# strata-multi.ps1 - start Strata in multi-vendor mode (RX 7900 XTX + RTX 4070 Ti SUPER, one process, port 8097),
# updating to the newest XeStrata release first, and falling back to the last working version if the new one does not run.
#
#   Release source: MistVVK/XeStrata main (the SYCL port of Strata that can target HIP + CUDA in one build).
#   "Release" = the version stamped in its CMakeLists.txt (STRATA_UPSTREAM_VERSION + XESTRATA_REVISION, e.g. xe0.2.8-1),
#   so a rebuild happens on a version bump, not on every commit.
#   Each version lives in its own folder <Root>\<version>; the known versions, which one last worked,
#   and which ones failed (and why) are in state.json. A failed version is not rebuilt again until a newer one appears.
#
#   Also checks, at every start, the NVIDIA and AMD drivers, the CUDA Toolkit, the ROCm HIP SDK and the intel/llvm compiler, and says
#   (popup, once per new version) when one is newer. It never installs them; -Rebuild builds the engine again against the newest
#   installed toolkits, as a separate version that is tested and kept only if it runs (the working one stays the fallback).
#
#   Usage: strata-multi.bat [-NoUpdate] [-CheckOnly] [-Rebuild] [-NoCheck]
#   Test hooks (used to prove the revert path without loading a model): -StatePath <json> -Port <n> -ForceCandidate <version name>
#   -RepoUrl <git url>: read releases from another repository (used to prove the update path with a simulated release)
#   -Sessions N: serve N conversations in parallel (batch slots). 1 (default) = one session with pipelined windows.
param([switch]$NoUpdate, [switch]$CheckOnly, [switch]$Rebuild, [switch]$NoCheck, [string]$StatePath, [int]$Port, [string]$ForceCandidate, [string]$RepoUrl, [int]$Sessions = 1)

$ErrorActionPreference = 'Continue'
# ---- settings: defaults, overridden by launcher-settings.ps1 next to this script (copy launcher-settings.example.ps1) ----
$Root        = Split-Path $PSScriptRoot -Parent          # install folder: holds state.json, logs\, one folder per built version
$ReleaseRepo = 'https://github.com/MistVVK/XeStrata.git'
$ServeLog    = $null                                      # server console log (default: <Root>\logs\serve.log)
$BasePython  = 'python.exe'                               # used to create one venv per version
$Node        = 'C:\Program Files\nodejs\node.exe'
$Guard       = $null                                      # memory guard (default: guard-mem.cjs next to this script)
$ServePort   = 8097
$Toolchain   = $null                                      # mixed intel/llvm install folder (has bin\clang++.exe)
$ToolchainRepo = $null                                    # intel/llvm source checkout (only for the version report)
$NinjaDir    = $null                                      # folder with ninja.exe (a venv's Scripts folder works)
$DeviceLibs  = $null                                      # ROCm device libraries prepared for the toolchain
$VcVars      = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
$HipArch     = 'gfx1100'; $CudaArch = 'sm_89'
$BuildTemp   = $null                                      # temp folder for compiles (default: <Root>\tmp)
$AmdDriverPage = 'https://www.amd.com/en/support/downloads/drivers.html/graphics/radeon-rx/radeon-rx-7000-series/amd-radeon-rx-7900-xtx.html'
$SeedVersion = $null                                      # first run only: the build that already works, @{ name; root; config; python }
# Parallel sessions: engine flags added for N > 1 ({0} = N); --pipeline-windows is removed (the engine refuses it beside --batch).
# --batch-groups auto crashed reliably on any concurrent request in our tests ("verify batch: the window's commit did not
# finish"); --batch-groups 1 (one slot group, real per-slot MTP) was clean at 2 and 4 slots. See README "Multi-session".
$SessionArgs = @('--batch', '{0}', '--batch-groups', '1')
$SettingsFile = Join-Path $PSScriptRoot 'launcher-settings.ps1'
if (Test-Path $SettingsFile) { . $SettingsFile }
if (-not $ServeLog) { $ServeLog = Join-Path $Root 'logs\serve.log' }
if (-not $Guard) { $Guard = Join-Path $PSScriptRoot 'guard-mem.cjs' }
if (-not $BuildTemp) { $BuildTemp = Join-Path $Root 'tmp' }
# ---- derived ----
$Repo       = $(if ($RepoUrl) { $RepoUrl } else { $ReleaseRepo })
$Probe      = Join-Path $Root $(if ($RepoUrl) { '_probe-test' } else { '_probe' })
$StateF     = $(if ($StatePath) { $StatePath } else { Join-Path $Root 'state.json' })
$LogF       = Join-Path $Root 'logs\strata-multi.log'
$ActiveCmd  = Join-Path $Root 'active-serve.cmd'
if (-not $Port) { $Port = $ServePort }
# the build script reads these
$env:XU_ROOT = $Root; $env:XU_TOOLCHAIN = $Toolchain; $env:XU_NINJA_DIR = $NinjaDir; $env:XU_DEVICE_LIBS = $DeviceLibs
$env:XU_VCVARS = $VcVars; $env:XU_HIP_ARCH = $HipArch; $env:XU_CUDA_ARCH = $CudaArch; $env:XU_TEMP = $BuildTemp
$LoadTimeoutMin = 25      # model load from disk can take a while
$PromptSlow = 0.5         # new prompt reading below 50 % of the last working version = "much slower"
$DecodeSlow = 0.6         # new decode below 60 % = "much slower"
$SpeedRx = 'prompt (\d+) tokens = (\d+) reused \+ (\d+) read in (\d+) ms \(([\d.]+) tok/s\), (\d+) generated in (\d+) ms \(([\d.]+) tok/s\)'

