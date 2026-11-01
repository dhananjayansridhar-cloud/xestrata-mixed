# XeStrata-mixed: run one big MoE model across an AMD GPU and an NVIDIA GPU on Windows

This repository is the glue for running **one model on two GPUs from different vendors at the same time**
(for example one AMD card and one NVIDIA card in the same PC), using the
[Strata](https://github.com/Niko1221/Strata) engine through its Windows SYCL port
[XeStrata-win](https://github.com/32x-k/XeStrata-win).

It contains build scripts, a server configuration template, a memory guard and the notes that cost
the most time to find. It does **not** contain the engine, the compiler or any model: those are
separate projects with their own licenses.

> Status: it works and is fast. A crash that hit every few minutes under agent load is gone in our tests with one environment
> variable (`STRATA_VERIFY_ASYNC_LAUNCH=0`, see [The stability finding](#the-stability-finding)). That result is from 15-minute test runs
> plus several hours of real use, not from a long soak test, so treat it as a tested recipe, not a finished product.
>
> **2026-11-01 update:** a newer XeStrata release (`xe0.2.8-1`, Strata 0.2.8) now builds with the same toolchain and runs **faster**
> than the 0.1.45 build above, instead of the 6x-slower regression we saw in the release between them (see
> [Notes on newer releases](#notes-on-newer-xestrata-and-strata-releases)). `update/` has a script that tracks new releases, builds
> and tests them automatically, and falls back if one does not run — see [Updating automatically](#updating-automatically). We also
> found that an **uncapped GPU clock** can hard-reset the PC under two-GPU load even on a large PSU, fixed by capping it (no
> administrator rights needed); see [The clock finding](#the-clock-finding) before you run this for long sessions.

## Why bother

Strata keeps a Mixture-of-Experts model's hot experts in VRAM and streams the rest from RAM or disk.
With a **layer split** the model's layers are divided between the cards, so each card holds fewer
experts' worth of data and the host RAM needs shrink:

| | one card (HIP or CUDA engine) | two cards, layer split (this repo) |
|---|---|---|
| decode speed (median, long agent sessions) | about 43 tok/s | about 100 tok/s (range 55 to 130) |
| prompt reading | about 240 tok/s | about 560 to 900 tok/s |
| host RAM the engine holds | about 22 GB | about 11 GB working set |

Measured with a 48 GB-class MoE model at an IQ2 quantisation, a 131,072-token window and a PC with
32 GB of RAM, driven by a coding agent. Your numbers will differ with your cards, model and settings.

With `xe0.2.8-1`, a fine-tuned draft layer for the model (see [Updating automatically](#updating-automatically)) and `--pipeline-windows 2`,
the same kind of agent load measured a decode median of 119 to 140 tok/s depending on the GPU clock setting (see
[The clock finding](#the-clock-finding)), peaking above 200 tok/s on repetitive output (code edits, quoted text).

The point of the mixed build is that the stock Windows engines are single-vendor: one is built for
HIP (AMD) and one for CUDA (NVIDIA), and neither can use both cards. Building the engine with the
intel/llvm SYCL compiler for **both** backends gives one executable that drives both.

## What you need

- Windows 10 or 11, 32 GB of RAM or more, fast NVMe storage for the model files
- one AMD GPU supported by the ROCm HIP SDK on Windows, and one NVIDIA GPU (CUDA 12 or 13)
- [ROCm HIP SDK for Windows](https://www.amd.com/en/developer/resources/rocm-hub/hip-sdk.html) and the
  [CUDA Toolkit](https://developer.nvidia.com/cuda-downloads)
- Visual Studio 2022 Build Tools (C++), Git, CMake, Ninja, Python 3, Node.js (for the memory guard)
- a lot of disk (the compiler build is tens of GB) and patience (the compiler build takes hours)

## Recipe

All steps are scripts in `scripts\`, run in order. Each one prints an `EXIT CODE` line; stop if it is not 0.

0. **Get the sources** (not in this repo). Next to this repo clone:
   - `xestrata\`: the XeStrata-win source (its `README.md`, section "Building", is the reference recipe)
   - `intel-llvm\`: `https://github.com/intel/llvm` at tag `v7.1.1`, with the patch series from
     the XeStrata-win recipe applied
   - create a Python venv in `.venv\` with `ninja`
1. Copy `env.example.cmd` to `env.cmd` and edit it: the folders, and **your two GPU architectures**
   (how to find them is written in that file).
2. `scripts\01-configure-llvm.cmd` configures intel/llvm with **both** the HIP and the CUDA backend.
3. `scripts\02-build-llvm.cmd` builds and deploys the toolchain (hours; run it again to resume).
4. `scripts\03-devlibs.cmd` rewrites the `wchar_size` of the ROCm device libraries so the compiler accepts them.
5. `scripts\04-builtins.cmd` installs compiler-rt builtins (needed by the oneMath link step).
6. `scripts\05-smoke-test.cmd` compiles a tiny SYCL program for both GPUs. **It must list both cards
   and compute on each.** If it does not, do not go on.
7. `scripts\06-configure-strata.cmd` and `scripts\07-build-strata.cmd` build the engine for both GPU families.
8. Copy `config\xestrata-mixed.example.json` to `config\xestrata-mixed.json`, fill in your model paths,
   then start the server with `scripts\08-serve.cmd`. It speaks the OpenAI API on port 8097.

### How the two GPUs are used

- `ONEAPI_DEVICE_SELECTOR=hip:0;cuda:0` makes both vendors visible to the SYCL runtime.
- Engine numbering is by memory and compute units: the discrete card with **more memory is engine 0**
  and runs the first layers; the other is engine 1. Check the engine log at start-up, which prints
  the order.
- `--layer-split K --split-device 1` gives layers `K` and up to engine 1. Pick `K` so each card's share
  fits its VRAM; `auto` is also accepted.
- Low-RAM mode: `--mmap-experts --resident-budget-gib 2` leaves the experts that no GPU holds in the
  operating system's page cache instead of a private copy. This is what brings the host RAM down.
  Windows then shows the engine with a large *working set* made of memory-mapped model files. That is
  reclaimable cache, not a leak.

## Things that will bite you (each cost hours)

1. **Compiler build stops near the end** with "Couldn't find the HIP library directory at /opt/rocm/lib".
   The debug sub-build `unified-runtimed` does not get `UR_HIP_*` from the parent configure. Set
   `ROCM_PATH` for the build (done in `02-build-llvm.cmd`). If it already failed once, delete only
   `intel-llvm\build\unified-runtimed\CMakeCache.txt` and rerun.
2. **Why short paths.** XeStrata's `StrataCuda.cmake` passes `--cuda-path=<dir>` through `try_compile`
   unquoted, so `C:\Program Files\...` fails the compiler probe. The scripts hand ROCm and CUDA over
   as 8.3 short paths (`C:\PROGRA~1\...`), derived automatically in `scripts\_env.cmd`.
3. **Do not run a second model on one of the two cards.** The engine sizes its VRAM expert cache to
   fill the card; a helper model next to it (even a small one) leaves too little VRAM and RAM and the
   engine dies with `verify: layer N never rang`.
4. **Native packs need `--spec` of 2 or more**; speculation cannot be switched off for them.
5. **Set a VRAM reserve** (`--vram-reserve-mib`, 1800 in the template) so a few hundred MiB stay
   free after the cache is placed. With none, the card ends up with 0 MiB free.
6. **Memory guard.** `scripts\guard-mem.cjs` kills the server only on real danger (commit total near
   the limit, or available RAM under a threshold for a sustained time). A guard on "available RAM
   under 1 GB" is wrong for this engine: mapped model pages make that normal, and it killed healthy
   servers during large prompts.
7. **Log file for monitoring.** Keep the server's console output in a file (`>> serve.log 2>&1` in the cmd file); tools that show
   live tokens-per-second read it. Starting the server without redirecting its output hides live speed. In our setup a server started
   from a detached process with no console wrote nothing to the redirected log, while the same cmd file started from a normal
   shell did; check that the file grows while the model answers.

## Settings that mattered for stability and speed

| setting | value | why |
|---|---|---|
| `--prefill` | 4096 (the automatic value was 8192) | the larger chunk crashed on long prompts in our runs; 4096 was fastest of 1024, 2048 and 4096 and survived cold 15k-token prompts |
| `--vram-reserve-mib` | 1800 | keeps VRAM free after the expert cache is placed |
| `--spec` | 4 | draft acceptance was about 73 percent |
| `--kv` | `k8v4` | fits a 131k window |
| `reasoning_effort` | `low` in the server config | meant to cut thinking time; we could not measure a clear gain |
| `STRATA_VERIFY_ASYNC_LAUNCH` (environment) | `0` | **the stability fix**: window graphs are launched from the calling thread instead of a helper thread (see below) |
| two other engine flags tried for the crash (`STRATA_MTP_STAGE0=1`, `STRATA_SH_STREAM=0`) | off | no stability benefit; the second cost about 30 percent speed |

## The stability finding

Symptom: in long agent sessions the engine died with `verify: layer N never rang (graph finished)`, a CUDA invalid-context abort, or a GPU wait
that exceeded the hang limit, usually while a large prompt was being read; the next request after a crash also failed while the engine reloaded
(1 to 3 minutes). The same message is reported upstream on single-vendor multi-GPU setups (Strata issue 3813), so mixing vendors is probably
not the cause.

How we found a fix: `test/longsession.cjs` replays an agent-like session against the server (conversations that grow 1 to 4k tokens a turn up to
about 100k tokens, then restart cold) and counts engine failures; each configuration gets a freshly started server and 15 minutes.

| configuration | engine failures in 15 min | requests completed | decode tok/s (median) |
|---|---|---|---|
| unchanged (baseline) | 4 | about 45 | 115 |
| `STRATA_VERIFY_ASYNC_LAUNCH=0` | **0** | 103 | 119 |
| `STRATA_VERIFY_SEGMENTED=1` (windows run as segments) | 0 | 81 | 85 (slower) |
| `STRATA_DF_BRANCH=0` and `STRATA_FETCH_BRANCH=0` | 0 | 101 | 123 |
| `STRATA_VERIFY_RESIDENT_GRAPH=0` | 4 | about 60 | not measured |
| unchanged, repeated | 3 | 14 | not measured |

The baseline failed in every run (three runs), and three variants ran clean. We use `STRATA_VERIFY_ASYNC_LAUNCH=0`: it costs no decode speed and
prompt reading drops by about 8 percent (about 680 against 740 tok/s). Caveats: 15 minutes per setting and one run each is a small sample; we do not know
the exact failure mechanism, only that the helper-thread launch path is involved; run `test/longsession.cjs` yourself for an hour before trusting it.
The supervisor workaround is still worth having for unattended jobs: wake the engine with a one-word request and retry the agent's turn after an error.

## Notes on newer XeStrata and Strata releases

- The port we built from is based on Strata 0.1.45. The newer Windows SYCL port (`xe0.2.2-1`, Strata 0.2.2) builds with the same toolchain, and it has no
  helper-thread launch code at all (the path the fix above switches off), so it may fix the crash on its own. We did not adopt it at the time: with it,
  prompt reading was about 6 times slower (126 against about 800 tok/s) and we could not find the cause.
- Building it natively on Windows: oneMath's rocBLAS and cuBLAS backends are only built on Unix or in a cross build, so a native Windows build silently
  falls back to the engine's own kernels for the prompt matrix products. `patches/onemath-native-windows.md` lists the four CMake conditions that
  need to allow native Windows (plus the cache variables to give). Even with them the prompt speed was not recovered.
- A Strata proposal for layer-major prefill on a CUDA layer split (issue 3976) reports 1.6 to 2.3 times faster prompt reading; it is opt-in, CUDA-only
  and not in an official build.
- **2026-11-01: a later release, `xe0.2.8-1` (Strata 0.2.8), builds and runs correctly** with the same mixed toolchain, and the earlier 6x prompt-speed
  regression is gone — it is now *faster* than our 0.1.45 baseline once tuned (see the results table at the top). We applied the Strata 0.2.9 server-side
  fixes by hand as a patch (`patches/serve-0.2.9-fixes.patch`: tool calls inside a fenced code block are no longer run, and a tool the conversation already
  used still counts as declared on a later turn) since the port had not reached 0.2.9 at the time. `update/strata-multi.ps1` tracks new XeStrata releases,
  builds and tests each one automatically against the mixed toolchain, and keeps it or falls back — see [Updating automatically](#updating-automatically).
- We tried a 1.2 GB DFlash2 block drafter (a separate model, not the engine's own MTP layer) for this model family. It measured **slower** than the stock
  MTP drafter on our RX 7900 XTX in every run (15-27 tok/s against MTP's 17-28 tok/s on the same prompt), and the engine refuses `--draft dflash2` together
  with `--serve` or a layer split anyway, so it cannot run in this mixed, multi-GPU setup. Not adopted.

## Updating automatically

`update\strata-multi.bat` (logic in `update\strata-multi.ps1`) checks MistVVK/XeStrata's `main` branch for a release newer than the one you last ran
(the version is read straight from its `CMakeLists.txt`, so it reacts to a version bump, not every commit), builds it with this repo's toolchain, runs
a test request and a short speed check, and either keeps it as the new "last working version" or reverts to the one before it and tells you why — a
version that fails once is not retried until a newer one appears. On every start it also checks for newer NVIDIA/AMD drivers, CUDA, the ROCm HIP SDK
and intel/llvm, and reports them (never installs); `-Rebuild` builds your current version again against newly installed toolkits, as a separate,
tested version. `-Sessions N` serves N conversations in parallel instead of one pipelined session (see [Multi-session](#multi-session-parallel-requests)).

Copy `update\launcher-settings.example.ps1` to `update\launcher-settings.ps1` and fill in your folders (the toolchain you built with this repo's own
recipe, your Python, your GPU architectures) and the build you already have working (`$SeedVersion`), then run `update\strata-multi.bat`. State
(which version last worked, which failed and why) lives in `state.json` next to the script; each built version gets its own folder and virtual
environment there, so your original build in this repo is never modified.

## The clock finding

An **uncapped** GPU under sustained two-GPU load hard-reset our PC (Kernel-Power 41, no blue screen, no crash dump) within seconds to a few minutes,
repeatably, even on a 1000 W Platinum PSU. Capping the AMD card's power alone only delayed it; capping its **maximum clock** (we used AMD's Overdrive8
API directly, see `update/amd-od8.ps1`) removed the resets in every 15-minute stress test we ran afterward. A single-GPU load was stable uncapped the
whole time, so this is specific to driving both cards at once, not a general instability.

We also tried **locking** the clock (setting the *minimum* equal to the capped maximum, so the card cannot ramp down between bursts and back up on the
next one) on the theory that the rapid ramp itself, not the peak clock, might be what stresses the power delivery path during bursty token-by-token
decode. Locked and ceiling-only capped measured **the same speed** (140 against 138 tok/s decode median, 964 against 947 tok/s prompt reading, same
15-minute test) at the one clock value we could compare directly, so locking costs nothing. We did not get a controlled test of locked against
ceiling-only at a clock *known* to fail ceiling-only, so whether locking buys more headroom than capping alone is still open. If you hit the same kind
of reset, try a clock cap first; `amd-od8.ps1 -Set "9=-10,0=<mhz>"` sets AMD's power and clock ceiling with no administrator rights needed, and
`-Set "1=<mhz>,0=<mhz>"` locks it (setting 1 is the floor, setting 0 is the ceiling, same feature family).

## Multi-session (parallel requests)

The engine's `--batch N` serves several conversations at once instead of one pipelined session (`--pipeline-windows`, which it refuses together with
`--batch`). Measured on our PC, Swift 1.5 IQ2_XS, short prompts, aggregate tok/s (total output / wall time) and per-request decode tok/s:

| configuration | c=1 aggregate / per-req | c=2 aggregate / per-req | c=4 aggregate / per-req |
|---|---|---|---|
| one session, pipelined (no `--batch`) | 75 / 97 | 105 / 134 (queued, not parallel slots) | 99 / 149 (queued) |
| `--batch 2 --batch-groups auto` | 48 / 57 | **crashed** | **crashed** |
| `--batch 2 --batch-groups 1` | 47 / 55 | 79 / 46 | 71 / 46 |
| `--batch 4 --batch-groups auto` | 34 / 39 | **crashed** | **crashed** |
| `--batch 4 --batch-groups 1` | 35 / 40 | 68 / 41 | 66 / 22 |

**`--batch-groups auto` (pipelined slot groups, no per-slot draft layer) crashed reliably the moment a second request arrived**, at both `--batch 2` and
`--batch 4` (confirmed twice each): `verify batch: the window's commit did not finish`, engine exit code 1, auto-restart in 1 to 3 minutes. We did not
find a condition under which it survived concurrency. **`--batch-groups 1` (one slot group, a real per-slot MTP draft layer) was clean** at every
concurrency level we tried. If you use `--batch` on a layer split at all, set `--batch-groups 1` explicitly; do not rely on the `auto` default.

Where it is worth it: aggregate throughput roughly doubles going from 1 to 2 concurrent requests under `--batch-groups 1`, at roughly half the
per-request speed — a reasonable trade for serving two agents instead of one, poor for making a single agent faster (one pipelined session alone
is faster per-request than any batch configuration we measured). `update/strata-multi.ps1 -Sessions N` builds this config for you.

## Layout

```
env.example.cmd             folders and the two GPU architectures (copy to env.cmd)
scripts\01 ... 08           the recipe, in order
scripts\_env.cmd            loads env.cmd, derives short paths, loads the Visual Studio environment
scripts\guard-mem.cjs       memory guard wrapper
test\longsession.cjs        agent-like load that counts engine failures (the crash-rate test)
patches\onemath-native-windows.md   what to change so oneMath's GPU backends build on native Windows
patches\serve-0.2.9-fixes.patch     Strata 0.2.9's server-side fixes, applied by hand to xe0.2.8-1's serve\ (see "Notes on newer releases")
smoke\smoke_ok.cpp          two-GPU SYCL smoke test
config\xestrata-mixed.example.json   server configuration template
update\strata-multi.bat / .ps1   tracks new XeStrata releases, builds, tests and falls back automatically (see "Updating automatically")
update\xu_build.cmd         configure + build one XeStrata tree with this repo's toolchain (called by strata-multi.ps1)
update\amd-od8.ps1          set an AMD card's Overdrive8 power limit and clock cap/lock from the command line, no admin rights needed
update\launcher-settings.example.ps1   per-PC settings for strata-multi.ps1 (copy to launcher-settings.ps1 and edit)
```

## License and credits

The scripts and notes in this repository are released under the MIT License. Strata, XeStrata-win,
intel/llvm, ROCm and CUDA are separate projects under their own licenses; check them before you
redistribute binaries. Thanks to the authors of Strata, of the Windows SYCL port, and of the
intel/llvm SYCL compiler.

The fine-tuned MTP draft layer mentioned in the results above is [Hardin22/Strata-DualGPU](https://github.com/Hardin22/Strata-DualGPU)'s
`swift15-mtp-ft2`, fine-tuned for this model's own outputs with a wider draft vocabulary; it is not redistributed here and keeps the Qwen and
Swift licenses it ships with — see that repository for the file and its terms.
