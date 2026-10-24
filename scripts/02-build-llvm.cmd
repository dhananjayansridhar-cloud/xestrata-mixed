@echo off
rem Step 2: build and deploy the SYCL toolchain (hours; restartable: run it again and it continues).
call "%~dp0_env.cmd" || exit /b 1
rem The debug-variant sub-build (unified-runtimed) does not receive UR_HIP_* from the parent configure;
rem the HIP adapter reads ROCM_PATH as its default. Without this the build stops near the end.
set "ROCM_PATH=%XM_ROCM%"
set "PATH=%XM_ROOT%\.venv\Scripts;%PATH%"
cd /d "%XM_ROOT%\intel-llvm" || exit /b 1
cmake --build build --target deploy-sycl-toolchain -j %XM_JOBS%
echo BUILD EXIT CODE %ERRORLEVEL%
exit /b %ERRORLEVEL%