New-Item -ItemType Directory -Force (Join-Path $Root 'logs') | Out-Null

function Log([string]$m) {
  $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m
  Write-Host $line
  for ($i = 0; $i -lt 5; $i++) {   # another program may be reading the log; never fail the launch over it
    try { $fs = [IO.File]::Open($LogF, 'Append', 'Write', 'ReadWrite'); $b = [Text.Encoding]::UTF8.GetBytes($line + "`r`n"); $fs.Write($b, 0, $b.Length); $fs.Close(); break }
    catch { Start-Sleep -Milliseconds 200 }
  }
}

$YesNoTimeoutSec = 600     # an unanswered Yes/No question takes the safe answer (No = back to the last working version)
function Popup([string]$text, [string]$title, [string]$kind = 'Info') {
  # Topmost Windows popup. Info / Warning / Error do not block this script (shown by a separate process, stays until clicked);
  # YesNo waits up to $YesNoTimeoutSec and then answers No.
  Log "POPUP [$kind] $title : $($text -replace "`r?`n", ' | ')"
  $flags = 64; if ($kind -eq 'Warning') { $flags = 48 }; if ($kind -eq 'Error') { $flags = 16 }
  if ($kind -eq 'YesNo') {
    $r = (New-Object -ComObject WScript.Shell).Popup($text + "`n`n(No answer in $([int]($YesNoTimeoutSec/60)) minutes = No)", $YesNoTimeoutSec, $title, 4 + 48 + 4096)
    if ($r -eq 6) { return 'Yes' } else { return 'No' }
  }
  $tf = Join-Path $env:TEMP ("xs-popup-" + [guid]::NewGuid().ToString('N') + '.txt')
  [IO.File]::WriteAllText($tf, $title + "`n" + $text, (New-Object Text.UTF8Encoding $false))
  $cmd = "`$l = [IO.File]::ReadAllLines('$tf'); Remove-Item '$tf'; (New-Object -ComObject WScript.Shell).Popup((`$l[1..(`$l.Count-1)] -join [char]10), 0, `$l[0], $($flags + 4096)) | Out-Null"
  Start-Process powershell.exe -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-Command', $cmd -WindowStyle Hidden | Out-Null
  return 'OK'
}

function Save-Json($obj, [string]$path) {
  $j = $obj | ConvertTo-Json -Depth 8
  [IO.File]::WriteAllText($path, $j, (New-Object Text.UTF8Encoding $false))
}

function Run([string]$cmdline) {   # run a native command through cmd (no PowerShell stderr wrapping); returns output lines
  $out = cmd /c "$cmdline 2>&1"
  $script:LastCode = $LASTEXITCODE
  return $out
}

function Median($xs) {
  $s = @($xs | Sort-Object)
  if ($s.Count -eq 0) { return $null }
  return [math]::Round([double]$s[[int][math]::Floor($s.Count / 2)], 1)
}

function Read-Speeds([string]$path, [long]$fromByte = 0) {
  $res = @()
  if (-not $path -or -not (Test-Path $path)) { return $res }
  $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
  try {
    if ($fromByte -gt $fs.Length) { $fromByte = 0 }
    $fs.Seek($fromByte, 'Begin') | Out-Null
    $txt = (New-Object IO.StreamReader($fs)).ReadToEnd()
  } finally { $fs.Close() }
  foreach ($m in [regex]::Matches($txt, $SpeedRx)) {
    $res += [pscustomobject]@{ read = [int]$m.Groups[3].Value; ptps = [double]$m.Groups[5].Value; gen = [int]$m.Groups[6].Value; dtps = [double]$m.Groups[8].Value }
  }
  return $res
}

function Tail([string]$path, [int]$n = 10) {
  if (-not $path -or -not (Test-Path $path)) { return '' }
  return ((Get-Content $path -Tail $n -ErrorAction SilentlyContinue) -join "`n")
}

function VerKey([string]$name) {   # 'xe0.2.8-1' -> [version]0.2.8, revision 1
  $m = [regex]::Match($name, 'xe(\d+(?:\.\d+)+)-(\d+)')
  if (-not $m.Success) { return $null }
  return [pscustomobject]@{ v = [version]$m.Groups[1].Value; rev = [int]$m.Groups[2].Value }
}
function Is-Newer([string]$a, [string]$b) {
  $ka = VerKey $a; $kb = VerKey $b
  if (-not $ka -or -not $kb) { return $false }
  if ($ka.v -ne $kb.v) { return ($ka.v -gt $kb.v) }
  return ($ka.rev -gt $kb.rev)
}

# ---------- state ----------
function Load-State {
  if (Test-Path $StateF) { return (Get-Content $StateF -Raw | ConvertFrom-Json) }
  # First run: adopt the build that already works ($SeedVersion in launcher-settings.ps1). Its speed baseline comes from its own engine log.
  if (-not $SeedVersion) { throw "no state.json yet and no `$SeedVersion in launcher-settings.ps1: name the build that already works (see launcher-settings.example.ps1)" }
  $sv = [pscustomobject]$SeedVersion
  $sp = @(); try { $sp = Read-Speeds ((Get-Content $sv.config -Raw | ConvertFrom-Json).log) } catch {}
  $v = [pscustomobject]@{
    name = $sv.name; root = $sv.root; config = $sv.config
    python = $sv.python; commit = $(if ($sv.commit) { $sv.commit } else { '' }); status = 'good'; reason = ''
    promptTps = (Median ($sp | Where-Object { $_.read -ge 4000 } | ForEach-Object { $_.ptps }))
    decodeTps = (Median ($sp | Where-Object { $_.gen -ge 200 } | ForEach-Object { $_.dtps }))
    checked = (Get-Date -Format s)
  }
  $s = [pscustomobject]@{ lastGood = $v.name; versions = @($v) }
  Save-Json $s $StateF
  return $s
}
function Get-Ver($state, [string]$name) { return (@($state.versions) | Where-Object { $_.name -eq $name } | Select-Object -First 1) }
function Set-Ver($state, $v) {
  $state.versions = @(@($state.versions) | Where-Object { $_.name -ne $v.name }) + @($v)
  Save-Json $state $StateF
}

