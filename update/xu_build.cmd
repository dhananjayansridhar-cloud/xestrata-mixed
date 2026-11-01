@echo off
rem Configure + build an XeStrata tree (MistVVK/XeStrata) for one AMD and one NVIDIA GPU with the mixed HIP+CUDA intel/llvm toolchain
rem (used read-only). Called by strata-multi.ps1, which sets the XU_* variables from launcher-settings.ps1.
rem Usage: xu_build.cmd <tree folder name under XU_ROOT> [jobs] [build dir, default build\mixed]
rem Toolkits: XU_CUDA / XU_ROCM (8.3 short paths, no spaces) override the defaults (strata-multi -Rebuild sets them).
setlocal
rem Called by strata-multi.ps1, which sets every XU_* variable below from launcher-settings.ps1 (copy
rem launcher-settings.example.ps1). If you run this script on its own, set the same variables yourself first.
if "%XU_ROOT%"=="" ( echo XU_ROOT not set: run this through strata-multi.ps1, or set the XU_* variables yourself & exit /b 1 )
if "%XU_TOOLCHAIN%"=="" ( echo XU_TOOLCHAIN not set & exit /b 1 )
if "%XU_NINJA_DIR%"=="" ( echo XU_NINJA_DIR not set & exit /b 1 )
if "%XU_DEVICE_LIBS%"=="" ( echo XU_DEVICE_LIBS not set & exit /b 1 )
if "%XU_VCVARS%"=="" set "XU_VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if "%XU_HIP_ARCH%"=="" ( echo XU_HIP_ARCH not set: your AMD card's gfx architecture, see env.example.cmd & exit /b 1 )
if "%XU_CUDA_ARCH%"=="" ( echo XU_CUDA_ARCH not set: your NVIDIA card's sm_ architecture, see env.example.cmd & exit /b 1 )
if "%XU_TEMP%"=="" set "XU_TEMP=%XU_ROOT%\tmp"
if "%XU_CUDA%"=="" ( echo XU_CUDA not set: your CUDA Toolkit's 8.3 short path & exit /b 1 )
if "%XU_ROCM%"=="" ( echo XU_ROCM not set: your ROCm HIP SDK's 8.3 short path & exit /b 1 )
set "TREE=%XU_ROOT%\%~1"
set "JOBS=%~2"
if "%JOBS%"=="" set "JOBS=3"
set "BDIR=%~3"
if "%BDIR%"=="" set "BDIR=build\mixed"
set "XU_CUDA_F=%XU_CUDA:\=/%"
set "XU_ROCM_F=%XU_ROCM:\=/%"
set "XU_TC_F=%XU_TOOLCHAIN:\=/%"
set "XU_DL_F=%XU_DEVICE_LIBS:\=/%"
if not exist "%TREE%\CMakeLists.txt" ( echo no tree at %TREE% & exit /b 1 )
call "%XU_VCVARS%" >nul || exit /b 1
set "ROCM_PATH=%XU_ROCM%"
set "CUDA_PATH=%XU_CUDA%"
set "PATH=%XU_NINJA_DIR%;%XU_TOOLCHAIN%\bin;%XU_ROCM%\bin;%PATH%"
set "TEMP=%XU_TEMP%"
set "TMP=%XU_TEMP%"
if not exist "%TEMP%" mkdir "%TEMP%"
cd /d "%TREE%" || exit /b 1
echo XU BUILD of %TREE% into %BDIR% with CUDA %XU_CUDA%, ROCm %XU_ROCM%, %XU_HIP_ARCH% + %XU_CUDA_ARCH%
if not exist %BDIR%\build.ninja (
  cmake -S . -B %BDIR% -G Ninja -DCMAKE_BUILD_TYPE=Release ^
    -DCMAKE_C_COMPILER=%XU_TC_F%/bin/clang.exe ^
    -DCMAKE_CXX_COMPILER=%XU_TC_F%/bin/clang++.exe ^
    -DSTRATA_LICENSE=contrib -DSTRATA_HIP_ARCHS=%XU_HIP_ARCH% -DSTRATA_CUDA_ARCHS=%XU_CUDA_ARCH% -DSTRATA_ONEMKL=OFF ^
    -DSTRATA_CUDA_PATH=%XU_CUDA_F% ^
    -DSTRATA_ROCM_DEVICE_LIBS=%XU_DL_F% ^
    -DCMAKE_PREFIX_PATH=%XU_ROCM_F% -DHIP_PATH=%XU_ROCM_F% ^
    -DCUDAToolkit_ROOT=%XU_CUDA_F% ^
    -DSTRATA_BUILD_TESTS=OFF -DSTRATA_PACKAGE=OFF
  if errorlevel 1 ( echo XU CONFIGURE EXIT CODE 1 & exit /b 1 )
  echo XU CONFIGURE EXIT CODE 0
)
cmake --build %BDIR% --target strata -j %JOBS%
echo XU BUILD EXIT CODE %ERRORLEVEL%
exit /b %ERRORLEVEL%
