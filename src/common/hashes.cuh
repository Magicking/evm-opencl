// SHA-256, RIPEMD-160 and BLAKE2b compression (EIP-152), usable on host and device.
#pragma once

#include "defs.cuh"

namespace fevm {

FEVM_HD uint32_t rotr32(uint32_t x, int s) { return (x >> s) | (x << (32 - s)); }
FEVM_HD uint32_t rotl32(uint32_t x, int s) { return (x << s) | (x >> (32 - s)); }
FEVM_HD uint64_t rotr64(uint64_t x, int s) { return (x >> s) | (x << (64 - s)); }

// ---------------------------------------------------------------- SHA-256

FEVM_HDN void sha256_block(uint32_t h[8], const uint8_t* blk) {
  const uint32_t K[64] = {
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
      0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
      0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
      0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
      0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
      0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
  uint32_t w[64];
  for (int i = 0; i < 16; i++)
    w[i] = ((uint32_t)blk[4 * i] << 24) | ((uint32_t)blk[4 * i + 1] << 16) | ((uint32_t)blk[4 * i + 2] << 8) |
           blk[4 * i + 3];
  for (int i = 16; i < 64; i++) {
    uint32_t s0 = rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3);
    uint32_t s1 = rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
  for (int i = 0; i < 64; i++) {
    uint32_t S1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25);
    uint32_t ch = (e & f) ^ (~e & g);
    uint32_t t1 = hh + S1 + ch + K[i] + w[i];
    uint32_t S0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22);
    uint32_t mj = (a & b) ^ (a & c) ^ (b & c);
    uint32_t t2 = S0 + mj;
    hh = g;
    g = f;
    f = e;
    e = d + t1;
    d = c;
    c = b;
    b = a;
    a = t1 + t2;
  }
  h[0] += a;
  h[1] += b;
  h[2] += c;
  h[3] += d;
  h[4] += e;
  h[5] += f;
  h[6] += g;
  h[7] += hh;
}

FEVM_HDN void sha256(const uint8_t* data, size_t len, uint8_t out[32]) {
  uint32_t h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
  size_t full = len / 64;
  for (size_t i = 0; i < full; i++) sha256_block(h, data + i * 64);
  uint8_t blk[128];
  size_t rem = len - full * 64;
  for (size_t i = 0; i < 128; i++) blk[i] = 0;
  for (size_t i = 0; i < rem; i++) blk[i] = data[full * 64 + i];
  blk[rem] = 0x80;
  size_t tot = rem + 9 <= 64 ? 64 : 128;
  uint64_t bits = (uint64_t)len * 8;
  store_be64(blk + tot - 8, bits);
  sha256_block(h, blk);
  if (tot == 128) sha256_block(h, blk + 64);
  for (int i = 0; i < 8; i++) {
    out[4 * i] = (uint8_t)(h[i] >> 24);
    out[4 * i + 1] = (uint8_t)(h[i] >> 16);
    out[4 * i + 2] = (uint8_t)(h[i] >> 8);
    out[4 * i + 3] = (uint8_t)h[i];
  }
}

// ---------------------------------------------------------------- RIPEMD-160

