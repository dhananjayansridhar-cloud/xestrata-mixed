@echo off
rem Step 7: build the engine for both GPU families.
call "%~dp0_env.cmd" || exit /b 1
set "ROCM_PATH=%XM_ROCM_S%"
set "CUDA_PATH=%XM_CUDA_S%"
set "PATH=%XM_ROOT%\.venv\Scripts;%XM_ROOT%\intel-llvm\install\bin;%XM_ROCM_S%\bin;%PATH%"
cd /d "%XM_ROOT%\xestrata" || exit /b 1
cmake --build build\mixed --target strata -j %XM_JOBS%
echo BUILD EXIT CODE %ERRORLEVEL%
exit /b %ERRORLEVEL%