# ---------- release check ----------
function Get-Latest {
  if (-not (Test-Path (Join-Path $Probe '.git'))) { Run "git clone -q --filter=blob:none --no-checkout $Repo $Probe" | Out-Null; if ($LastCode -ne 0) { return $null } }
  Run "git -C $Probe fetch -q origin main" | Out-Null
  if ($LastCode -ne 0) { return $null }
  $commit = ((Run "git -C $Probe rev-parse origin/main") | Select-Object -First 1).Trim()
  $cm = (Run "git -C $Probe show origin/main:CMakeLists.txt") -join "`n"
  $up = [regex]::Match($cm, 'set\(STRATA_UPSTREAM_VERSION "([^"]+)"\)').Groups[1].Value
  $rev = [regex]::Match($cm, 'set\(XESTRATA_REVISION (\d+)\)').Groups[1].Value
  if (-not $up -or -not $rev) { return $null }
  return [pscustomobject]@{ name = "xe$up-$rev"; commit = $commit }
}

# ---------- build ----------
function Wait-OtherBuild {
  $shown = $false
  while ($true) {
    $b = @(Get-CimInstance Win32_Process -Filter "Name='ninja.exe'" | Where-Object { $NinjaDir -and $_.ExecutablePath -like (Join-Path $NinjaDir '*') })
    if ($b.Count -eq 0) { return }
    if (-not $shown) { Log 'An XeStrata build is already running (started outside this launcher); waiting for it to finish.'; $shown = $true }
    $bl = Get-ChildItem (Join-Path $Root 'logs\build-*.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
    if ($bl) { Write-Host ('   ' + (Get-Content $bl.FullName -Tail 1)) }
    Start-Sleep -Seconds 30
  }
}

function Build-Version($latest) {
  $name = $latest.name; $tree = Join-Path $Root $name
  $blog = Join-Path $Root "logs\build-$name.log"
  if (-not (Test-Path (Join-Path $tree '.git'))) {
    Log "Downloading $name source ($Repo) ..."
    Run "git clone -q --filter=blob:none $Repo $tree" | Out-Null
    if ($LastCode -ne 0) { return "git clone failed" }
  }
  $head = ((Run "git -C $tree rev-parse HEAD") | Select-Object -First 1).Trim()
  if ($head -ne $latest.commit) {
    Run "git -C $tree fetch -q origin" | Out-Null
    Run "git -C $tree checkout -q --detach $($latest.commit)" | Out-Null
    if ($LastCode -ne 0) { return "git checkout of $($latest.commit) failed" }
  }
  return (Run-Build $name 'build\mixed' $blog)
}

function Run-Build([string]$treeName, [string]$bdir, [string]$blog) {   # xu_build.cmd in the background with progress; '' = ok, else the reason
  $availGB = (Get-Counter '\Memory\Available MBytes').CounterSamples[0].CookedValue / 1024
  $jobs = [math]::Max(2, [math]::Min(8, [int][math]::Floor($availGB / 3)))
  Log "Building $treeName ($bdir) with the mixed HIP+CUDA toolchain ($jobs jobs, below-normal priority). This can take 30-90 minutes. Log: $blog"
  $p = Start-Process -FilePath cmd.exe -ArgumentList "/c $PSScriptRoot\xu_build.cmd $treeName $jobs $bdir >> $blog 2>&1" -NoNewWindow -PassThru
  try { $p.PriorityClass = 'BelowNormal' } catch {}
  $last = ''
  while (-not $p.HasExited) {
    Start-Sleep -Seconds 20
    $l = Get-Content $blog -Tail 1 -ErrorAction SilentlyContinue
    if ($l -and $l -ne $last) { Write-Host ('   ' + $l); $last = $l }
  }
  $codes = Select-String -Path $blog -Pattern 'XU (BUILD|CONFIGURE) EXIT CODE (\d+)' | Select-Object -Last 1
  $exe = Join-Path (Join-Path (Join-Path $Root $treeName) $bdir) 'strata.exe'
  if (-not $codes -or $codes.Matches[0].Groups[2].Value -ne '0' -or -not (Test-Path $exe)) { return "build failed (see $blog)" }
  return ''
}

# ---------- the other components the multi-vendor build depends on (checked at every start, never installed from here) ----------
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
$HipSdkPage = 'https://www.amd.com/en/developer/resources/rocm-hub/hip-sdk.html'
$CudaRoot = 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA'
$RocmRoot = 'C:\Program Files\AMD\ROCm'

function Ver([string]$s) { $m = [regex]::Match([string]$s, '\d+(\.\d+)+'); if ($m.Success) { try { return [version]$m.Value } catch {} }; return $null }
function Max-Ver($list) { return (@($list | ForEach-Object { Ver $_ } | Where-Object { $_ }) | Sort-Object | Select-Object -Last 1) }
function Web([string]$url) { try { return (Invoke-WebRequest -Uri $url -TimeoutSec 25 -UseBasicParsing -UserAgent $UA).Content } catch { return $null } }
function Uninstalled([string]$rx) {
  return (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match $rx } | Select-Object -First 1).DisplayVersion
}
function Newest-Dir([string]$root) { return (Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Where-Object { Ver $_.Name } | Sort-Object { Ver $_.Name } | Select-Object -Last 1) }
function Short([string]$path) { try { return (New-Object -ComObject Scripting.FileSystemObject).GetFolder($path).ShortPath } catch { return $path } }

