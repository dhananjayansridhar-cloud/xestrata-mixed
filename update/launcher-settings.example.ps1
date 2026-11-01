# launcher-settings.ps1 - per-PC settings for strata-multi.ps1 (copy this file to launcher-settings.ps1 next to it and edit).
# Every value is optional except the toolchain folders and, on the very first run, $SeedVersion.

# Install folder: state.json, logs\, and one folder per built XeStrata version (needs tens of GB; not your system SSD).
$Root          = 'D:\XeStrata-update'

# The mixed HIP+CUDA intel/llvm toolchain from the recipe in this repo (scripts 01-05), used read-only.
$Toolchain     = 'D:\xestrata-mixed\intel-llvm\install'      # has bin\clang++.exe
$ToolchainRepo = 'D:\xestrata-mixed\intel-llvm'              # source checkout, only for the "newer compiler" report
$NinjaDir      = 'D:\xestrata-mixed\.venv\Scripts'           # folder with ninja.exe
$DeviceLibs    = 'D:\xestrata-mixed\device-libs'             # from scripts\03-devlibs.cmd
$HipArch       = 'gfx1100'                                   # your AMD card (see env.example.cmd)
$CudaArch      = 'sm_89'                                     # your NVIDIA card

# Python 3 used to create one virtual environment per version (the server's requirements.txt is installed into it).
$BasePython    = 'C:\Python314\python.exe'

# Optional
# $ServeLog    = 'D:\xestrata-mixed\logs\serve.log'          # where the server's console output goes (live-speed tools read it)
# $Guard       = 'D:\xestrata-mixed\scripts\guard-mem.cjs'   # memory guard (default: guard-mem.cjs next to strata-multi.ps1)
# $BuildTemp   = 'D:\XeStrata-update\tmp'                    # compiler temp folder (keep heavy writes off a small SSD)
# $ServePort   = 8097
# $ReleaseRepo = 'https://github.com/MistVVK/XeStrata.git'   # where new XeStrata versions are looked for
# $VcVars      = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat'

# First run only: the multi-vendor build you already run (from this repo's recipe). It becomes the first "last working version".
$SeedVersion   = @{ name = 'xe0.1.45-1-win'                                   # any label; xe<upstream>-<revision> keeps version ordering
                    root = 'D:\xestrata-mixed\xestrata'                       # the source tree it was built from
                    config = 'D:\xestrata-mixed\config\xestrata-mixed.json'   # its server config
                    python = 'C:\path\to\a\venv\Scripts\python.exe' }         # a Python with the server's requirements
