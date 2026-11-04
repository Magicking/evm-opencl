// CUDA backend: one thread per lane, the same interpreter as the CPU backend.
#include <cuda_runtime.h>

#include <chrono>
#include <cstdio>
#include <cstring>
#include <stdexcept>

#include "batch.hpp"

namespace fevm {

#define CUDA_CHECK(x)                                                                        \
  do {                                                                                       \
    cudaError_t _e = (x);                                                                    \
    if (_e != cudaSuccess) {                                                                 \
      fprintf(stderr, "fastevm cuda error %s at %s:%d\n", cudaGetErrorString(_e), __FILE__, \
              __LINE__);                                                                     \
      throw std::runtime_error(cudaGetErrorString(_e));                                      \
    }                                                                                        \
  } while (0)

struct KernelArgs {
  uint8_t* arenas;
  u256* stacks;  // interleaved: item k of slot s at stacks[k * n_slots + s]
  uint64_t n_slots;
  uint64_t arena_bytes;
  LaneCtl* ctl;
  const Msg* msgs;
  const uint32_t* lane_ids;
  const uint32_t* active;
  uint32_t n_active;
  CtlEvent* events;  // events[i]: outcome of active[i] after this round
  BaseView base;
  Block blk;
  LaneLayout layout;
  ResultPool pool;
};

// Threads per lane_kernel block. Lanes are register-bound (3 blocks of 128 or
// 12 of 32 per SM), so small blocks lose no occupancy, and they spread a load
// over every SM: 1,000 lanes in blocks of 128 would run on 8 of 34 SMs.
constexpr uint32_t kLaneBlock = 32;

__global__ void __launch_bounds__(kLaneBlock) lane_kernel(KernelArgs a) {
  uint32_t i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= a.n_active) return;
  uint32_t slot = a.active[i];
  Interp it;
  it.arena = a.arenas + (uint64_t)slot * a.arena_bytes;
  it.stk = a.stacks + slot;
  it.stk_stride = a.n_slots;
  it.ctl = &a.ctl[slot];
  it.L = &a.layout;
  it.base = &a.base;
  it.blk = &a.blk;
  it.msg = &a.msgs[slot];
  it.pool = &a.pool;
  it.lane = a.lane_ids[slot];
  it.bind();
  it.run();
  ctl_to_event(*it.ctl, &a.events[i]);
}

// Writes cache entries changed on the host into the device tables.
template <typename T>
__global__ void scatter_kernel(T* dst, const uint32_t* idx, const T* src, uint32_t n) {
  uint32_t i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) dst[idx[i]] = src[i];
}

static bool trace_enabled() {
  static int v = -1;
  if (v < 0) v = getenv("FASTEVM_TRACE") ? 1 : 0;
  return v == 1;
}
#define TRACE(...)                                 \
  do {                                             \
    if (trace_enabled()) fprintf(stderr, __VA_ARGS__); \
  } while (0)