function Check-Components {
  $out = @()
  # NVIDIA display driver: installed from nvidia-smi; latest from NVIDIA's driver lookup for this exact card
  $inst = $null; $latest = $null; $url = 'https://www.nvidia.com/Download/index.aspx'; $drvCuda = $null
  try {
    $q = (Run 'nvidia-smi --query-gpu=name,driver_version --format=csv,noheader' | Select-Object -First 1) -split ',\s*'
    $gpu = $q[0].Trim(); $inst = $q[1].Trim()
    $drvCuda = [regex]::Match(((Run 'nvidia-smi') -join ' '), 'CUDA Version:\s*([\d.]+)').Groups[1].Value
    foreach ($series in 127, 131, 120) {   # GeForce RTX 40, 50, 30 series
      [xml]$x = Web "https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=3&ParentID=$series"
      $pf = @($x.LookupValueSearch.LookupValues.LookupValue | Where-Object { $_.Name -eq $gpu -or $_.Name -eq "NVIDIA $gpu" })[0]
      if ($pf) {
        $j = Web "https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&psid=$series&pfid=$($pf.Value)&osID=57&languageCode=1033&beta=0&isWHQL=1&dltype=-1&dch=1&upCRD=0&qnf=0&sort1=0&numberOfResults=1"
        $info = ($j | ConvertFrom-Json).IDS[0].downloadInfo
        $latest = $info.Version; $url = $info.DownloadURL; break
      }
    }
  } catch {}
  $out += [pscustomobject]@{ name = 'NVIDIA driver'; installed = $inst; latest = $latest; url = $url; rebuild = 'no rebuild needed'; extra = $(if ($drvCuda) { "supports CUDA $drvCuda" } else { '' }) }
  # AMD Software (Adrenalin)
  $page = Web $AmdDriverPage
  $amdLatest = $null; if ($page) { $amdLatest = (Max-Ver ([regex]::Matches($page, 'Adrenalin(?: Edition)? (\d+\.\d+\.\d+)') | ForEach-Object { $_.Groups[1].Value })) }
  $out += [pscustomobject]@{ name = 'AMD Software (Adrenalin)'; installed = (Uninstalled '^AMD Software$'); latest = $amdLatest; url = $AmdDriverPage; rebuild = 'no rebuild needed'; extra = '' }
  # CUDA Toolkit
  $cudaDir = Newest-Dir $CudaRoot
  $idx = Web 'https://developer.download.nvidia.com/compute/cuda/redist/'
  $cudaLatest = $null; if ($idx) { $cudaLatest = Max-Ver ([regex]::Matches($idx, 'redistrib_([\d.]+)\.json') | ForEach-Object { $_.Groups[1].Value }) }
  $out += [pscustomobject]@{ name = 'CUDA Toolkit'; installed = $(if ($cudaDir) { $cudaDir.Name.TrimStart('v') }); latest = $cudaLatest; url = 'https://developer.nvidia.com/cuda-downloads'; rebuild = 'then run strata-multi.bat -Rebuild'; extra = '' }
  # ROCm HIP SDK for Windows (AMD lists major.minor; a patch release of the same line counts as current)
  $hp = Web $HipSdkPage
  $hipLatest = $null; if ($hp) { $hipLatest = Max-Ver ([regex]::Matches($hp, 'HIP SDK (\d+\.\d+(?:\.\d+)?)') | ForEach-Object { $_.Groups[1].Value }) }
  $out += [pscustomobject]@{ name = 'ROCm HIP SDK'; installed = (Uninstalled '^HIP SDK Core$'); latest = $hipLatest; url = $HipSdkPage; rebuild = 'then run strata-multi.bat -Rebuild (the device libraries step 03 of XeStrata-mixed may need redoing)'; extra = '' }
  # intel/llvm SYCL compiler (the toolchain that targets both vendors)
  $tcInst = ((Run "git -C $ToolchainRepo describe --tags --abbrev=0") | Select-Object -First 1)
  $tags = Run 'git ls-remote --tags https://github.com/intel/llvm.git v*'
  $tcLatest = Max-Ver ($tags | ForEach-Object { if ($_ -match 'refs/tags/v(\d+\.\d+\.\d+)$') { $Matches[1] } })
  $out += [pscustomobject]@{ name = 'intel/llvm SYCL compiler'; installed = $tcInst; latest = $tcLatest; url = 'https://github.com/intel/llvm/releases'; rebuild = 'compiler rebuild (hours): XeStrata-mixed scripts 01-05, not automated'; extra = '' }

  foreach ($c in $out) {
    $vi = Ver $c.installed; $vl = Ver $c.latest
    $newer = $false
    if ($vi -and $vl) {
      if ($c.name -eq 'ROCm HIP SDK') { $newer = ([version]"$($vl.Major).$($vl.Minor)") -gt ([version]"$($vi.Major).$($vi.Minor)") } else { $newer = $vl -gt $vi }
    }
    $c | Add-Member -NotePropertyName newer -NotePropertyValue $newer
    $state_ = $(if (-not $vl) { 'latest unknown (offline?)' } elseif ($newer) { 'NEWER AVAILABLE' } else { 'up to date' })
    Log ("  {0,-26} installed {1,-12} latest {2,-10} {3} {4}" -f $c.name, $c.installed, $c.latest, $state_, $c.extra)
  }
  return $out
}

