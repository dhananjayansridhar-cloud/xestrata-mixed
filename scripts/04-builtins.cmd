@echo off
rem Step 4: build and install compiler-rt builtins into the toolchain (XeStrata's oneMath link step needs clang_rt.builtins.lib).
call "%~dp0_env.cmd" || exit /b 1
set "ROCM_PATH=%XM_ROCM_S%"
set "PATH=%XM_ROOT%\.venv\Scripts;%PATH%"
cd /d "%XM_ROOT%\intel-llvm" || exit /b 1
cmake --build build --target builtins -j %XM_JOBS%
cmake --build build --target install-builtins
echo BUILTINS EXIT CODE %ERRORLEVEL%
exit /b %ERRORLEVEL%
