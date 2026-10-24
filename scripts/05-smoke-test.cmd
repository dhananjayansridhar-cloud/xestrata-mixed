@echo off
rem Step 5: compile and run a tiny SYCL program for both GPUs; it must list both and compute on each.
call "%~dp0_env.cmd" || exit /b 1
set "ROCM_PATH=%XM_ROCM%"
set "CUDA_PATH=%XM_CUDA%"
set "PATH=%XM_ROOT%\intel-llvm\build\bin;%PATH%"
cd /d "%~dp0..\smoke" || exit /b 1
clang++.exe -fsycl -fsycl-targets=amd_gpu_%XM_HIP_ARCH%,nvidia_gpu_%XM_CUDA_ARCH% -o smoke_ok.exe smoke_ok.cpp || exit /b 1
.\smoke_ok.exe
echo SMOKE EXIT CODE %ERRORLEVEL%
exit /b %ERRORLEVEL%