FEVM_HDN void ripemd160_block(uint32_t h[5], const uint8_t* blk) {
  const uint8_t RL[80] = {0, 1, 2,  3,  4,  5,  6,  7,  8, 9,  10, 11, 12, 13, 14, 15, 7,  4,  13, 1,
                          10, 6, 15, 3,  12, 0,  9,  5,  2, 14, 11, 8,  3,  10, 14, 4,  9,  15, 8,  1,
                          2,  7, 0,  6,  13, 11, 5,  12, 1, 9,  11, 10, 0,  8,  12, 4,  13, 3,  7,  15,
                          14, 5, 6,  2,  4,  0,  5,  9,  7, 12, 2,  10, 14, 1,  3,  8,  11, 6,  15, 13};
  const uint8_t RR[80] = {5,  14, 7,  0, 9, 2,  11, 4,  13, 6,  15, 8,  1,  10, 3,  12, 6,  11, 3,  7,
                          0,  13, 5,  10, 14, 15, 8,  12, 4,  9,  1,  2,  15, 5,  1,  3,  7,  14, 6,  9,
                          11, 8,  12, 2,  10, 0,  4,  13, 8,  6,  4,  1,  3,  11, 15, 0,  5,  12, 2,  13,
                          9,  7,  10, 14, 12, 15, 10, 4,  1,  5,  8,  7,  6,  2,  13, 14, 0,  3,  9,  11};
  const uint8_t SL[80] = {11, 14, 15, 12, 5,  8,  7,  9,  11, 13, 14, 15, 6,  7,  9,  8,  7,  6,  8,  13,
                          11, 9,  7,  15, 7,  12, 15, 9,  11, 7,  13, 12, 11, 13, 6,  7,  14, 9,  13, 15,
                          14, 8,  13, 6,  5,  12, 7,  5,  11, 12, 14, 15, 14, 15, 9,  8,  9,  14, 5,  6,
                          8,  6,  5,  12, 9,  15, 5,  11, 6,  8,  13, 12, 5,  12, 13, 14, 11, 8,  5,  6};
  const uint8_t SR[80] = {8,  9,  9,  11, 13, 15, 15, 5,  7,  7,  8,  11, 14, 14, 12, 6,  9,  13, 15, 7,
                          12, 8,  9,  11, 7,  7,  12, 7,  6,  15, 13, 11, 9,  7,  15, 11, 8,  6,  6,  14,
                          12, 13, 5,  14, 13, 13, 7,  5,  15, 5,  8,  11, 14, 14, 6,  14, 6,  9,  12, 9,
                          12, 5,  15, 8,  8,  5,  12, 9,  12, 5,  14, 6,  8,  13, 6,  5,  15, 13, 11, 11};
  const uint32_t KL[5] = {0x00000000, 0x5a827999, 0x6ed9eba1, 0x8f1bbcdc, 0xa953fd4e};
  const uint32_t KR[5] = {0x50a28be6, 0x5c4dd124, 0x6d703ef3, 0x7a6d76e9, 0x00000000};
  uint32_t X[16];
  for (int i = 0; i < 16; i++)
    X[i] = (uint32_t)blk[4 * i] | ((uint32_t)blk[4 * i + 1] << 8) | ((uint32_t)blk[4 * i + 2] << 16) |
           ((uint32_t)blk[4 * i + 3] << 24);
  uint32_t al = h[0], bl = h[1], cl = h[2], dl = h[3], el = h[4];
  uint32_t ar = h[0], br = h[1], cr = h[2], dr = h[3], er = h[4];
  for (int j = 0; j < 80; j++) {
    int r = j / 16;
    uint32_t fl, fr;
    switch (r) {
      case 0: fl = bl ^ cl ^ dl; fr = br ^ (cr | ~dr); break;
      case 1: fl = (bl & cl) | (~bl & dl); fr = (br & dr) | (cr & ~dr); break;
      case 2: fl = (bl | ~cl) ^ dl; fr = (br | ~cr) ^ dr; break;
      case 3: fl = (bl & dl) | (cl & ~dl); fr = (br & cr) | (~br & dr); break;
      default: fl = bl ^ (cl | ~dl); fr = br ^ cr ^ dr; break;
    }
    uint32_t t = rotl32(al + fl + X[RL[j]] + KL[r], SL[j]) + el;
    al = el; el = dl; dl = rotl32(cl, 10); cl = bl; bl = t;
    t = rotl32(ar + fr + X[RR[j]] + KR[r], SR[j]) + er;
    ar = er; er = dr; dr = rotl32(cr, 10); cr = br; br = t;
  }
  uint32_t t = h[1] + cl + dr;
  h[1] = h[2] + dl + er;
  h[2] = h[3] + el + ar;
  h[3] = h[4] + al + br;
  h[4] = h[0] + bl + cr;
  h[0] = t;
}

