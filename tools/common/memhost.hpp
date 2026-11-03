// In-memory world state implementing the fastevm host interface.
// Used by unit tests, fastevm-run and fastevm-bench.
#pragma once

#include <cstring>
#include <map>
#include <string>
#include <vector>

#include "fastevm.h"
#include "../../src/common/keccak.cuh"

namespace memhost {

struct Hash32 {
  uint8_t b[32] = {0};
  bool operator<(const Hash32& o) const { return memcmp(b, o.b, 32) < 0; }
  bool operator==(const Hash32& o) const { return memcmp(b, o.b, 32) == 0; }
  bool is_zero() const {
    for (auto c : b)
      if (c) return false;
    return true;
  }
};

struct Addr {
  uint8_t b[20] = {0};
  bool operator<(const Addr& o) const { return memcmp(b, o.b, 20) < 0; }
  bool operator==(const Addr& o) const { return memcmp(b, o.b, 20) == 0; }
};

inline Addr addr_from_u64(uint64_t v) {
  Addr a;
  for (int i = 0; i < 8; i++) a.b[19 - i] = (uint8_t)(v >> (i * 8));
  return a;
}
inline Hash32 h32_from_u64(uint64_t v) {
  Hash32 h;
  for (int i = 0; i < 8; i++) h.b[31 - i] = (uint8_t)(v >> (i * 8));
  return h;
}

inline void keccak(const uint8_t* p, size_t n, uint8_t out[32]) { fevm::keccak256(p, n, out); }

struct Account {
  uint64_t nonce = 0;
  Hash32 balance;
  std::vector<uint8_t> code;
  std::map<Hash32, Hash32> storage;
};

typedef int (*PrecompileFn)(const fevm_request& r, std::vector<uint8_t>* out, uint64_t* gas_left);

struct World {
  std::map<Addr, Account> accounts;
  std::map<uint64_t, Hash32> block_hashes;
  PrecompileFn precompile = nullptr;
  uint64_t fetches = 0;

  Account& at(const Addr& a) { return accounts[a]; }

  static int fetch_cb(void* ctx, fevm_sink* sink, const fevm_request* reqs, uint32_t n) {
    World* w = (World*)ctx;
    for (uint32_t i = 0; i < n; i++) {
      const fevm_request& r = reqs[i];
      w->fetches++;
      Addr a;
      memcpy(a.b, r.address.bytes, 20);
      switch (r.kind) {
        case FEVM_REQ_ACCOUNT: {
          fevm_account_info info{};
          auto it = w->accounts.find(a);
          if (it == w->accounts.end()) {
            fevm_sink_account(sink, i, &info, nullptr, 0);
            break;
          }
          const Account& acc = it->second;
          info.exists = 1;
          info.has_storage = !acc.storage.empty();
          info.nonce = acc.nonce;
          memcpy(info.balance.bytes, acc.balance.b, 32);
          keccak(acc.code.data(), acc.code.size(), info.code_hash.bytes);
          fevm_sink_account(sink, i, &info, acc.code.data(), acc.code.size());
          break;
        }
        case FEVM_REQ_STORAGE: {
          fevm_bytes32 v{};
          auto it = w->accounts.find(a);
          if (it != w->accounts.end()) {
            Hash32 k;
            memcpy(k.b, r.key.bytes, 32);
            auto s = it->second.storage.find(k);
            if (s != it->second.storage.end()) memcpy(v.bytes, s->second.b, 32);
          }
          fevm_sink_storage(sink, i, &v, &v, 0);
          break;
        }
        case FEVM_REQ_BLOCKHASH: {
          fevm_bytes32 h{};
          auto it = w->block_hashes.find(r.number);
          if (it != w->block_hashes.end()) memcpy(h.bytes, it->second.b, 32);
          fevm_sink_blockhash(sink, i, &h);
          break;
        }
        case FEVM_REQ_PRECOMPILE: {
          std::vector<uint8_t> out;
          uint64_t gl = 0;
          int st = w->precompile ? w->precompile(r, &out, &gl) : 1;
          fevm_sink_precompile(sink, i, st, gl, out.data(), out.size());
          break;
        }
      }
    }
    return 0;
  }

  fevm_host host() { return fevm_host{this, &World::fetch_cb}; }

  // Applies a message result to the world (same semantics a client adapter uses).
  void apply(const fevm_result& r) {
    if (r.status == FEVM_STATUS_FALLBACK) return;
    for (uint32_t i = 0; i < r.n_accounts; i++) {
      const fevm_account_diff& d = r.accounts[i];
      Addr a;
      memcpy(a.b, d.address.bytes, 20);
      Account& acc = accounts[a];
      if (d.flags & FEVM_ACC_BALANCE) memcpy(acc.balance.b, d.balance.bytes, 32);
      if (d.flags & FEVM_ACC_NONCE) acc.nonce = d.nonce;
      if (d.flags & FEVM_ACC_CODE) acc.code.assign(d.code, d.code + d.code_len);
      if (d.flags & FEVM_ACC_DESTRUCTED) {
        accounts.erase(a);
        continue;
      }
      if ((d.flags & FEVM_ACC_TOUCHED) && acc.nonce == 0 && acc.balance.is_zero() && acc.code.empty())
        accounts.erase(a);  // EIP-158
    }
    for (uint32_t i = 0; i < r.n_slots; i++) {
      const fevm_slot_diff& d = r.slots[i];
      Addr a;
      memcpy(a.b, d.address.bytes, 20);
      auto it = accounts.find(a);
      if (it == accounts.end()) continue;
      Hash32 k, v;
      memcpy(k.b, d.key.bytes, 32);
      memcpy(v.b, d.value.bytes, 32);
      if (v.is_zero())
        it->second.storage.erase(k);
      else
        it->second.storage[k] = v;
    }
  }
};

}  // namespace memhost
