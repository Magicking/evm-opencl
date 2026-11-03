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
  BaseView base;
  Block blk;
  LaneLayout layout;
  ResultPool pool;
};

__global__ void __launch_bounds__(128) lane_kernel(KernelArgs a) {
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
    CUDA_CHECK(cudaStreamCreate(&stream_));
    size_t free_b = 0, total_b = 0;
    CUDA_CHECK(cudaMemGetInfo(&free_b, &total_b));
    // Keep headroom for tables, blob and the result pool.
    max_lanes_ = (size_t)((free_b * 0.75) / (arena_ + layout_.stack_cap * 32 + (64 << 10)));
    if (max_lanes_ < 1) max_lanes_ = 1;
  }
  ~GpuBackend() override {
    cudaSetDevice(device_);
    arenas_.release();
    stacks_.release();
    acc_.release();
    slot_.release();
    bh_.release();
    blob_.release();
    msgs_.release();
    ctl_.release();
    lane_ids_.release();
    active_.release();
    pool_.release();
    cursor_.release();
    if (stream_) cudaStreamDestroy(stream_);
  }
  const char* name() const override { return "gpu"; }
  uint64_t arena_bytes() const override { return arena_; }
  size_t max_lanes() const override { return max_lanes_; }

 protected:
  void begin(fevm_batch* b, const std::vector<uint32_t>& lanes) override {
    CUDA_CHECK(cudaSetDevice(device_));
    double t0 = now_s();
    n_ = lanes.size();
    // Arenas persist across batches; lanes leave their tables clean when they
    // finish, so only freshly allocated memory needs zeroing.
    stacks_.reserve(n_ * layout_.stack_cap, true);
    if (arenas_.reserve(n_ * arena_, true))
      CUDA_CHECK(cudaMemset2DAsync(arenas_.p, arena_, 0, layout_.heap_off, arenas_.cap / arena_, stream_));
    h_msgs_.resize(n_);
    std::vector<uint32_t> ids(n_);
    h_ctl_.assign(n_, LaneCtl{});
    for (size_t s = 0; s < n_; s++) {
      h_msgs_[s] = b->msgs[lanes[s]];
      ids[s] = lanes[s];
      b->ctl[lanes[s]] = LaneCtl{};
    }
    msgs_.reserve(n_);
    lane_ids_.reserve(n_);
    ctl_.reserve(n_);
    active_.reserve(n_);
    CUDA_CHECK(cudaMemcpyAsync(msgs_.p, h_msgs_.data(), n_ * sizeof(Msg), cudaMemcpyHostToDevice, stream_));
    CUDA_CHECK(cudaMemcpyAsync(lane_ids_.p, ids.data(), n_ * 4, cudaMemcpyHostToDevice, stream_));
    pool_bytes_ = std::max<uint64_t>(4 << 20, n_ * (16ull << 10));
    pool_.reserve(pool_bytes_);
    cursor_.reserve(1);
    CUDA_CHECK(cudaMemsetAsync(cursor_.p, 0, sizeof(unsigned long long), stream_));
    uploaded_gen_ = ~0ull;
    blob_uploaded_ = 0;
    first_round_ = true;
    CUDA_CHECK(cudaStreamSynchronize(stream_));
    transfer_seconds_ += now_s() - t0;
    TRACE("[gpu] begin n=%zu %.3fms\n", n_, (now_s() - t0) * 1e3);
  }

  void sync_tables(fevm_batch* b) {
    HostTables& T = b->T;
    if (T.generation == uploaded_gen_) return;
    acc_.reserve(T.accounts.size());
    slot_.reserve(T.slots.size());
    bh_.reserve(T.bh.size());
    CUDA_CHECK(cudaMemcpyAsync(acc_.p, T.accounts.data(), T.accounts.size() * sizeof(BaseAccount),
                               cudaMemcpyHostToDevice, stream_));
    CUDA_CHECK(cudaMemcpyAsync(slot_.p, T.slots.data(), T.slots.size() * sizeof(BaseSlot), cudaMemcpyHostToDevice,
                               stream_));
    CUDA_CHECK(
        cudaMemcpyAsync(bh_.p, T.bh.data(), T.bh.size() * sizeof(BaseBlockHash), cudaMemcpyHostToDevice, stream_));
    size_t old_cap = blob_.cap;
    blob_.reserve(T.blob.size());
    if (blob_.cap != old_cap) blob_uploaded_ = 0;
    if (T.blob.size() > blob_uploaded_) {
      CUDA_CHECK(cudaMemcpyAsync(blob_.p + blob_uploaded_, T.blob.data() + blob_uploaded_,
                                 T.blob.size() - blob_uploaded_, cudaMemcpyHostToDevice, stream_));
      blob_uploaded_ = T.blob.size();
    }
    uploaded_gen_ = T.generation;
  }

  void run_round(fevm_batch* b, const std::vector<uint32_t>& active) override {
    double t0 = now_s();
    sync_tables(b);
    // The device copy of LaneCtl is authoritative; the host only patches lanes
    // that received a precompile response (and uploads everything once at start).
    if (first_round_) {
      for (size_t s = 0; s < n_; s++) h_ctl_[s] = b->ctl[lanes_[s]];
      CUDA_CHECK(cudaMemcpyAsync(ctl_.p, h_ctl_.data(), n_ * sizeof(LaneCtl), cudaMemcpyHostToDevice, stream_));
      first_round_ = false;
    } else {
      for (uint32_t s : active) {
        const LaneCtl& c = b->ctl[lanes_[s]];
        if (!c.resp_ready) continue;
        h_ctl_[s] = c;
        CUDA_CHECK(cudaMemcpyAsync(ctl_.p + s, &h_ctl_[s], sizeof(LaneCtl), cudaMemcpyHostToDevice, stream_));
      }
    }
    CUDA_CHECK(cudaMemcpyAsync(active_.p, active.data(), active.size() * 4, cudaMemcpyHostToDevice, stream_));
    CUDA_CHECK(cudaStreamSynchronize(stream_));
    double t1 = now_s();
    TRACE("[gpu] round upload %.3fms (acc=%zu slots=%zu blob=%zu)\n", (t1 - t0) * 1e3, b->T.accounts.size(),
          b->T.slots.size(), b->T.blob.size());
    KernelArgs a;
    a.arenas = arenas_.p;
    a.stacks = stacks_.p;
    a.n_slots = n_;
    a.arena_bytes = arena_;
    a.ctl = ctl_.p;
    a.msgs = msgs_.p;
    a.lane_ids = lane_ids_.p;
    a.active = active_.p;
    a.n_active = (uint32_t)active.size();
    a.base.accounts = acc_.p;
    a.base.acc_mask = b->T.accounts.size() - 1;
    a.base.slots = slot_.p;
    a.base.slot_mask = b->T.slots.size() - 1;
    a.base.bh = bh_.p;
    a.base.bh_mask = b->T.bh.size() - 1;
    a.base.blob = blob_.p;
    a.blk = b->blk;
    a.layout = layout_;
    a.pool.data = pool_.p;
    a.pool.cap = pool_bytes_;
    a.pool.cursor = cursor_.p;
    uint32_t threads = 128;
    uint32_t blocks = (a.n_active + threads - 1) / threads;
    lane_kernel<<<blocks, threads, 0, stream_>>>(a);
    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaStreamSynchronize(stream_));
    double t2 = now_s();
    CUDA_CHECK(cudaMemcpyAsync(h_ctl_.data(), ctl_.p, n_ * sizeof(LaneCtl), cudaMemcpyDeviceToHost, stream_));
    CUDA_CHECK(cudaStreamSynchronize(stream_));
    for (size_t s = 0; s < n_; s++) b->ctl[lanes_[s]] = h_ctl_[s];
    double t3 = now_s();
    TRACE("[gpu] kernel %.3fms download %.3fms active=%zu\n", (t2 - t1) * 1e3, (t3 - t2) * 1e3, active.size());
    kernel_seconds_ = t2 - t1;
    transfer_seconds_ += (t1 - t0) + (t3 - t2);
  }

  void read_lane_bytes(uint32_t slot, Loc loc, uint64_t len, uint8_t* out) override {
    double t0 = now_s();
    CUDA_CHECK(cudaMemcpy(out, arenas_.p + (uint64_t)slot * arena_ + (loc & ~LOC_ARENA), len, cudaMemcpyDeviceToHost));
    transfer_seconds_ += now_s() - t0;
  }

  const uint8_t* result_pool(uint64_t* len) override {
    double t0 = now_s();
    unsigned long long cur = 0;
    CUDA_CHECK(cudaMemcpy(&cur, cursor_.p, sizeof(cur), cudaMemcpyDeviceToHost));
    uint64_t n = std::min<uint64_t>(cur, pool_bytes_);
    h_pool_.resize(n);
    if (n) CUDA_CHECK(cudaMemcpy(h_pool_.data(), pool_.p, n, cudaMemcpyDeviceToHost));
    *len = n;
    transfer_seconds_ += now_s() - t0;
    TRACE("[gpu] pool %.3fms (%llu bytes)\n", (now_s() - t0) * 1e3, (unsigned long long)n);
    return h_pool_.data();
  }

  void end(fevm_batch* b) override { (void)b; }
  double kernel_seconds() override { return kernel_seconds_; }

  void scrub(const std::vector<uint32_t>& slots) override {
    for (uint32_t s : slots) CUDA_CHECK(cudaMemset(arenas_.p + (uint64_t)s * arena_, 0, layout_.heap_off));
  }

 private:
  int device_;
  uint64_t arena_;
  LaneLayout layout_;
  size_t max_lanes_ = 0;
  cudaStream_t stream_ = nullptr;
  size_t n_ = 0;
  DevBuf<uint8_t> arenas_;
  DevBuf<u256> stacks_;
  DevBuf<BaseAccount> acc_;
  DevBuf<BaseSlot> slot_;
  DevBuf<BaseBlockHash> bh_;
  DevBuf<uint8_t> blob_;
  DevBuf<Msg> msgs_;
  DevBuf<LaneCtl> ctl_;
  DevBuf<uint32_t> lane_ids_;
  DevBuf<uint32_t> active_;
  DevBuf<uint8_t> pool_;
  DevBuf<unsigned long long> cursor_;
  uint64_t pool_bytes_ = 0;
  PinnedVec<LaneCtl> h_ctl_;
  PinnedVec<uint8_t> h_pool_;
  PinnedVec<Msg> h_msgs_;
  uint64_t uploaded_gen_ = ~0ull;
  size_t blob_uploaded_ = 0;
  double kernel_seconds_ = 0;
  bool first_round_ = true;
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