static double now_s() {
  return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

template <typename T>
struct DevBuf {
  T* p = nullptr;
  size_t cap = 0;  // elements
  // Returns true when the buffer was (re)allocated.
  bool reserve(size_t n, bool exact = false) {
    if (n <= cap) return false;
    if (p) cudaFree(p);
    p = nullptr;
    size_t c = exact ? n : std::max(n, cap + cap / 4);
    CUDA_CHECK(cudaMalloc(&p, c * sizeof(T)));
    cap = c;
    return true;
  }
  void release() {
    if (p) cudaFree(p);
    p = nullptr;
    cap = 0;
  }
};

// Page-locked host buffer (fast async copies).
template <typename T>
struct PinnedVec {
  T* p = nullptr;
  size_t n = 0, cap = 0;
  ~PinnedVec() {
    if (p) cudaFreeHost(p);
  }
  void resize(size_t m) {
    if (m > cap) {
      if (p) cudaFreeHost(p);
      size_t c = std::max(m, cap + cap / 2);
      CUDA_CHECK(cudaHostAlloc((void**)&p, c * sizeof(T), cudaHostAllocDefault));
      cap = c;
    }
    n = m;
  }
  void assign(size_t m, const T& v) {
    resize(m);
    for (size_t i = 0; i < m; i++) p[i] = v;
  }
  T* data() { return p; }
  T& operator[](size_t i) { return p[i]; }
};

class GpuBackend final : public Backend {
 public:
  explicit GpuBackend(const fevm_config& cfg) : device_(cfg.device) {
    CUDA_CHECK(cudaSetDevice(device_));
    arena_ = cfg.lane_arena_bytes ? cfg.lane_arena_bytes : (1ull << 20);
    arena_ = (arena_ + 4095) & ~4095ull;
    layout_ = make_layout(arena_, true);
    CUDA_CHECK(cudaDeviceSetLimit(cudaLimitStackSize, 8192));
    for (Grp& g : grp_) {
      CUDA_CHECK(cudaStreamCreateWithFlags(&g.s, cudaStreamNonBlocking));
      CUDA_CHECK(cudaEventCreate(&g.k0));
      CUDA_CHECK(cudaEventCreate(&g.k1));
    }
    size_t free_b = 0, total_b = 0;
    CUDA_CHECK(cudaMemGetInfo(&free_b, &total_b));
    // Keep headroom for the state cache, the batch blob and the result pools.
    uint64_t cache = std::min<uint64_t>(cfg.state_cache_bytes ? cfg.state_cache_bytes : (512ull << 20), free_b / 4);
    double usable = free_b * 0.75 - (double)cache;
    max_lanes_ = (size_t)(std::max(usable, 0.0) / (arena_ + layout_.stack_cap * 32 + (64 << 10)));
    if (max_lanes_ < 1) max_lanes_ = 1;
  }
  ~GpuBackend() override {
    cudaSetDevice(device_);
    for (Grp& g : grp_) {
      g.active.release();
      g.events.release();
      g.pool.release();
      g.cursor.release();
      if (g.k0) cudaEventDestroy(g.k0);
      if (g.k1) cudaEventDestroy(g.k1);
      if (g.s) cudaStreamDestroy(g.s);
    }
    arenas_.release();
    stacks_.release();
    acc_.release();
    slot_.release();
    bh_.release();
    alru_.release();
    slru_.release();
    code_.release();
    stage_idx_.release();
    stage_ent_.release();
    blob_.release();
    msgs_.release();
    ctl_.release();
    lane_ids_.release();
  }
  const char* name() const override { return "gpu"; }
  uint64_t arena_bytes() const override { return arena_; }
  size_t max_lanes() const override { return max_lanes_; }
  uint32_t groups() const override { return kGroups; }

  void pull_lru(StateCache& C) override {
    CUDA_CHECK(cudaSetDevice(device_));
    auto merge = [&](DevBuf<uint32_t>& d, size_t n, std::vector<uint32_t>& h) {
      if (!d.p || n != h.size()) return;  // host table was rebuilt since the last upload
      std::vector<uint32_t> tmp(n);
      CUDA_CHECK(cudaMemcpy(tmp.data(), d.p, n * 4, cudaMemcpyDeviceToHost));
      for (size_t i = 0; i < n; i++) h[i] = std::max(h[i], tmp[i]);
    };
    merge(alru_, dev_acc_n_, C.acc_lru);
    merge(slru_, dev_slot_n_, C.slot_lru);
  }

 protected:
  void begin(fevm_batch* b, size_t slots, size_t per_group) override {
    (void)b;
    CUDA_CHECK(cudaSetDevice(device_));
    double t0 = now_s();
    n_ = slots;
    // Arenas persist across batches; lanes leave their tables clean when they
    // finish, so only freshly allocated memory needs zeroing.
    stacks_.reserve(n_ * layout_.stack_cap, true);
    if (arenas_.reserve(n_ * arena_, true)) {
      CUDA_CHECK(cudaMemset2DAsync(arenas_.p, arena_, 0, layout_.heap_off, arenas_.cap / arena_, grp_[0].s));
      CUDA_CHECK(cudaStreamSynchronize(grp_[0].s));
    }
    msgs_.reserve(n_);
    lane_ids_.reserve(n_);
    ctl_.reserve(n_);
    pool_bytes_ = std::max<uint64_t>(4 << 20, per_group * (16ull << 10));
    for (Grp& g : grp_) {
      g.active.reserve(per_group);
      g.events.reserve(per_group);
      g.pool.reserve(pool_bytes_);
      g.cursor.reserve(1);
      g.busy = false;
    }
    blob_uploaded_ = 0;  // a new batch blob
    transfer_seconds_ += now_s() - t0;
    TRACE("[gpu] begin slots=%zu per_group=%zu %.3fms\n", n_, per_group, (now_s() - t0) * 1e3);
  }

  void load(fevm_batch* b, uint32_t gi, uint32_t base, const std::vector<uint32_t>& lanes) override {
    Grp& g = grp_[gi];
    size_t n = lanes.size();
    g.h_msgs.resize(n);
    g.h_ids.resize(n);
    for (size_t i = 0; i < n; i++) {
      g.h_msgs[i] = b->msgs[lanes[i]];
      g.h_ids[i] = lanes[i];
      b->ctl[lanes[i]] = LaneCtl{};
    }
    CUDA_CHECK(cudaMemcpyAsync(msgs_.p + base, g.h_msgs.data(), n * sizeof(Msg), cudaMemcpyHostToDevice, g.s));
    CUDA_CHECK(cudaMemcpyAsync(lane_ids_.p + base, g.h_ids.data(), n * 4, cudaMemcpyHostToDevice, g.s));
    CUDA_CHECK(cudaMemsetAsync(ctl_.p + base, 0, n * sizeof(LaneCtl), g.s));  // LaneCtl{}: LANE_INIT
    CUDA_CHECK(cudaMemsetAsync(g.cursor.p, 0, sizeof(unsigned long long), g.s));
  }

  // Uploads cache and blob changes. Device tables are only written while no
  // kernel runs, so a lane never reads a half-written entry.
  void sync_state(fevm_batch* b, uint32_t gi) {
    StateCache& C = b->eng->cache;
    bool dirty = !C.dirty_acc.empty() || !C.dirty_slot.empty() || !C.dirty_bh.empty();
    if (!C.full && !dirty && C.code.size() <= C.code_synced && b->blob.size() <= blob_uploaded_) return;
    double t0 = now_s();
    for (uint32_t h = 0; h < kGroups; h++)
      if (h != gi && grp_[h].busy) CUDA_CHECK(cudaStreamSynchronize(grp_[h].s));
    cudaStream_t s = grp_[gi].s;
    size_t up = 0;
    if (C.full) {
      acc_.reserve(C.accounts.size(), true);
      slot_.reserve(C.slots.size(), true);
      bh_.reserve(C.bh.size(), true);
      alru_.reserve(C.acc_lru.size(), true);
      slru_.reserve(C.slot_lru.size(), true);
      CUDA_CHECK(cudaMemcpyAsync(acc_.p, C.accounts.data(), C.accounts.size() * sizeof(BaseAccount),
                                 cudaMemcpyHostToDevice, s));
      CUDA_CHECK(cudaMemcpyAsync(slot_.p, C.slots.data(), C.slots.size() * sizeof(BaseSlot), cudaMemcpyHostToDevice, s));
      CUDA_CHECK(cudaMemcpyAsync(bh_.p, C.bh.data(), C.bh.size() * sizeof(BaseBlockHash), cudaMemcpyHostToDevice, s));
      CUDA_CHECK(cudaMemcpyAsync(alru_.p, C.acc_lru.data(), C.acc_lru.size() * 4, cudaMemcpyHostToDevice, s));
      CUDA_CHECK(cudaMemcpyAsync(slru_.p, C.slot_lru.data(), C.slot_lru.size() * 4, cudaMemcpyHostToDevice, s));
      dev_acc_n_ = C.accounts.size();
      dev_slot_n_ = C.slots.size();
      dev_bh_n_ = C.bh.size();
      up += C.accounts.size() * sizeof(BaseAccount) + C.slots.size() * sizeof(BaseSlot);
      C.full = false;
      C.code_synced = 0;
    } else if (dirty) {
      up += scatter(C.dirty_acc, C.accounts.data(), acc_.p, s) + scatter(C.dirty_slot, C.slots.data(), slot_.p, s) +
            scatter(C.dirty_bh, C.bh.data(), bh_.p, s);
    }
    C.dirty_acc.clear();
    C.dirty_slot.clear();
    C.dirty_bh.clear();
    if (code_.reserve(C.code.size())) C.code_synced = 0;
    if (C.code.size() > C.code_synced) {
      CUDA_CHECK(cudaMemcpyAsync(code_.p + C.code_synced, C.code.data() + C.code_synced,
                                 C.code.size() - C.code_synced, cudaMemcpyHostToDevice, s));
      up += C.code.size() - C.code_synced;
      C.code_synced = C.code.size();
    }
    if (blob_.reserve(b->blob.size())) blob_uploaded_ = 0;
    if (b->blob.size() > blob_uploaded_) {
      CUDA_CHECK(cudaMemcpyAsync(blob_.p + blob_uploaded_, b->blob.data() + blob_uploaded_,
                                 b->blob.size() - blob_uploaded_, cudaMemcpyHostToDevice, s));
      up += b->blob.size() - blob_uploaded_;
      blob_uploaded_ = b->blob.size();
    }
    CUDA_CHECK(cudaStreamSynchronize(s));
    transfer_seconds_ += now_s() - t0;
    TRACE("[gpu] sync g%u %zu bytes %.3fms\n", gi, up, (now_s() - t0) * 1e3);
  }

  // Stages the listed host entries and scatters them into the device table.
  template <typename T>
  size_t scatter(const std::vector<uint32_t>& idx, const T* host, T* dev, cudaStream_t s) {
    size_t n = idx.size();
    if (!n) return 0;
    h_stage_idx_.resize(n);
    h_stage_.resize(n * sizeof(T));
    T* ent = (T*)h_stage_.data();
    for (size_t i = 0; i < n; i++) {
      h_stage_idx_[i] = idx[i];
      ent[i] = host[idx[i]];
    }
    stage_idx_.reserve(n);
    stage_ent_.reserve(n * sizeof(T));
    CUDA_CHECK(cudaMemcpyAsync(stage_idx_.p, h_stage_idx_.data(), n * 4, cudaMemcpyHostToDevice, s));
    CUDA_CHECK(cudaMemcpyAsync(stage_ent_.p, ent, n * sizeof(T), cudaMemcpyHostToDevice, s));
    scatter_kernel<T><<<(uint32_t)((n + 127) / 128), 128, 0, s>>>(dev, stage_idx_.p, (const T*)stage_ent_.p, (uint32_t)n);
    CUDA_CHECK(cudaGetLastError());
    // The staging buffers are reused by the next table: finish this one first.
    CUDA_CHECK(cudaStreamSynchronize(s));
    return n * (sizeof(T) + 4);
  }

  void launch(fevm_batch* b, uint32_t gi, const std::vector<uint32_t>& active) override {
    Grp& g = grp_[gi];
    sync_state(b, gi);
    double t0 = now_s();
    // Precompile responses: the host wrote them into its copy of the lane's control block.
    g.h_resp.resize(active.size());
    size_t nr = 0;
    for (uint32_t slot : active) {
      LaneCtl& c = b->ctl[lanes_[slot]];
      if (!c.resp_ready) continue;
      g.h_resp[nr] = c;
      CUDA_CHECK(cudaMemcpyAsync(ctl_.p + slot, &g.h_resp[nr], sizeof(LaneCtl), cudaMemcpyHostToDevice, g.s));
      c.resp_ready = 0;  // the lane consumes it on the device
      nr++;
    }
    size_t n = active.size();
    g.h_active.resize(n);
    memcpy(g.h_active.data(), active.data(), n * 4);
    CUDA_CHECK(cudaMemcpyAsync(g.active.p, g.h_active.data(), n * 4, cudaMemcpyHostToDevice, g.s));
    StateCache& C = b->eng->cache;
    KernelArgs a;
    a.arenas = arenas_.p;
    a.stacks = stacks_.p;
    a.n_slots = n_;
    a.arena_bytes = arena_;
    a.ctl = ctl_.p;
    a.msgs = msgs_.p;
    a.lane_ids = lane_ids_.p;
    a.active = g.active.p;
    a.n_active = (uint32_t)n;
    a.events = g.events.p;
    a.base.accounts = acc_.p;
    a.base.acc_mask = dev_acc_n_ - 1;
    a.base.slots = slot_.p;
    a.base.slot_mask = dev_slot_n_ - 1;
    a.base.bh = bh_.p;
    a.base.bh_mask = dev_bh_n_ - 1;
    a.base.blob = blob_.p;
    a.base.code = code_.p;
    a.base.acc_lru = alru_.p;
    a.base.slot_lru = slru_.p;
    a.base.epoch = C.epoch;
    a.base.seq = C.seq;
    a.blk = b->blk;
    a.layout = layout_;
    a.pool.data = g.pool.p;
    a.pool.cap = pool_bytes_;
    a.pool.cursor = g.cursor.p;
    CUDA_CHECK(cudaEventRecord(g.k0, g.s));
    lane_kernel<<<(a.n_active + kLaneBlock - 1) / kLaneBlock, kLaneBlock, 0, g.s>>>(a);
    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaEventRecord(g.k1, g.s));
    g.h_events.resize(n);
    CUDA_CHECK(cudaMemcpyAsync(g.h_events.data(), g.events.p, n * sizeof(CtlEvent), cudaMemcpyDeviceToHost, g.s));
    g.busy = true;
    transfer_seconds_ += now_s() - t0;
  }

  void wait(fevm_batch* b, uint32_t gi, const std::vector<uint32_t>& active) override {
    Grp& g = grp_[gi];
    double t0 = now_s();
    CUDA_CHECK(cudaStreamSynchronize(g.s));
    g.busy = false;
    float ms = 0;
    CUDA_CHECK(cudaEventElapsedTime(&ms, g.k0, g.k1));
    g.kernel_s = ms / 1e3;
    for (size_t i = 0; i < active.size(); i++) event_to_ctl(g.h_events[i], &b->ctl[lanes_[active[i]]]);
    TRACE("[gpu] g%u kernel %.3fms wait %.3fms active=%zu\n", gi, ms, (now_s() - t0) * 1e3, active.size());
  }

  void read_lane_bytes(uint32_t gi, uint32_t slot, Loc loc, uint64_t len, uint8_t* out) override {
    double t0 = now_s();
    cudaStream_t s = grp_[gi].s;
    CUDA_CHECK(cudaMemcpyAsync(out, arenas_.p + (uint64_t)slot * arena_ + (loc & ~LOC_ARENA), len,
                               cudaMemcpyDeviceToHost, s));
    CUDA_CHECK(cudaStreamSynchronize(s));
    transfer_seconds_ += now_s() - t0;
  }

  const uint8_t* result_pool(uint32_t gi, uint64_t* len) override {
    Grp& g = grp_[gi];
    double t0 = now_s();
    g.h_cursor.resize(1);
    CUDA_CHECK(cudaMemcpyAsync(g.h_cursor.data(), g.cursor.p, sizeof(unsigned long long), cudaMemcpyDeviceToHost, g.s));
    CUDA_CHECK(cudaStreamSynchronize(g.s));
    uint64_t n = std::min<uint64_t>(g.h_cursor[0], pool_bytes_);
    g.h_pool.resize(n);
    if (n) {
      CUDA_CHECK(cudaMemcpyAsync(g.h_pool.data(), g.pool.p, n, cudaMemcpyDeviceToHost, g.s));
      CUDA_CHECK(cudaStreamSynchronize(g.s));
    }
    *len = n;
    transfer_seconds_ += now_s() - t0;
    TRACE("[gpu] g%u pool %.3fms (%llu bytes)\n", gi, (now_s() - t0) * 1e3, (unsigned long long)n);
    return g.h_pool.data();
  }

  void end(fevm_batch* b) override { (void)b; }
  double kernel_seconds(uint32_t gi) override { return grp_[gi].kernel_s; }

  void scrub(uint32_t gi, const std::vector<uint32_t>& slots) override {
    cudaStream_t s = grp_[gi].s;
    for (uint32_t sl : slots) CUDA_CHECK(cudaMemsetAsync(arenas_.p + (uint64_t)sl * arena_, 0, layout_.heap_off, s));
    CUDA_CHECK(cudaStreamSynchronize(s));
  }

 private:
  static constexpr uint32_t kGroups = 2;
  // A lane group: its stream and the buffers of its current load.
  struct Grp {
    cudaStream_t s = nullptr;
    cudaEvent_t k0 = nullptr, k1 = nullptr;
    bool busy = false;  // a round is in flight
    double kernel_s = 0;
    DevBuf<uint32_t> active;
    DevBuf<CtlEvent> events;
    DevBuf<uint8_t> pool;
    DevBuf<unsigned long long> cursor;
    PinnedVec<uint32_t> h_active;
    PinnedVec<CtlEvent> h_events;
    PinnedVec<LaneCtl> h_resp;
    PinnedVec<Msg> h_msgs;
    PinnedVec<uint32_t> h_ids;
    PinnedVec<uint8_t> h_pool;
    PinnedVec<unsigned long long> h_cursor;
  };
  int device_;
  uint64_t arena_;
  LaneLayout layout_;
  size_t max_lanes_ = 0;
  size_t n_ = 0;
  Grp grp_[kGroups];
  DevBuf<uint8_t> arenas_;
  DevBuf<u256> stacks_;
  // State cache mirror (persists across batches).
  DevBuf<BaseAccount> acc_;
  DevBuf<BaseSlot> slot_;
  DevBuf<BaseBlockHash> bh_;
  DevBuf<uint32_t> alru_, slru_;
  DevBuf<uint8_t> code_;
  size_t dev_acc_n_ = 0, dev_slot_n_ = 0, dev_bh_n_ = 0;
  DevBuf<uint32_t> stage_idx_;
  DevBuf<uint8_t> stage_ent_;
  PinnedVec<uint32_t> h_stage_idx_;
  PinnedVec<uint8_t> h_stage_;
  // Per batch.
  DevBuf<uint8_t> blob_;
  size_t blob_uploaded_ = 0;
  DevBuf<Msg> msgs_;
  DevBuf<LaneCtl> ctl_;
  DevBuf<uint32_t> lane_ids_;
  uint64_t pool_bytes_ = 0;
};

std::unique_ptr<Backend> make_gpu_backend(const fevm_config& cfg, const char** err) {
  if (!gpu_available()) {
    if (err) *err = "no CUDA device available";
    return nullptr;
  }
  try {
    return std::make_unique<GpuBackend>(cfg);
  } catch (const std::exception&) {
    if (err) *err = "CUDA backend initialisation failed";
    return nullptr;
  }
}

bool gpu_available() {
  int n = 0;
  if (cudaGetDeviceCount(&n) != cudaSuccess) return false;
  return n > 0;
}

}  // namespace fevm