function Report-Components($state) {
  Log 'Checking drivers, toolkits and the compiler ...'
  $cs = Check-Components
  $new = @($cs | Where-Object { $_.newer })
  if (-not $new.Count) { return }
  $key = ($new | ForEach-Object { "$($_.name)=$($_.latest)" }) -join ';'
  if ($state.PSObject.Properties['notified'] -and $state.notified -eq $key) { Log '  (already reported; no popup)'; return }
  $lines = $new | ForEach-Object { "- $($_.name): $($_.installed) -> $($_.latest) ($($_.rebuild))`n  $($_.url)" }
  Popup ("Newer versions are available (nothing was installed):`n`n" + ($lines -join "`n") + "`n`nDrivers: install them yourself, then start XeStrata again. Toolkits: install, then run strata-multi.bat -Rebuild to build and test the engine against them (your working version is kept until the new build passes).") 'XeStrata: updates for drivers and toolkits' 'Info' | Out-Null
  $state | Add-Member -NotePropertyName notified -NotePropertyValue $key -Force
  Save-Json $state $StateF
}

function Prepare-Version($latest, $base) {   # venv + config for a freshly built version, derived from the last working config
  $name = $latest.name; $tree = Join-Path $Root $name
  $venv = Join-Path $Root "venvs\$name"; $py = Join-Path $venv 'Scripts\python.exe'
  if (-not (Test-Path $py)) {
    Log "Creating the Python environment for $name ..."
    Run "`"$BasePython`" -m venv $venv" | Out-Null
    if ($LastCode -ne 0) { return @{ err = 'could not create the Python venv' } }
  }
  # Local fixes for this version (patches\<version>\*.patch, e.g. a newer Strata's server fixes that the port does not carry yet).
  # Each is applied only when it applies cleanly, and skipped when it is already in; the test start below is the final check.
  foreach ($pf in @(Get-ChildItem (Join-Path $Root "patches\$name\*.patch") -ErrorAction SilentlyContinue)) {
    Run "git -C $tree apply --reverse --check $($pf.FullName)" | Out-Null
    if ($LastCode -eq 0) { Log "Patch $($pf.Name): already applied"; continue }
    Run "git -C $tree apply --check $($pf.FullName)" | Out-Null
    if ($LastCode -ne 0) { Log "Patch $($pf.Name): does not apply to $name, skipped"; continue }
    Run "git -C $tree apply $($pf.FullName)" | Out-Null
    Log "Patch $($pf.Name): applied"
  }
  $env:PIP_CACHE_DIR = Join-Path $Root 'pip-cache'
  Run "$py -m pip install -q --disable-pip-version-check -r $tree\requirements.txt" | Out-Null
  if ($LastCode -ne 0) { return @{ err = 'pip install of the server requirements failed' } }

  $c = Get-Content $base.config -Raw | ConvertFrom-Json
  $old = $base.root.TrimEnd('\')
  $map = { param($s) if ($s -is [string] -and $s.StartsWith($old + '\', [StringComparison]::OrdinalIgnoreCase)) { $tree + $s.Substring($old.Length) } else { $s } }
  $c.exe = & $map $c.exe
  $c.cwd = & $map $c.cwd
  $c.lib_dirs = @($c.lib_dirs | ForEach-Object { & $map $_ })
  $c.args = @($c.args | ForEach-Object { & $map $_ })
  $c.log = Join-Path $Root "logs\$name-engine.log"
  $cfg = Join-Path $Root "$name.json"
  Save-Json $c $cfg
  return @{ err = ''; v = [pscustomobject]@{ name = $name; root = $tree; config = $cfg; python = $py; commit = $latest.commit; status = 'testing'; reason = ''; promptTps = $null; decodeTps = $null; checked = (Get-Date -Format s) } }
}

# ---------- run / verify ----------
function Health([int]$port) {
  try { return (Invoke-RestMethod -Uri "http://127.0.0.1:$port/health" -TimeoutSec 3) } catch { return $null }
}

function Apply-XtxClock {
  # Optional fallback: if you have no other tool managing GPU clocks, this applies a max-clock cap (Overdrive8 setting 0,
  # amd-od8.ps1 in this folder) before every start. On our PC, an uncapped RX 7900 XTX under two-GPU load hard-reset the
  # system (Kernel-Power 41) within seconds to minutes, even on a 1000 W PSU; capping it removed that. A later test found
  # that LOCKING the clock (min = max, Overdrive8 setting 1 = setting 0: `amd-od8.ps1 -Set "1=<mhz>,0=<mhz>"`) costs no
  # measurable speed over a ceiling-only cap and may be the more robust fix, since it removes the boost ramp entirely
  # rather than just lowering its top; we did not get a controlled test of locked vs. ceiling-only at a clock that
  # ceiling-only alone was known to fail at. Clock caps reset at every reboot and need no administrator rights to set.
  # xtx-clock.txt holds the MHz (delete the file to stop applying it).
  $f = Join-Path $Root 'xtx-clock.txt'
  if (-not (Test-Path $f)) { return }
  $mhz = ((Get-Content $f | Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -First 1) -as [string]).Trim()
  if (-not $mhz) { return }
  $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'amd-od8.ps1') -Set "0=$mhz" 2>&1 | Select-Object -First 1
  Log "XTX max clock ${mhz} MHz: $o"
}

function Session-Config($v) {
  # N > 1: a copy of the version's config with batch slots instead of pipelined windows (the version's own config stays as it is).
  if ($Sessions -le 1) { return $v.config }
  $c = Get-Content $v.config -Raw | ConvertFrom-Json
  $a = [System.Collections.Generic.List[string]]@($c.args)
  foreach ($flag in '--pipeline-windows', '--batch', '--slots', '--batch-groups') { $i = $a.IndexOf($flag); if ($i -ge 0) { $a.RemoveRange($i, 2) } }
  $c.args = @($a) + @($SessionArgs | ForEach-Object { $_ -f $Sessions })
  $out = [IO.Path]::ChangeExtension($v.config, ".sessions$Sessions.json")
  Save-Json $c $out
  Log "Parallel sessions: $Sessions ($((@($SessionArgs | ForEach-Object { $_ -f $Sessions })) -join ' '); pipelined windows off)"
  return $out
}

function Start-Server($v) {
  Apply-XtxClock
  $cfgUsed = Session-Config $v
  $lines = @(
    '@echo off',
    "rem Written by strata-multi.ps1 on $(Get-Date -Format s): serves $($v.name) in multi-vendor mode on port $Port.",
    "title XeStrata $($v.name) (multi-vendor, port $Port)",
    "cd /d $($v.root) || exit /b 1",
    "`"$Node`" $Guard 6 0.15 60 $($v.python) -m serve.server --engine $(if ($v.PSObject.Properties['engine'] -and $v.engine) { $v.engine } else { 'strata' }) --config $cfgUsed --port $Port >> $ServeLog 2>&1",
    "echo XS SERVE EXIT CODE %ERRORLEVEL% >> $ServeLog"
  )
  [IO.File]::WriteAllText($ActiveCmd, ($lines -join "`r`n") + "`r`n", (New-Object Text.ASCIIEncoding))
  Add-Content -Path $ServeLog -Value "==== strata-multi: starting $($v.name) at $(Get-Date -Format s)"
  Log "Starting $($v.name) (window: 'XeStrata $($v.name)', minimized) ..."
  return (Start-Process -FilePath cmd.exe -ArgumentList "/c $ActiveCmd" -WindowStyle Minimized -PassThru)
}

