@echo off
rem Step 1: configure intel/llvm (tag v7.1.1, patched as in the XeStrata-win recipe) with BOTH the HIP and the CUDA backend.
call "%~dp0_env.cmd" || exit /b 1
set "PATH=%XM_ROOT%\.venv\Scripts;%PATH%"
cd /d "%XM_ROOT%\intel-llvm" || exit /b 1
if exist build rmdir /s /q build
"%XM_ROOT%\.venv\Scripts\python.exe" buildbot\configure.py -o build -t Release --cuda --hip --hip-platform AMD ^
 "--cmake-opt=-DCMAKE_INSTALL_PREFIX=%XM_ROOT_FWD%/intel-llvm/install" ^
 "--cmake-opt=-DUR_HIP_ROCM_DIR=%XM_ROCM_FWD%" ^
 "--cmake-opt=-DUR_HIP_LIB_DIR=%XM_ROCM_FWD%/lib" ^
 "--cmake-opt=-DLIBCLC_TARGETS_TO_BUILD=amdgcn--amdhsa;nvptx64--nvidiacl" ^
 "--cmake-opt=-DSYCL_ENABLE_BACKENDS=hip;level_zero;cuda" ^
 "--cmake-opt=-DLLVM_ENABLE_DIA_SDK=OFF" ^
 "--cmake-opt=-DCUDAToolkit_ROOT=%XM_CUDA_FWD%" ^
 "--cmake-opt=-DCMAKE_C_FLAGS=/DWIN32 /D_WINDOWS /utf-8 /d1trimfile:%XM_ROOT%\intel-llvm" ^
 "--cmake-opt=-DCMAKE_CXX_FLAGS=/DWIN32 /D_WINDOWS /GR /EHsc /utf-8 /d1trimfile:%XM_ROOT%\intel-llvm"
echo CONFIGURE EXIT CODE %ERRORLEVEL%
exit /b %ERRORLEVEL%
