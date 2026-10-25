# oneMath's rocBLAS and cuBLAS backends on a native Windows build

Applies to the downloaded oneMath copy that XeStrata fetches into `build\mixed\_deps\strata_onemath-src` (the Windows SYCL port, release `xe0.2.2-1`).
oneMath builds its rocBLAS and cuBLAS backends only on Unix or when cross-compiling, so a native Windows build configures fine but silently falls back to the
engine's own kernels for the prompt matrix products (the engine prints "Couldn't load selected backend" at start-up).

Four conditions to change (originals are worth keeping as `.orig`):

| file | before | after |
|---|---|---|
| `src/blas/backends/CMakeLists.txt` | `if(ENABLE_CUBLAS_BACKEND AND (UNIX OR CMAKE_CROSSCOMPILING))` | `... (UNIX OR CMAKE_CROSSCOMPILING OR WIN32))` |
| `src/blas/backends/CMakeLists.txt` | `if(ENABLE_ROCBLAS_BACKEND AND (UNIX OR CMAKE_CROSSCOMPILING))` | `... (UNIX OR CMAKE_CROSSCOMPILING OR WIN32))` |
| `src/blas/backends/rocblas/CMakeLists.txt` | `if(CMAKE_CROSSCOMPILING AND WIN32 AND ROCM_WINDOWS_INCLUDE ...` | `if(WIN32 AND ROCM_WINDOWS_INCLUDE ...` |
| `cmake/FindcuBLAS.cmake` | `if(CMAKE_CROSSCOMPILING AND WIN32 AND CUDA_cublas_LIBRARY ...` | `if(WIN32 AND CUDA_cublas_LIBRARY ...` |

Then give the engine's configure step the import libraries it expects (any layout with the same file names works):

- `-DSTRATA_ROCM_WINDOWS_LIBS=<ROCm folder>` (needs `lib\rocblas.lib` and `lib\hipblaslt.lib`; the HIP import library is looked up next to `STRATA_SYCL_WINDOWS\..\hip\lib\amdhip64.lib`)
- `-DSTRATA_SYCL_WINDOWS=<folder>` whose sibling `hip\` has `lib\amdhip64.lib` and an `include` junction to ROCm's headers
- `-DSTRATA_CUDA_WINDOWS_LIBS=<folder>` containing `cublas.lib`, `cudart.lib`, `cuda.lib` and an `include` junction to the CUDA toolkit's headers

After a rebuild the engine log should say "prompt matrix products on oneMath (rocBLAS)" and "(cuBLAS)". In our tests this made the backends load but did not
recover prompt-reading speed on that release; the cause was not found, so treat this as a build note, not a speed fix.