function Stop-Server($proc, $v) {
  if ($proc -and -not $proc.HasExited) { Run "taskkill /PID $($proc.Id) /T /F" | Out-Null }
  for ($i = 0; $i -lt 30; $i++) {
    $left = @(Get-Process strata -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$($v.root)\*" })
    if ($left.Count -eq 0) { break }
    if ($i -eq 15) { $left | Stop-Process -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
  }
  Start-Sleep -Seconds 5   # let the drivers release VRAM
}

function Chat($model, [string]$text, [int]$max, [int]$timeout) {
  $body = @{ model = $model; max_tokens = $max; stream = $false; messages = @(@{ role = 'user'; content = $text }) } | ConvertTo-Json -Depth 6 -Compress
  $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/chat/completions" -Method Post -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec $timeout
  $n = 0; if ($r.usage) { $n = [int]$r.usage.completion_tokens }
  $t = ''; if ($r.choices) { $t = [string]$r.choices[0].message.content }
  if ($n -le 0 -and -not $t) { throw 'empty answer' }
  return $r
}

function Verify($v, [bool]$measure) {
  $res = @{ ok = $false; reason = ''; proc = $null; ptps = $null; dtps = $null }
  $cfg = Get-Content $v.config -Raw | ConvertFrom-Json
  $res.proc = Start-Server $v
  $deadline = (Get-Date).AddMinutes($LoadTimeoutMin); $model = $null; $nextNote = Get-Date
  while ((Get-Date) -lt $deadline) {
    if ($res.proc.HasExited) { $res.reason = "the server stopped while loading (exit code $($res.proc.ExitCode))"; return $res }
    $h = Health $Port
    if ($h -and $h.status -eq 'ok') { $model = $h.model; break }
    if ((Get-Date) -ge $nextNote) { $l = (Get-Content $ServeLog -Tail 1 -ErrorAction SilentlyContinue); Write-Host "   loading ... $l"; $nextNote = (Get-Date).AddSeconds(60) }
    Start-Sleep -Seconds 10
  }
  if (-not $model) { $res.reason = "the server did not answer /health within $LoadTimeoutMin minutes"; return $res }
  Log "$($v.name) is up (model $model). Test request ..."
  # A request may hit the engine's occasional CUDA crash (it restarts itself, about 1 min): retry once before judging the version.
  $retry = {
    param($text, $max, $timeout, $what)
    try { Chat $model $text $max $timeout | Out-Null; return '' } catch { $first = $_.Exception.Message }
    if ($res.proc.HasExited) { return "the $what failed and the server stopped: $first" }
    Log "The $what failed ($first); waiting for the engine to restart, then retrying once ..."
    Start-Sleep -Seconds 15
    $until = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $until -and -not ((Health $Port) -and (Health $Port).status -eq 'ok')) { Start-Sleep -Seconds 5 }
    try { Chat $model $text $max $timeout | Out-Null; Log "The $what passed on the retry."; return '' } catch { return "the $what failed twice: $first / $($_.Exception.Message)" }
  }
  $e1 = & $retry 'Reply with the single word: ready' 300 600 'test request'
  if ($e1) { $res.reason = $e1; return $res }
  if ($measure) {
    Log 'Speed test (about 8,000-token prompt) ...'
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine("Run $(Get-Random). Below is a numbered list.")
    for ($i = 1; $i -le 600; $i++) { [void]$sb.AppendLine("Line ${i}: the quick brown fox jumps over the lazy dog near the river bank.") }
    [void]$sb.AppendLine('Write a short paragraph about what this list contains and how long it is.')
    $from = 0; if ($cfg.log -and (Test-Path $cfg.log)) { $from = (Get-Item $cfg.log).Length }
    $e2 = & $retry $sb.ToString() 400 900 'speed-test request'
    if ($e2) { $res.reason = $e2; return $res }
    Start-Sleep -Seconds 2
    $sp = @(Read-Speeds $cfg.log $from) | Select-Object -Last 1
    if ($sp) { $res.ptps = $sp.ptps; $res.dtps = $sp.dtps; Log "Speed: prompt $($sp.ptps) tok/s ($($sp.read) tokens), decode $($sp.dtps) tok/s" }
    else { Log 'Speed: could not read the engine log line (format changed?), speed comparison skipped.' }
  }
  if ($res.proc.HasExited) { $res.reason = 'the server stopped right after the test'; return $res }
  $res.ok = $true
  return $res
}

# ---------- main ----------
$lockF = Join-Path $Root 'strata-multi.lock'
try { $lock = [IO.File]::Open($lockF, 'OpenOrCreate', 'ReadWrite', 'None') }
catch { Popup 'The XeStrata launcher is already running in another window.' 'XeStrata multi-vendor' 'Info' | Out-Null; exit 1 }

try {
  $state = Load-State
  $good = Get-Ver $state $state.lastGood
  Log "Last working version: $($good.name)"

  if ($CheckOnly) {
    Report-Components $state
    $l = Get-Latest
    if (-not $l) { Log 'Could not read the latest release (no network?).' }
    elseif (Is-Newer $l.name $good.name) { Log "Newer release available: $($l.name) ($($l.commit.Substring(0,8)))" }
    else { Log "Up to date (newest release: $($l.name))." }
    exit 0
  }

  # Refuse to start next to anything that already holds the GPUs.
  if ((Health $Port) -or (Get-Process strata -ErrorAction SilentlyContinue)) {
    Popup "XeStrata is already running (port $Port).`n`nStop it first (AI Launcher, Strata tab), then run this again." 'XeStrata multi-vendor' 'Info' | Out-Null
    exit 0
  }
  $busy = @(8081, 8082, 8083 | Where-Object { Health $_ })
  if ($busy.Count) {
    Popup ("Local models are loaded on port(s) $($busy -join ', ').`n`nXeStrata needs both GPUs and most of the RAM. Stop them first (AI Launcher), then run this again.") 'XeStrata multi-vendor' 'Warning' | Out-Null
    exit 1
  }

  if (-not $NoCheck) { Report-Components $state }

  $candidate = $null; $updateNote = ''
  if ($ForceCandidate) {
    $candidate = Get-Ver $state $ForceCandidate
    if (-not $candidate) { Log "No version named $ForceCandidate in $StateF"; exit 1 }
    Log "Testing $ForceCandidate as the new version (-ForceCandidate)."
  }
  elseif ($Rebuild) {
    # Same engine source, built again against the newest CUDA Toolkit and ROCm installed, into its own build folder.
    if (-not $good.root.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) {
      Popup "-Rebuild works on versions this launcher built; the last working version ($($good.name)) is the original XeStrata-mixed build." 'XeStrata rebuild' 'Warning' | Out-Null
      exit 1
    }
    $cuda = Newest-Dir $CudaRoot; $rocm = Newest-Dir $RocmRoot
    if (-not $cuda -or -not $rocm) { Popup 'No CUDA Toolkit or ROCm HIP SDK folder was found.' 'XeStrata rebuild' 'Error' | Out-Null; exit 1 }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
    $bdir = "build\r$stamp"; $treeName = Split-Path $good.root -Leaf
    $vname = ($good.name -replace '\+r\d{8}-\d{4}$', '') + "+r$stamp"
    $env:XU_CUDA = Short $cuda.FullName; $env:XU_ROCM = Short $rocm.FullName
    Log "Rebuild of $($good.name) as $vname with CUDA $($cuda.Name) ($env:XU_CUDA) and ROCm $($rocm.Name) ($env:XU_ROCM)"
    $err = Run-Build $treeName $bdir (Join-Path $Root "logs\build-$vname.log")
    if (-not $err) {
      $c = Get-Content $good.config -Raw | ConvertFrom-Json
      $oldB = ($c.cwd).TrimEnd('\'); $newB = Join-Path $good.root $bdir
      $sw = { param($s) if ($s -is [string] -and $s.StartsWith($oldB, [StringComparison]::OrdinalIgnoreCase)) { $newB + $s.Substring($oldB.Length) } else { $s } }
      $c.exe = & $sw $c.exe; $c.cwd = & $sw $c.cwd
      $oldRocm = [string]$c.env.ROCM_PATH
      $c.lib_dirs = @($c.lib_dirs | ForEach-Object { $x = & $sw $_; if ($oldRocm -and $x.StartsWith($oldRocm, [StringComparison]::OrdinalIgnoreCase)) { $env:XU_ROCM + $x.Substring($oldRocm.Length) } else { $x } })
      $c.env.ROCM_PATH = $env:XU_ROCM; $c.env.CUDA_PATH = $env:XU_CUDA
      $c.log = Join-Path $Root "logs\$vname-engine.log"
      $cfg = Join-Path $Root "$vname.json"; Save-Json $c $cfg
      $candidate = [pscustomobject]@{ name = $vname; root = $good.root; config = $cfg; python = $good.python; commit = $good.commit; status = 'testing'; reason = ''; promptTps = $null; decodeTps = $null; checked = (Get-Date -Format s) }
      Set-Ver $state $candidate
    } else {
      $updateNote = "The rebuild ($vname) failed:`n$err"
      Log "Rebuild failed: $err"
    }
  }
  elseif (-not $NoUpdate) {
    Log 'Checking for a newer XeStrata release ...'
    $latest = Get-Latest
    if (-not $latest) { Log 'Could not reach GitHub; starting the last working version.' }
    elseif (-not (Is-Newer $latest.name $good.name)) { Log "Up to date (newest release: $($latest.name))." }
    else {
      $known = Get-Ver $state $latest.name
      if ($known -and $known.status -eq 'bad' -and $known.commit -eq $latest.commit) {
        Log "Newer release $($latest.name) failed before ($($known.reason)); not retrying. Starting $($good.name)."
      } else {
        Log "New release found: $($latest.name) (commit $($latest.commit.Substring(0,8)))."
        Wait-OtherBuild
        $err = Build-Version $latest
        if (-not $err) { $prep = Prepare-Version $latest $good; $err = $prep.err }
        if ($err) {
          $bad = [pscustomobject]@{ name = $latest.name; root = (Join-Path $Root $latest.name); config = ''; python = ''; commit = $latest.commit; status = 'bad'; reason = $err; promptTps = $null; decodeTps = $null; checked = (Get-Date -Format s) }
          Set-Ver $state $bad
          Log "Update to $($latest.name) failed: $err"
          $updateNote = "The update to $($latest.name) failed:`n$err"
        } else { $candidate = $prep.v; Set-Ver $state $candidate }
      }
    }
  }

  if ($candidate) {
    $r = Verify $candidate $true
    $slow = ''
    if ($r.ok -and $good.promptTps -and $r.ptps -and $r.ptps -lt $PromptSlow * $good.promptTps) { $slow += "prompt reading $($r.ptps) tok/s (was about $($good.promptTps))`n" }
    if ($r.ok -and $good.decodeTps -and $r.dtps -and $r.dtps -lt $DecodeSlow * $good.decodeTps) { $slow += "decode $($r.dtps) tok/s (was about $($good.decodeTps))`n" }
    if ($r.ok -and $slow) {
      $a = Popup ("$($candidate.name) runs, but it is much slower than $($good.name):`n`n$slow`nKeep the new version?`n`nYes = keep $($candidate.name) running`nNo = go back to $($good.name)") 'XeStrata update' 'YesNo'
      if ($a -ne 'Yes') { $r.ok = $false; $r.reason = 'much slower than the last working version: ' + ($slow -replace "`n", '; ').TrimEnd('; ') }
    }
    if ($r.ok) {
      $candidate.status = 'good'; $candidate.promptTps = $r.ptps; $candidate.decodeTps = $r.dtps; $candidate.checked = (Get-Date -Format s)
      Set-Ver $state $candidate; $state.lastGood = $candidate.name; Save-Json $state $StateF
      Log "UPDATED: $($candidate.name) is running on port $Port and is now the last working version."
      $sp = ''; if ($r.ptps) { $sp = "`n`nPrompt $($r.ptps) tok/s, decode $($r.dtps) tok/s (before: about $($good.promptTps) / $($good.decodeTps))." }
      Popup ("XeStrata was updated to $($candidate.name) and is running in multi-vendor mode on port $Port.$sp`n`nThe previous version ($($good.name)) is kept as the fallback.") 'XeStrata updated' 'Info' | Out-Null
      exit 0
    }
    $cfgLog = (Get-Content $candidate.config -Raw | ConvertFrom-Json).log
    $tail = Tail $cfgLog 8
    Stop-Server $r.proc $candidate
    $candidate.status = 'bad'; $candidate.reason = $r.reason; $candidate.checked = (Get-Date -Format s); Set-Ver $state $candidate
    Log "Update to $($candidate.name) FAILED: $($r.reason). Going back to $($good.name)."
    $updateNote = "The update to $($candidate.name) did not run:`n$($r.reason)`n`nLast engine log lines:`n$tail`n`nLog: $cfgLog"
  }

  # Start the last working version (normal launch, or after a failed update). If even that fails, try older working versions.
  $tryList = @($good) + @(@($state.versions) | Where-Object { $_.status -eq 'good' -and $_.name -ne $good.name } | Sort-Object checked -Descending)
  foreach ($v in $tryList) {
    $r = Verify $v (-not $v.promptTps)
    if ($r.ok) {
      if (-not $v.promptTps -and $r.ptps) { $v.promptTps = $r.ptps; $v.decodeTps = $r.dtps; Set-Ver $state $v }
      if ($state.lastGood -ne $v.name) { $state.lastGood = $v.name; Save-Json $state $StateF }
      Log "$($v.name) is running in multi-vendor mode on port $Port."
      if ($updateNote) { Popup ("$updateNote`n`nReverted: the last working version $($v.name) is running in multi-vendor mode on port $Port.") 'XeStrata update failed - reverted' 'Warning' | Out-Null }
      exit 0
    }
    Log "$($v.name) did not start: $($r.reason)"
    Stop-Server $r.proc $v
    $updateNote = ($updateNote + "`n`n$($v.name) did not start either: $($r.reason)").Trim()
  }
  Popup ("XeStrata could not be started.`n`n$updateNote`n`nLogs: $ServeLog and $LogF") 'XeStrata not running' 'Error' | Out-Null
  exit 2
}
catch {
  Log "launcher error: $($_.Exception.Message)"
  Popup ("The XeStrata launcher stopped with an error:`n$($_.Exception.Message)`n`nLog: $LogF") 'XeStrata launcher error' 'Error' | Out-Null
  exit 3
}
finally { if ($lock) { $lock.Close() } }
