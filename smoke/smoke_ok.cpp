// Smoke test for the mixed HIP + CUDA SYCL toolchain: list every GPU with its backend, then run a vector add on each one.
// (Replaces the supervisor-rejected list_devices.cpp, which called a function that does not exist in SYCL.)
#include <sycl/sycl.hpp>
#include <cmath>
#include <iostream>
#include <vector>

int main() {
  int failures = 0, gpus = 0;
  for (auto &plat : sycl::platform::get_platforms()) {
    for (auto &dev : plat.get_devices()) {
      if (!dev.is_gpu()) continue;
      ++gpus;
      std::cout << "GPU " << gpus << ": " << dev.get_info<sycl::info::device::name>() << " | backend " << plat.get_info<sycl::info::platform::name>() << std::endl;
      try {
        sycl::queue q{dev};
        const size_t N = 1 << 20;
        std::vector<float> a(N), b(N), c(N, -1.f);
        for (size_t i = 0; i < N; ++i) { a[i] = float(i % 1000); b[i] = float((i * 7) % 13); }
        float *da = sycl::malloc_device<float>(N, q), *db = sycl::malloc_device<float>(N, q), *dc = sycl::malloc_device<float>(N, q);
        q.memcpy(da, a.data(), N * sizeof(float));
        q.memcpy(db, b.data(), N * sizeof(float)).wait();
        q.parallel_for(sycl::range<1>(N), [=](sycl::id<1> i) { dc[i] = da[i] + db[i]; }).wait();
        q.memcpy(c.data(), dc, N * sizeof(float)).wait();
        sycl::free(da, q); sycl::free(db, q); sycl::free(dc, q);
        size_t bad = 0;
        for (size_t i = 0; i < N; ++i) if (std::fabs(c[i] - (a[i] + b[i])) > 1e-3f) ++bad;
        std::cout << "  vector add of " << N << " floats: " << (bad ? "FAILED, wrong values: " + std::to_string(bad) : std::string("OK")) << std::endl;
        if (bad) ++failures;
      } catch (const sycl::exception &e) {
        std::cout << "  SYCL exception: " << e.what() << std::endl;
        ++failures;
      }
    }
  }
  std::cout << "gpus found: " << gpus << ", failures: " << failures << std::endl;
  return (gpus >= 2 && failures == 0) ? 0 : 1;
}
