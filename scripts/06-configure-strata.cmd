@echo off
rem Step 6: configure XeStrata itself in contrib mode with one AMD and one NVIDIA target.
rem Short (8.3) paths for ROCm and CUDA: StrataCuda.cmake passes --cuda-path through try_compile unquoted, so a path with spaces fails.
call "%~dp0_env.cmd" || exit /b 1
set "ROCM_PATH=%XM_ROCM_S%"
set "CUDA_PATH=%XM_CUDA_S%"
set "PATH=%XM_ROOT%\.venv\Scripts;%XM_ROOT%\intel-llvm\install\bin;%PATH%"
cd /d "%XM_ROOT%\xestrata" || exit /b 1
if exist build\mixed rmdir /s /q build\mixed
cmake -S . -B build\mixed -G Ninja -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_C_COMPILER=%XM_ROOT_FWD%/intel-llvm/install/bin/clang.exe ^
  -DCMAKE_CXX_COMPILER=%XM_ROOT_FWD%/intel-llvm/install/bin/clang++.exe ^
  -DSTRATA_LICENSE=contrib -DSTRATA_HIP_ARCHS=%XM_HIP_ARCH% -DSTRATA_CUDA_ARCHS=%XM_CUDA_ARCH% -DSTRATA_ONEMKL=OFF ^
  -DSTRATA_CUDA_PATH=%XM_CUDA_S_FWD% ^
  -DSTRATA_ROCM_DEVICE_LIBS=%XM_ROOT_FWD%/device-libs -DSTRATA_ROCM_ROOT=%XM_ROCM_S_FWD% ^
  -DSTRATA_ENABLE_ONEMATH=ON -DCMAKE_PREFIX_PATH=%XM_ROCM_S_FWD% -DHIP_PATH=%XM_ROCM_S_FWD% ^
  -DCUDAToolkit_ROOT=%XM_CUDA_S_FWD% ^
  -DSTRATA_BUILD_TESTS=OFF -DSTRATA_PACKAGE=OFF
echo CONFIGURE EXIT CODE %ERRORLEVEL%
exit /b %ERRORLEVEL%