FEVM_HDN void ripemd160(const uint8_t* data, size_t len, uint8_t out[20]) {
  uint32_t h[5] = {0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0};
  size_t full = len / 64;
  for (size_t i = 0; i < full; i++) ripemd160_block(h, data + i * 64);
  uint8_t blk[128];
  size_t rem = len - full * 64;
  for (size_t i = 0; i < 128; i++) blk[i] = 0;
  for (size_t i = 0; i < rem; i++) blk[i] = data[full * 64 + i];
  blk[rem] = 0x80;
  size_t tot = rem + 9 <= 64 ? 64 : 128;
  store_le64(blk + tot - 8, (uint64_t)len * 8);
  ripemd160_block(h, blk);
  if (tot == 128) ripemd160_block(h, blk + 64);
  for (int i = 0; i < 5; i++) {
    out[4 * i] = (uint8_t)h[i];
    out[4 * i + 1] = (uint8_t)(h[i] >> 8);
    out[4 * i + 2] = (uint8_t)(h[i] >> 16);
    out[4 * i + 3] = (uint8_t)(h[i] >> 24);
  }
}

// ---------------------------------------------------------------- BLAKE2b F (EIP-152)

FEVM_HD void blake2_g(uint64_t* v, int a, int b, int c, int d, uint64_t x, uint64_t y) {
  v[a] = v[a] + v[b] + x;
  v[d] = rotr64(v[d] ^ v[a], 32);
  v[c] = v[c] + v[d];
  v[b] = rotr64(v[b] ^ v[c], 24);
  v[a] = v[a] + v[b] + y;
  v[d] = rotr64(v[d] ^ v[a], 16);
  v[c] = v[c] + v[d];
  v[b] = rotr64(v[b] ^ v[c], 63);
}

FEVM_HDN void blake2b_f(uint32_t rounds, uint64_t h[8], const uint64_t m[16], const uint64_t t[2], bool f) {
  const uint64_t IV[8] = {0x6a09e667f3bcc908ull, 0xbb67ae8584caa73bull, 0x3c6ef372fe94f82bull,
                          0xa54ff53a5f1d36f1ull, 0x510e527fade682d1ull, 0x9b05688c2b3e6c1full,
                          0x1f83d9abfb41bd6bull, 0x5be0cd19137e2179ull};
  const uint8_t SIGMA[10][16] = {
      {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}, {14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3},
      {11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4}, {7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8},
      {9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13}, {2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9},
      {12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11}, {13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10},
      {6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5}, {10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0}};
  uint64_t v[16];
  for (int i = 0; i < 8; i++) {
    v[i] = h[i];
    v[i + 8] = IV[i];
  }
  v[12] ^= t[0];
  v[13] ^= t[1];
  if (f) v[14] = ~v[14];
  for (uint32_t r = 0; r < rounds; r++) {
    const uint8_t* s = SIGMA[r % 10];
    blake2_g(v, 0, 4, 8, 12, m[s[0]], m[s[1]]);
    blake2_g(v, 1, 5, 9, 13, m[s[2]], m[s[3]]);
    blake2_g(v, 2, 6, 10, 14, m[s[4]], m[s[5]]);
    blake2_g(v, 3, 7, 11, 15, m[s[6]], m[s[7]]);
    blake2_g(v, 0, 5, 10, 15, m[s[8]], m[s[9]]);
    blake2_g(v, 1, 6, 11, 12, m[s[10]], m[s[11]]);
    blake2_g(v, 2, 7, 8, 13, m[s[12]], m[s[13]]);
    blake2_g(v, 3, 4, 9, 14, m[s[14]], m[s[15]]);
  }
  for (int i = 0; i < 8; i++) h[i] ^= v[i] ^ v[i + 8];
}

}  // namespace fevm
