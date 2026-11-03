// Host-side batch state shared by the CPU and GPU backends.
#pragma once

#include <atomic>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include "../../include/fastevm.h"
#include "../evm/interpreter.cuh"

namespace fevm {

LaneLayout make_layout(uint64_t arena_bytes, bool external_stack);

// Open-addressing tables mirrored to the device by the GPU backend.
struct HostTables {
  std::vector<BaseAccount> accounts;
  std::vector<BaseSlot> slots;
  std::vector<BaseBlockHash> bh;
  std::vector<uint8_t> blob;
  size_t n_acc = 0, n_slot = 0, n_bh = 0;
  std::unordered_map<std::string, std::pair<Loc, Loc>> code_by_hash;  // code hash -> (code, jumpdests)
  uint64_t generation = 0;  // bumped on every modification
  bool rehashed = true;     // tables reallocated since last upload

  HostTables();
  void clear();
  Loc blob_append(const void* p, size_t n, size_t align = 8);
  void put_account(const Address& a, const fevm_account_info& info, const uint8_t* code, uint64_t len,
                   uint32_t warm_lane);
  void put_slot(const Address& a, const u256& key, const u256& value, const u256& original, uint32_t warm_lane);
  void put_blockhash(uint64_t n, const uint8_t* hash);
  BaseView view(const uint8_t* blob_base) const;

 private:
  template <typename T>
  void grow(std::vector<T>& v, size_t n);
};

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
};

struct fevm_batch {
  fevm_engine* eng = nullptr;
  fevm::Block blk{};
  fevm::HostTables T;
  std::vector<fevm::Msg> msgs;
  std::vector<fevm::LaneCtl> ctl;
  std::vector<fevm::LaneResult> results;
  fevm_batch_stats stats{};
  bool executed = false;
};

namespace fevm {

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
  // Largest number of lanes one execute() call may hold.
  virtual size_t max_lanes() const { return SIZE_MAX; }
  // Executes the lanes listed in `lanes` (indices into batch) until all are done.
  // Returns 0 on success.
  int execute(fevm_batch* b, const std::vector<uint32_t>& lanes, const fevm_host* host);

 protected:
  // Allocates per-lane arenas for n lanes and zeroes them, resets the result pool.
  virtual void begin(fevm_batch* b, const std::vector<uint32_t>& lanes) = 0;
  // Runs one round over the given active lanes (positions into `lanes` given at begin).
  virtual void run_round(fevm_batch* b, const std::vector<uint32_t>& active) = 0;
  // Copies precompile input bytes of lane slot `slot` at location `loc`.
  virtual void read_lane_bytes(uint32_t slot, Loc loc, uint64_t len, uint8_t* out) = 0;
  // Returns the result pool contents after the final round.
  virtual const uint8_t* result_pool(uint64_t* len) = 0;
  virtual void end(fevm_batch* b) = 0;
  // Restores the given slots' arenas to the clean state (lanes aborted by the host
  // never released their tables).
  virtual void scrub(const std::vector<uint32_t>& slots) = 0;
  // Device time of the last round, or -1 when the backend does not measure it.
  virtual double kernel_seconds() { return -1; }

  std::vector<uint32_t> lanes_;  // slot -> batch lane
  double transfer_seconds_ = 0;
};

std::unique_ptr<Backend> make_cpu_backend(const fevm_config& cfg);
std::unique_ptr<Backend> make_gpu_backend(const fevm_config& cfg, const char** err);
bool gpu_available();

void unpack_result(const uint8_t* rec, LaneResult* out);

}  // namespace fevm
