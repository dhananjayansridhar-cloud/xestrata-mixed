# XeStrata-mixed: run one big MoE model across an AMD GPU and an NVIDIA GPU on Windows

This repository is the glue for running **one model on two GPUs from different vendors at the same time**
(for example one AMD card and one NVIDIA card in the same PC), using the
[Strata](https://github.com/Niko1221/Strata) engine through its Windows SYCL port
[XeStrata-win](https://github.com/32x-k/XeStrata-win).

It contains build scripts, a server configuration template, a memory guard and the notes that cost
the most time to find. It does **not** contain the engine, the compiler or any model: those are
separate projects with their own licenses.

> Status: it works and is fast, but it is **not fully stable yet** (see [Known issues](#known-issues)).
> Treat it as a tested recipe, not a finished product.

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
7. **Log file for monitoring.** Keep the server's console output in a file; tools that show live
   tokens-per-second read it. Starting the server without redirecting its output hides live speed.

## Settings that mattered for stability and speed

| setting | value | why |
|---|---|---|
| `--prefill` | 4096 (the automatic value was 8192) | the larger chunk crashed on long prompts in our runs; 4096 was fastest of 1024, 2048 and 4096 and survived cold 15k-token prompts |
| `--vram-reserve-mib` | 1800 | keeps VRAM free after the expert cache is placed |
| `--spec` | 4 | draft acceptance was about 73 percent |
| `--kv` | `k8v4` | fits a 131k window |
| `reasoning_effort` | `low` in the server config | meant to cut thinking time; we could not measure a clear gain |
| two optional engine flags tried for the crash (`STRATA_MTP_STAGE0=1`, `STRATA_SH_STREAM=0`) | off | no stability benefit; the second cost about 30 percent speed |

## Known issues

- **Intermittent engine failure in long agent sessions**: `verify: layer N never rang`, a CUDA
  invalid-context abort, or a GPU wait that exceeds the hang limit, usually while reading a large
  prompt. In our runs it hit about every 15 to 30 minutes of agent work and about 1 in 4 cold large
  prompts at the larger chunk sizes. After a crash the first request fails and the engine reloads
  in 1 to 3 minutes. The same message has been reported upstream on single-vendor multi-GPU setups
  (Strata issue 3813), so it is probably not caused by mixing vendors.
- Workaround we use: a supervisor script that wakes the engine with a one-word request and retries the
  agent's turn. If you automate long jobs, do the same.
- Our port is based on Strata 0.1.45. Newer upstream engines (0.1.48 and later) contain verify-path
  fixes that we have not merged yet.

## Layout

```
env.example.cmd             folders and the two GPU architectures (copy to env.cmd)
scripts\01 ... 08           the recipe, in order
scripts\_env.cmd            loads env.cmd, derives short paths, loads the Visual Studio environment
scripts\guard-mem.cjs       memory guard wrapper
smoke\smoke_ok.cpp          two-GPU SYCL smoke test
config\xestrata-mixed.example.json   server configuration template
```

## License and credits

The scripts and notes in this repository are released under the MIT License. Strata, XeStrata-win,
intel/llvm, ROCm and CUDA are separate projects under their own licenses; check them before you
redistribute binaries. Thanks to the authors of Strata, of the Windows SYCL port, and of the
intel/llvm SYCL compiler.
