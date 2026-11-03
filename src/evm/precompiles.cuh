// Precompiles that run inside the lane (host+device). All others are delegated
// to the client through REQ_PRECOMPILE so results match it bit for bit.
#pragma once

#include "../common/hashes.cuh"
#include "types.cuh"

namespace fevm {

enum PrecompileWhere : uint32_t { PC_NONE = 0, PC_LANE = 1, PC_HOST = 2 };

FEVM_HD uint32_t precompile_where(uint32_t fork, const Address& a) {
  uint32_t idx = addr_low_index(a);
  if (idx == 0 || idx == 0xffffffffu) return PC_NONE;
  switch (idx) {
    case 0x02:  // sha256
    case 0x03:  // ripemd160
    case 0x04:  // identity
    case 0x09:  // blake2f
      return PC_LANE;
    case 0x01:  // ecrecover
    case 0x05:  // modexp
    case 0x06:  // bn254 add
    case 0x07:  // bn254 mul
    case 0x08:  // bn254 pairing
    case 0x0a:  // kzg point evaluation
      return PC_HOST;
    default:
      break;
  }
  if (fork >= FORK_PRAGUE && idx >= 0x0b && idx <= 0x11) return PC_HOST;  // BLS12-381 (EIP-2537)
  if (fork >= FORK_OSAKA && idx == 0x100) return PC_HOST;                 // P256VERIFY (EIP-7951)
  return PC_NONE;
}

FEVM_HD bool is_precompile(uint32_t fork, const Address& a) { return precompile_where(fork, a) != PC_NONE; }

// Runs an in-lane precompile. Writes at most 64 bytes to out unless identity,
// which is handled by the caller (output == input). Returns false on failure
// (all gas consumed). *gas_cost receives the required gas.
FEVM_HD bool run_lane_precompile(uint32_t idx, const uint8_t* in, uint64_t len, uint64_t gas, uint64_t* gas_used,
                                 uint8_t* out, uint64_t* out_len) {
  uint64_t words = (len + 31) / 32;
  switch (idx) {
    case 0x02: {
      uint64_t cost = 60 + 12 * words;
      *gas_used = cost;
      if (cost > gas) return false;
      sha256(in, len, out);
      *out_len = 32;
      return true;
    }
    case 0x03: {
      uint64_t cost = 600 + 120 * words;
      *gas_used = cost;
      if (cost > gas) return false;
      mem_zero(out, 12);
      ripemd160(in, len, out + 12);
      *out_len = 32;
      return true;
    }
    case 0x04: {
      uint64_t cost = 15 + 3 * words;
      *gas_used = cost;
      if (cost > gas) return false;
      *out_len = len;  // caller copies input
      return true;
    }
    case 0x09: {
      *gas_used = gas;
      if (len != 213) return false;
      uint8_t f = in[212];
      if (f > 1) return false;
      uint32_t rounds = ((uint32_t)in[0] << 24) | ((uint32_t)in[1] << 16) | ((uint32_t)in[2] << 8) | in[3];
      *gas_used = rounds;
      if (rounds > gas) return false;
      uint64_t h[8], m[16], t[2];
      for (int i = 0; i < 8; i++) h[i] = load_le64(in + 4 + i * 8);
      for (int i = 0; i < 16; i++) m[i] = load_le64(in + 68 + i * 8);
      t[0] = load_le64(in + 196);
      t[1] = load_le64(in + 204);
      blake2b_f(rounds, h, m, t, f == 1);
      for (int i = 0; i < 8; i++) store_le64(out + i * 8, h[i]);
      *out_len = 64;
      return true;
    }
    default:
      *gas_used = gas;
      return false;
  }
}

}  // namespace fevm
