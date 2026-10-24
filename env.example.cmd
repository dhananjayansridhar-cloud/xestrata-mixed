@echo off
rem Copy this file to env.cmd and edit it. Every script in scripts\ calls it.
rem Use real paths of YOUR machine. The two GPU architecture values are the only hardware-specific part.

rem Folder that holds everything (this repo, intel-llvm\, xestrata\, device-libs\, .venv\):
set "XM_ROOT=C:\xestrata-mixed"

rem Visual Studio Build Tools 2022 environment script:
set "XM_VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"

rem ROCm (HIP SDK) and CUDA Toolkit install folders. Normal paths here; the scripts derive the 8.3 short
rem form themselves (see README, "Why short paths").
set "XM_ROCM=C:\Program Files\AMD\ROCm\7.2"
set "XM_CUDA=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.3"

rem GPU architectures to compile for. Find yours:
rem   AMD:    hipinfo  (field gcnArchName, e.g. gfx1030, gfx1100, gfx1201)  or  rocminfo
rem   NVIDIA: nvidia-smi --query-gpu=compute_cap --format=csv   (8.6 -> sm_86, 8.9 -> sm_89, 12.0 -> sm_120)
set "XM_HIP_ARCH=gfxXXXX"
set "XM_CUDA_ARCH=sm_XX"

rem Parallel build jobs (the LLVM build is heavy: 8 is fine with 32 GB RAM):
set "XM_JOBS=8"
