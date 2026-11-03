// Keccak-256 (original Keccak padding, as used by Ethereum).
#pragma once

#include "defs.cuh"

namespace fevm {

FEVM_HD uint64_t rotl64(uint64_t x, int s) { return (x << s) | (x >> (64 - s)); }

FEVM_HDN void keccakf(uint64_t st[25]) {
  const uint64_t RC[24] = {
      0x0000000000000001ull, 0x0000000000008082ull, 0x800000000000808aull, 0x8000000080008000ull,
      0x000000000000808bull, 0x0000000080000001ull, 0x8000000080008081ull, 0x8000000000008009ull,
      0x000000000000008aull, 0x0000000000000088ull, 0x0000000080008009ull, 0x000000008000000aull,
      0x000000008000808bull, 0x800000000000008bull, 0x8000000000008089ull, 0x8000000000008003ull,
      0x8000000000008002ull, 0x8000000000000080ull, 0x000000000000800aull, 0x800000008000000aull,
      0x8000000080008081ull, 0x8000000000008080ull, 0x0000000080000001ull, 0x8000000080008008ull};
  uint64_t a0 = st[0], a1 = st[1], a2 = st[2], a3 = st[3], a4 = st[4], a5 = st[5], a6 = st[6], a7 = st[7], a8 = st[8], a9 = st[9], a10 = st[10], a11 = st[11], a12 = st[12], a13 = st[13], a14 = st[14], a15 = st[15], a16 = st[16], a17 = st[17], a18 = st[18], a19 = st[19], a20 = st[20], a21 = st[21], a22 = st[22], a23 = st[23], a24 = st[24];
  for (int r = 0; r < 24; r++) {
    uint64_t c0 = a0 ^ a5 ^ a10 ^ a15 ^ a20;
    uint64_t c1 = a1 ^ a6 ^ a11 ^ a16 ^ a21;
    uint64_t c2 = a2 ^ a7 ^ a12 ^ a17 ^ a22;
    uint64_t c3 = a3 ^ a8 ^ a13 ^ a18 ^ a23;
    uint64_t c4 = a4 ^ a9 ^ a14 ^ a19 ^ a24;
    uint64_t d0 = c4 ^ rotl64(c1, 1);
    uint64_t d1 = c0 ^ rotl64(c2, 1);
    uint64_t d2 = c1 ^ rotl64(c3, 1);
    uint64_t d3 = c2 ^ rotl64(c4, 1);
    uint64_t d4 = c3 ^ rotl64(c0, 1);
    uint64_t b0 = (a0 ^ d0);
    uint64_t b10 = rotl64((a1 ^ d1), 1);
    uint64_t b20 = rotl64((a2 ^ d2), 62);
    uint64_t b5 = rotl64((a3 ^ d3), 28);
    uint64_t b15 = rotl64((a4 ^ d4), 27);
    uint64_t b16 = rotl64((a5 ^ d0), 36);
    uint64_t b1 = rotl64((a6 ^ d1), 44);
    uint64_t b11 = rotl64((a7 ^ d2), 6);
    uint64_t b21 = rotl64((a8 ^ d3), 55);
    uint64_t b6 = rotl64((a9 ^ d4), 20);
    uint64_t b7 = rotl64((a10 ^ d0), 3);
    uint64_t b17 = rotl64((a11 ^ d1), 10);
    uint64_t b2 = rotl64((a12 ^ d2), 43);
    uint64_t b12 = rotl64((a13 ^ d3), 25);
    uint64_t b22 = rotl64((a14 ^ d4), 39);
    uint64_t b23 = rotl64((a15 ^ d0), 41);
    uint64_t b8 = rotl64((a16 ^ d1), 45);
    uint64_t b18 = rotl64((a17 ^ d2), 15);
    uint64_t b3 = rotl64((a18 ^ d3), 21);
    uint64_t b13 = rotl64((a19 ^ d4), 8);
    uint64_t b14 = rotl64((a20 ^ d0), 18);
    uint64_t b24 = rotl64((a21 ^ d1), 2);
    uint64_t b9 = rotl64((a22 ^ d2), 61);
    uint64_t b19 = rotl64((a23 ^ d3), 56);
    uint64_t b4 = rotl64((a24 ^ d4), 14);
    a0 = b0 ^ (~b1 & b2);
    a1 = b1 ^ (~b2 & b3);
    a2 = b2 ^ (~b3 & b4);
    a3 = b3 ^ (~b4 & b0);
    a4 = b4 ^ (~b0 & b1);
    a5 = b5 ^ (~b6 & b7);
    a6 = b6 ^ (~b7 & b8);
    a7 = b7 ^ (~b8 & b9);
    a8 = b8 ^ (~b9 & b5);
    a9 = b9 ^ (~b5 & b6);
    a10 = b10 ^ (~b11 & b12);
    a11 = b11 ^ (~b12 & b13);
    a12 = b12 ^ (~b13 & b14);
    a13 = b13 ^ (~b14 & b10);
    a14 = b14 ^ (~b10 & b11);
    a15 = b15 ^ (~b16 & b17);
    a16 = b16 ^ (~b17 & b18);
    a17 = b17 ^ (~b18 & b19);
    a18 = b18 ^ (~b19 & b15);
    a19 = b19 ^ (~b15 & b16);
    a20 = b20 ^ (~b21 & b22);
    a21 = b21 ^ (~b22 & b23);
    a22 = b22 ^ (~b23 & b24);
    a23 = b23 ^ (~b24 & b20);
    a24 = b24 ^ (~b20 & b21);
    a0 ^= RC[r];
  }
  st[0] = a0; st[1] = a1; st[2] = a2; st[3] = a3; st[4] = a4; st[5] = a5; st[6] = a6; st[7] = a7; st[8] = a8; st[9] = a9; st[10] = a10; st[11] = a11; st[12] = a12; st[13] = a13; st[14] = a14; st[15] = a15; st[16] = a16; st[17] = a17; st[18] = a18; st[19] = a19; st[20] = a20; st[21] = a21; st[22] = a22; st[23] = a23; st[24] = a24;
}

FEVM_HDN void keccak256(const uint8_t* data, size_t len, uint8_t out[32]) {
  const size_t rate = 136;
  uint64_t st[25];
  for (int i = 0; i < 25; i++) st[i] = 0;
  while (len >= rate) {
    for (size_t i = 0; i < rate / 8; i++) st[i] ^= load_le64(data + i * 8);
    keccakf(st);
    data += rate;
    len -= rate;
  }
  uint8_t block[136];
  for (size_t i = 0; i < rate; i++) block[i] = 0;
  for (size_t i = 0; i < len; i++) block[i] = data[i];
  block[len] ^= 0x01;
  block[rate - 1] ^= 0x80;
  for (size_t i = 0; i < rate / 8; i++) st[i] ^= load_le64(block + i * 8);
  keccakf(st);
  for (int i = 0; i < 4; i++) store_le64(out + i * 8, st[i]);
}

}  // namespace fevm
