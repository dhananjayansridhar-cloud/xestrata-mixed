@echo off
rem Step 3: rewrite the wchar_size of the ROCm device libraries so the intel/llvm compiler accepts them.
call "%~dp0_env.cmd" || exit /b 1
set "PATH=%XM_ROOT%\.venv\Scripts;%XM_ROOT%\intel-llvm\build\bin;%PATH%"
cd /d "%XM_ROOT%\intel-llvm" || exit /b 1
if not exist build\bin\llvm-dis.exe cmake --build build --target llvm-dis -j %XM_JOBS%
cd /d "%XM_ROOT%\xestrata" || exit /b 1
"%XM_ROOT%\.venv\Scripts\python.exe" tools\windows\device_libs_wchar.py "%XM_ROOT%\intel-llvm\build\bin" "%XM_ROCM%\amdgcn\bitcode" "%XM_ROOT%\device-libs"
echo DEVLIBS EXIT CODE %ERRORLEVEL%
exit /b %ERRORLEVEL%
