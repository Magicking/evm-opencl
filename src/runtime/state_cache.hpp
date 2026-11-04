// Engine-level state cache: the base tables (accounts, slots, block hashes) and
// the code cache, kept across batches and mirrored on the device by the GPU
// backend.
//
// Validity:
//   * code and jumpdest bitmaps are keyed by code hash and never go stale;
//   * accounts, slots and block hashes are reused while consecutive batches
//     declare the same state id (fevm_batch_set_state_id); otherwise the epoch
//     is bumped, which invalidates them in O(1) on host and device;
//   * fevm_batch_commit folds a batch's results into the cache under a new id.
// When the cache outgrows its budget, the least recently used entries go.
#pragma once

#include <string>
#include <unordered_map>
#include <vector>

#include "../../include/fastevm.h"
#include "../evm/types.cuh"

namespace fevm {

struct StateCache {
  std::vector<BaseAccount> accounts;
  std::vector<BaseSlot> slots;
  std::vector<BaseBlockHash> bh;
  std::vector<uint32_t> acc_lru, slot_lru;  // batch seq of last use, parallel to the tables
  std::vector<uint8_t> code;                // LOC_CODE region: code and jumpdest bitmaps

  struct CodeEnt {
    Loc code, jd;
    uint32_t len;
    uint32_t last;  // batch seq of last use
  };
  std::unordered_map<std::string, CodeEnt> code_by_hash;

  size_t n_acc = 0, n_slot = 0, n_bh = 0;  // live entries
  uint32_t epoch = 1;
  uint32_t seq = 0;  // batch sequence number
  bool has_id = false;
  uint8_t id[32] = {};
  uint64_t budget = 0;

  // Device mirror bookkeeping (GPU backend).
  std::vector<uint32_t> dirty_acc, dirty_slot, dirty_bh;
  bool full = true;        // the next device sync must upload everything
  size_t code_synced = 0;  // bytes of `code` already on the device

  // Statistics.
  uint64_t evictions = 0;
  uint64_t acc_puts = 0, slot_puts = 0;

  explicit StateCache(uint64_t budget_bytes = 0);
  void reset();
  // Starts a batch: reuses accounts/slots when `state_id` matches the cached
  // state, otherwise invalidates them. Code survives either way.
  void begin_batch(const uint8_t* state_id);
  void flush_state();
  bool over_budget() const { return bytes() > budget; }
  // Drops least recently used entries until the cache fits in `target` bytes.
  void evict(uint64_t target);
  uint64_t bytes() const;

  void put_account(const Address& a, const fevm_account_info& info, const uint8_t* code, uint64_t len,
                   uint32_t warm_lane);
  void put_slot(const Address& a, const u256& key, const u256& value, const u256& original, uint32_t warm_lane);
  void put_blockhash(uint64_t n, const uint8_t* hash);
  BaseAccount* find_account(const Address& a);
  BaseSlot* find_slot(const Address& a, const u256& key);

  // Applies one message's committed diffs. Returns false when the cache cannot
  // follow them (created/destroyed accounts); the caller then flushes.
  bool apply(const fevm_result& r);

  BaseView view(const uint8_t* blob_base, const uint8_t* code_base, uint32_t* acc_lru_base,
                uint32_t* slot_lru_base) const;

 private:
  Loc add_code(const uint8_t* hash, const uint8_t* code, uint64_t len, Loc* jd);
  template <typename T>
  void grow(std::vector<T>& v, std::vector<uint32_t>* lru, size_t n);
  bool live(const BaseAccount& e) const { return e.used && e.epoch == epoch; }
  bool live(const BaseSlot& e) const { return e.used && e.epoch == epoch; }
  bool live(const BaseBlockHash& e) const { return e.used && e.epoch == epoch; }
};

}  // namespace fevm
