@echo off
rem Loads env.cmd, checks it was edited, and derives the 8.3 short paths. Called by the other scripts.
if not exist "%~dp0..\env.cmd" ( echo env.cmd not found: copy env.example.cmd to env.cmd and edit it & exit /b 1 )
call "%~dp0..\env.cmd"
if /i "%XM_HIP_ARCH%"=="gfxXXXX" ( echo Edit XM_HIP_ARCH in env.cmd & exit /b 1 )
if /i "%XM_CUDA_ARCH%"=="sm_XX" ( echo Edit XM_CUDA_ARCH in env.cmd & exit /b 1 )
for %%I in ("%XM_ROCM%") do set "XM_ROCM_S=%%~sI"
for %%I in ("%XM_CUDA%") do set "XM_CUDA_S=%%~sI"
set "XM_ROCM_FWD=%XM_ROCM:\=/%"
set "XM_CUDA_FWD=%XM_CUDA:\=/%"
set "XM_ROCM_S_FWD=%XM_ROCM_S:\=/%"
set "XM_CUDA_S_FWD=%XM_CUDA_S:\=/%"
set "XM_ROOT_FWD=%XM_ROOT:\=/%"
call "%XM_VCVARS%" || exit /b 1
