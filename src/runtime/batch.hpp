// Host-side batch state shared by the CPU and GPU backends.
#pragma once

#include <atomic>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include "../../include/fastevm.h"
#include "../evm/interpreter.cuh"
#include "state_cache.hpp"

namespace fevm {

LaneLayout make_layout(uint64_t arena_bytes, bool external_stack);

struct LaneResult {
  fevm_result r{};
  std::vector<fevm_account_diff> accounts;
  std::vector<fevm_slot_diff> slots;
  std::vector<fevm_log> logs;
  std::vector<uint8_t> bytes;  // backing store for output, code and log data
};

class Backend;

}  // namespace fevm

struct fevm_engine {
  fevm_config cfg{};
  std::unique_ptr<fevm::Backend> backend;
  std::unique_ptr<fevm::Backend> cpu;  // fallback for lanes exceeding GPU arena limits
  fevm::StateCache cache;              // base state kept across batches
  fevm_batch* bound = nullptr;         // batch the cache currently serves
};

struct fevm_batch {
  fevm_engine* eng = nullptr;
  fevm::Block blk{};
  std::vector<uint8_t> blob;  // calldata, access lists, frame code, precompile outputs
  std::vector<fevm::Msg> msgs;
  std::vector<fevm::LaneCtl> ctl;
  std::vector<fevm::LaneResult> results;
  fevm_batch_stats stats{};
  bool executed = false;
  bool has_state_id = false;
  uint8_t state_id[32] = {};
  uint64_t acc_puts0 = 0, slot_puts0 = 0;  // cache counters when the batch bound the cache
};

namespace fevm {

fevm::Loc blob_append(fevm_batch* b, const void* p, size_t n, size_t align = 8);
// Makes the engine's state cache serve batch b (flushing it unless b declared
// the cached state id). Called before b's first state access.
void bind_cache(fevm_batch* b);

// One request handed to the client, plus the lanes waiting for it.
struct PendingReq {
  fevm_request req;
  std::vector<uint32_t> lanes;
  std::vector<uint8_t> input;  // precompile input copy
  bool answered = false;
};

class Backend {
 public:
  virtual ~Backend() = default;
  virtual const char* name() const = 0;
  // Lane arena size this backend uses.
  virtual uint64_t arena_bytes() const = 0;
  // Largest number of lanes resident at once.
  virtual size_t max_lanes() const { return SIZE_MAX; }
  // Lane groups whose rounds can overlap host work of the other group.
  virtual uint32_t groups() const { return 1; }
  // Merges device-side LRU stamps into the cache before an eviction.
  virtual void pull_lru(StateCache&) {}
  // Executes the lanes listed in `lanes` (indices into batch) until all are done.
  // Returns 0 on success.
  int execute(fevm_batch* b, const std::vector<uint32_t>& lanes, const fevm_host* host);

 protected:
  // Prepares `slots` lane arenas and per-group buffers for `per_group` lanes.
  virtual void begin(fevm_batch* b, size_t slots, size_t per_group) = 0;
  // Places `lanes` in slots [base, base + lanes.size()) for group g and resets them.
  virtual void load(fevm_batch* b, uint32_t g, uint32_t base, const std::vector<uint32_t>& lanes) = 0;
  // Starts one round of group g over the given slots; may return before it ends.
  virtual void launch(fevm_batch* b, uint32_t g, const std::vector<uint32_t>& active) = 0;
  // Waits for group g's round and updates b->ctl of the lanes that ran.
  virtual void wait(fevm_batch* b, uint32_t g, const std::vector<uint32_t>& active) = 0;
  // Copies precompile input bytes of lane slot `slot` at location `loc`.
  virtual void read_lane_bytes(uint32_t g, uint32_t slot, Loc loc, uint64_t len, uint8_t* out) = 0;
  // Result records of group g's current load.
  virtual const uint8_t* result_pool(uint32_t g, uint64_t* len) = 0;
  // Restores the given slots' arenas to the clean state (lanes aborted by the host
  // never released their tables).
  virtual void scrub(uint32_t g, const std::vector<uint32_t>& slots) = 0;
  virtual void end(fevm_batch* b) = 0;
  // Device time of group g's last round, or -1 when the backend does not measure it.
  virtual double kernel_seconds(uint32_t) { return -1; }

  std::vector<uint32_t> lanes_;  // slot -> batch lane
  double transfer_seconds_ = 0;
};

std::unique_ptr<Backend> make_cpu_backend(const fevm_config& cfg);
std::unique_ptr<Backend> make_gpu_backend(const fevm_config& cfg, const char** err);
bool gpu_available();

// Decodes a packed result record; unchanged account fields come from the cache.
void unpack_result(const uint8_t* rec, uint64_t len, StateCache& cache, LaneResult* out);

}  // namespace fevm
