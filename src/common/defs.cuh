// Common definitions shared by host and device code.
#pragma once

#include <stdint.h>
#include <stddef.h>

#if defined(__CUDACC__)
#define FEVM_HD __host__ __device__ __forceinline__
#define FEVM_HDN inline __host__ __device__ __noinline__
#define FEVM_DEV __device__
#else
#define FEVM_HD inline __attribute__((always_inline))
#define FEVM_HDN inline __attribute__((noinline))
#define FEVM_DEV
#endif

#if defined(__CUDA_ARCH__)
#define FEVM_ON_DEVICE 1
#else
#define FEVM_ON_DEVICE 0
#endif

#define FEVM_LIKELY(x) __builtin_expect(!!(x), 1)
#define FEVM_UNLIKELY(x) __builtin_expect(!!(x), 0)

namespace fevm {

typedef unsigned __int128 u128;

FEVM_HD void mem_copy(void* dst, const void* src, size_t n) {
  uint8_t* d = (uint8_t*)dst;
  const uint8_t* s = (const uint8_t*)src;
  for (size_t i = 0; i < n; i++) d[i] = s[i];
}

FEVM_HD void mem_move(void* dst, const void* src, size_t n) {
  uint8_t* d = (uint8_t*)dst;
  const uint8_t* s = (const uint8_t*)src;
  if (d == s || n == 0) return;
  if (d < s) {
    for (size_t i = 0; i < n; i++) d[i] = s[i];
  } else {
    for (size_t i = n; i > 0; i--) d[i - 1] = s[i - 1];
  }
}

FEVM_HD void mem_zero(void* dst, size_t n) {
  uint8_t* d = (uint8_t*)dst;
  for (size_t i = 0; i < n; i++) d[i] = 0;
}

FEVM_HD bool mem_eq(const void* a, const void* b, size_t n) {
  const uint8_t* x = (const uint8_t*)a;
  const uint8_t* y = (const uint8_t*)b;
  for (size_t i = 0; i < n; i++)
    if (x[i] != y[i]) return false;
  return true;
}

FEVM_HD uint64_t min_u64(uint64_t a, uint64_t b) { return a < b ? a : b; }
FEVM_HD uint64_t max_u64(uint64_t a, uint64_t b) { return a > b ? a : b; }

FEVM_HD int clz64(uint64_t x) {
#if FEVM_ON_DEVICE
  return __clzll((long long)x);
#else
  return x == 0 ? 64 : __builtin_clzll(x);
#endif
}

FEVM_HD uint64_t load_be64(const uint8_t* p) {
  uint64_t v = 0;
  for (int i = 0; i < 8; i++) v = (v << 8) | p[i];
  return v;
}

FEVM_HD void store_be64(uint8_t* p, uint64_t v) {
  for (int i = 7; i >= 0; i--) {
    p[i] = (uint8_t)v;
    v >>= 8;
  }
}

FEVM_HD uint64_t load_le64(const uint8_t* p) {
  uint64_t v = 0;
  for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
  return v;
}

FEVM_HD void store_le64(uint8_t* p, uint64_t v) {
  for (int i = 0; i < 8; i++) {
    p[i] = (uint8_t)v;
    v >>= 8;
  }
}

}  // namespace fevm
