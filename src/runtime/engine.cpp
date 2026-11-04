// Host runtime: base-state tables, the execution round loop, result unpacking
// and the public C API.
#include <algorithm>
#include <chrono>
#include <cstring>
#include <thread>

#include "batch.hpp"

namespace fevm {

static double now_seconds() {
  return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

static uint64_t pow2_floor(uint64_t x) {
  uint64_t p = 1;
  while (p * 2 <= x) p *= 2;
  return p;
}

LaneLayout make_layout(uint64_t A, bool external_stack) {
  LaneLayout L{};
  L.arena_bytes = A;
  uint64_t acc_cap = pow2_floor(A / 16384);
  if (acc_cap < 32) acc_cap = 32;
  if (acc_cap > 4096) acc_cap = 4096;
  uint64_t off = 256;  // LaneHdr
  auto take = [&](uint64_t n) {
    uint64_t o = (off + 63) & ~63ull;
    off = o + n;
    return o;
  };
  // Frame headers: full depth when it costs at most 1/16 of the arena.
  uint64_t frames_cap = std::min<uint64_t>(MAX_DEPTH + 1, std::max<uint64_t>(64, A / 16 / sizeof(Frame)));
  L.frames_cap = (uint32_t)frames_cap;
  L.frames_off = take(sizeof(Frame) * frames_cap);
  L.acc_cap = (uint32_t)acc_cap;
  L.acc_off = take(sizeof(Acc) * acc_cap);
  L.slot_cap = (uint32_t)(acc_cap * 4);
  L.slot_off = take(sizeof(Slot) * L.slot_cap);
  L.tslot_cap = (uint32_t)acc_cap;
  L.tslot_off = take(sizeof(TSlot) * L.tslot_cap);
  L.journal_cap = (uint32_t)(acc_cap * 8);
  L.journal_off = take(sizeof(JEntry) * L.journal_cap);
  L.logs_cap = (uint32_t)acc_cap;
  L.logs_off = take(sizeof(LogRec) * L.logs_cap);
  L.acc_list_off = take(4 * acc_cap);
  L.slot_list_off = take(4 * L.slot_cap);
  L.tslot_list_off = take(4 * L.tslot_cap);
  uint64_t heap = A / 8;
  L.heap_off = take(heap);
  L.heap_end = L.heap_off + heap;
  uint64_t stack_bytes = A / 8;
  L.stack_cap = stack_bytes / 32;
  // With an external (interleaved) stack the arena holds no stack region.
  L.stack_off = external_stack ? 0 : take(stack_bytes);
  L.mem_off = (off + 63) & ~63ull;
  L.mem_end = A;
  return L;
}

// ------------------------------------------------------------------ batch blob and cache binding

Loc blob_append(fevm_batch* b, const void* p, size_t n, size_t align) {
  size_t off = (b->blob.size() + align - 1) & ~(align - 1);
  b->blob.resize(off + n);
  if (n) memcpy(b->blob.data() + off, p, n);
  return off;
}

void bind_cache(fevm_batch* b) {
  fevm_engine* e = b->eng;
  if (e->bound == b) return;
  StateCache& C = e->cache;
  if (C.over_budget()) {
    e->backend->pull_lru(C);
    C.evict(C.budget / 2);
  }
  C.begin_batch(b->has_state_id ? b->state_id : nullptr);
  e->bound = b;
  b->acc_puts0 = C.acc_puts;
  b->slot_puts0 = C.slot_puts;
}

// ------------------------------------------------------------------ results

void unpack_result(const uint8_t* rec, LaneResult* out) {
  const PackHdr* ph = (const PackHdr*)rec;
  const uint8_t* p = rec + sizeof(PackHdr);
  out->bytes.assign(p, rec + ph->total);  // stable backing store
  const uint8_t* base = out->bytes.data();
  const uint8_t* q = base;
  out->accounts.resize(ph->n_acc);
  for (uint32_t i = 0; i < ph->n_acc; i++) {
    const PackAcc* pa = (const PackAcc*)q;
    fevm_account_diff& d = out->accounts[i];
    memcpy(d.address.bytes, pa->addr.b, 20);
    d.flags = pa->flags;
    d.nonce = pa->nonce;
    memcpy(d.balance.bytes, pa->balance, 32);
    memcpy(d.code_hash.bytes, pa->code_hash, 32);
    q += sizeof(PackAcc);
    d.code_len = pa->code_len;
    d.code = pa->code_len ? q : nullptr;
    q += pad8(pa->code_len);
  }
  out->slots.resize(ph->n_slot);
  for (uint32_t i = 0; i < ph->n_slot; i++) {
    const PackSlot* ps = (const PackSlot*)q;
    fevm_slot_diff& d = out->slots[i];
    memcpy(d.address.bytes, ps->addr.b, 20);
    memcpy(d.key.bytes, ps->key, 32);
    memcpy(d.value.bytes, ps->value, 32);
    q += sizeof(PackSlot);
  }
  out->logs.resize(ph->n_log);
  for (uint32_t i = 0; i < ph->n_log; i++) {
    const PackLog* pl = (const PackLog*)q;
    fevm_log& d = out->logs[i];
    memcpy(d.address.bytes, pl->addr.b, 20);
    d.n_topics = pl->n_topics;
    memcpy(d.topics, pl->topics, sizeof(d.topics));
    q += sizeof(PackLog);
    d.data_len = pl->data_len;
    d.data = pl->data_len ? q : nullptr;
    q += pad8(pl->data_len);
  }
  out->r.output_len = ph->out_len;
  out->r.output = ph->out_len ? q : nullptr;
  out->r.n_accounts = (uint32_t)out->accounts.size();
  out->r.accounts = out->accounts.data();
  out->r.n_slots = (uint32_t)out->slots.size();
  out->r.slots = out->slots.data();
  out->r.n_logs = (uint32_t)out->logs.size();
  out->r.logs = out->logs.data();
}

// ------------------------------------------------------------------ round loop

static void to_addr(fevm_address* d, const Address& s) { memcpy(d->bytes, s.b, 20); }
static Address from_addr(const fevm_address& s) {
  Address a;
  memcpy(a.b, s.bytes, 20);
  return a;
}

}  // namespace fevm

struct fevm_sink {
  fevm_batch* b;
  std::vector<fevm::PendingReq>* reqs;
};

namespace fevm {

// Dedupe key of a state request: kind, address and storage key or block number.
struct ReqKey {
  uint64_t w[7];
  bool operator==(const ReqKey& o) const { return memcmp(w, o.w, sizeof(w)) == 0; }
};
struct ReqKeyHash {
  size_t operator()(const ReqKey& k) const {
    uint64_t h = 0;
    for (uint64_t x : k.w) h = mix64(h ^ x);
    return (size_t)h;
  }
};

// Lanes in a group are resident together; a group runs its lanes in successive
// loads when the batch exceeds the resident limit.
struct LaneGroup {
  std::vector<uint32_t> loaded;  // batch lanes of the current load
  std::vector<uint32_t> active;  // slots still running
  uint32_t base = 0;
  uint32_t rounds = 0;
  bool live = false;
};

// Below this many lanes one group cannot fill the GPU on its own, and a second group only
// serializes with it on every state upload.
static constexpr size_t kOverlapMin = 4096;
// Lanes per group load when overlapping (measured best for erc20 at N = 10k on PCIe Gen3 x4).
static constexpr size_t kLoadLanes = 2560;

int Backend::execute(fevm_batch* b, const std::vector<uint32_t>& lanes, const fevm_host* host) {
  double t0 = now_seconds();
  transfer_seconds_ = 0;
  size_t n = lanes.size();
  if (n == 0) return 0;
  bind_cache(b);
  size_t cap = std::max<size_t>(1, std::min(n, max_lanes()));
  uint32_t G = groups() > 1 && n >= kOverlapMin && cap >= 2 ? groups() : 1;
  // Equal loads: no short tail load that would repeat every round on its own.
  // Several smaller loads pipeline better than one large one: a group's result
  // download and host fetches overlap the other group's kernel.
  size_t load_lanes = kLoadLanes;
  if (const char* v = getenv("FASTEVM_LOAD_LANES")) load_lanes = std::max<size_t>(1, strtoull(v, nullptr, 0));
  if (G > 1) cap = std::min(cap, load_lanes * G);
  size_t waves = (n + cap - 1) / cap;
  size_t per = (n + waves * G - 1) / (waves * G);
  begin(b, per * G, per);
  lanes_.assign(per * G, NO_LANE);
  uint32_t max_rounds = b->eng->cfg.max_rounds ? b->eng->cfg.max_rounds : 4096;
  std::vector<LaneGroup> gs(G);
  size_t next = 0;
  uint32_t rounds = 0;
  int rc = 0;

  auto load_next = [&](uint32_t g) {
    LaneGroup& gr = gs[g];
    gr.live = false;
    if (next >= n) return;
    size_t take = std::min(per, n - next);
    gr.loaded.assign(lanes.begin() + next, lanes.begin() + next + take);
    next += take;
    gr.base = (uint32_t)(g * per);
    load(b, g, gr.base, gr.loaded);
    gr.active.resize(take);
    for (size_t i = 0; i < take; i++) {
      gr.active[i] = gr.base + (uint32_t)i;
      lanes_[gr.base + i] = gr.loaded[i];
    }
    gr.rounds = 0;
    gr.live = true;
    launch(b, g, gr.active);
  };

  // Scrubs aborted lanes and unpacks the results of group g's finished load.
  auto finish_load = [&](uint32_t g) {
    LaneGroup& gr = gs[g];
    std::vector<uint32_t> aborted;
    for (size_t i = 0; i < gr.loaded.size(); i++) {
      const LaneCtl& c = b->ctl[gr.loaded[i]];
      if (c.result_status == FEVM_STATUS_FALLBACK && c.result_error == FEVM_ERR_HOST)
        aborted.push_back(gr.base + (uint32_t)i);
    }
    if (!aborted.empty()) scrub(g, aborted);
    uint64_t pool_len = 0;
    const uint8_t* pool = result_pool(g, &pool_len);
    for (uint32_t lane : gr.loaded) {
      LaneCtl& c = b->ctl[lane];
      LaneResult& lr = b->results[lane];
      lr.r = fevm_result{};
      if (c.result_status != FEVM_STATUS_FALLBACK && c.out_loc != LOC_NONE && c.out_loc + sizeof(PackHdr) <= pool_len)
        unpack_result(pool + c.out_loc, &lr);
      else
        lr = LaneResult{};
      lr.r.status = c.result_status;
      lr.r.error = c.result_error;
      lr.r.gas_left = c.gas_left;
      lr.r.refund = c.refund;
      lr.r.steps = c.steps;
      memcpy(lr.r.created_address.bytes, c.created.b, 20);
    }
    rounds = std::max(rounds, gr.rounds);
  };

  for (uint32_t g = 0; g < G; g++) load_next(g);
  std::vector<PendingReq> reqs;
  std::unordered_map<ReqKey, uint32_t, ReqKeyHash> dedupe;
  for (bool any = true; any;) {
    any = false;
    for (uint32_t g = 0; g < G; g++) {
      LaneGroup& gr = gs[g];
      if (!gr.live) continue;
      any = true;
      double te = now_seconds();
      wait(b, g, gr.active);
      double kt = kernel_seconds(g);
      b->stats.exec_seconds += kt >= 0 ? kt : now_seconds() - te;
      gr.rounds++;
      // Gather requests from suspended lanes.
      reqs.clear();
      dedupe.clear();
      std::vector<uint32_t> next_active;
      for (uint32_t slot : gr.active) {
        uint32_t lane = lanes_[slot];
        LaneCtl& c = b->ctl[lane];
        if (c.status != LANE_SUSPENDED) continue;
        next_active.push_back(slot);
        fevm_request r{};
        r.lane = lane;
        ReqKey key{};
        uint8_t* kb = (uint8_t*)key.w;  // kind | address | storage key or block number
        bool keyed = true;
        switch (c.req_kind) {
          case REQ_ACCOUNT:
            r.kind = FEVM_REQ_ACCOUNT;
            to_addr(&r.address, c.req_addr);
            kb[0] = 1;
            memcpy(kb + 1, c.req_addr.b, 20);
            break;
          case REQ_STORAGE:
            r.kind = FEVM_REQ_STORAGE;
            to_addr(&r.address, c.req_addr);
            c.req_key.to_be(r.key.bytes);
            kb[0] = 2;
            memcpy(kb + 1, c.req_addr.b, 20);
            memcpy(kb + 21, c.req_key.w, 32);
            break;
          case REQ_BLOCKHASH:
            r.kind = FEVM_REQ_BLOCKHASH;
            r.number = c.req_number;
            kb[0] = 3;
            memcpy(kb + 1, &c.req_number, 8);
            break;
          case REQ_PRECOMPILE:
            r.kind = FEVM_REQ_PRECOMPILE;
            to_addr(&r.address, c.req_addr);
            r.gas = c.req_gas;
            keyed = false;
            break;
          default:
            c.status = LANE_DONE;
            c.result_status = FEVM_STATUS_FALLBACK;
            c.result_error = FEVM_ERR_HOST;
            next_active.pop_back();
            continue;
        }
        bool host_warm = b->msgs[lane].use_host_warm != 0;
        if (keyed && !host_warm) {
          auto it = dedupe.find(key);
          if (it != dedupe.end()) {
            reqs[it->second].lanes.push_back(lane);
            continue;
          }
          dedupe.emplace(key, (uint32_t)reqs.size());
        }
        PendingReq pr;
        pr.req = r;
        pr.lanes.push_back(lane);
        if (c.req_kind == REQ_PRECOMPILE) {
          pr.input.resize(c.req_input_len);
          if (c.req_input_len) {
            if (c.req_input_loc & LOC_ARENA)
              read_lane_bytes(g, slot, c.req_input_loc, c.req_input_len, pr.input.data());
            else if (c.req_input_loc & LOC_CODE)
              memcpy(pr.input.data(), b->eng->cache.code.data() + (c.req_input_loc & ~LOC_CODE), c.req_input_len);
            else
              memcpy(pr.input.data(), b->blob.data() + c.req_input_loc, c.req_input_len);
          }
        }
        reqs.push_back(std::move(pr));
      }
      gr.active.swap(next_active);
      if (!gr.active.empty() && (gr.rounds >= max_rounds || !host || !host->fetch)) {
        for (uint32_t slot : gr.active) {
          LaneCtl& c = b->ctl[lanes_[slot]];
          c.status = LANE_DONE;
          c.result_status = FEVM_STATUS_FALLBACK;
          c.result_error = FEVM_ERR_HOST;
        }
        gr.active.clear();
      }
      if (!gr.active.empty()) {
        std::vector<fevm_request> flat(reqs.size());
        for (size_t i = 0; i < reqs.size(); i++) {
          flat[i] = reqs[i].req;
          if (reqs[i].req.kind == FEVM_REQ_PRECOMPILE) {
            flat[i].input = reqs[i].input.data();
            flat[i].input_len = reqs[i].input.size();
          }
        }
        fevm_sink sink{b, &reqs};
        double th = now_seconds();
        int hr = host->fetch(host->ctx, &sink, flat.data(), (uint32_t)flat.size());
        b->stats.host_seconds += now_seconds() - th;
        b->stats.requests += flat.size();
        for (uint32_t slot : gr.active) b->ctl[lanes_[slot]].status = LANE_RUNNING;
        for (auto& pr : reqs) {
          if (pr.answered && hr == 0) continue;
          for (uint32_t lane : pr.lanes) {
            LaneCtl& c = b->ctl[lane];
            c.status = LANE_DONE;
            c.result_status = FEVM_STATUS_FALLBACK;
            c.result_error = FEVM_ERR_HOST;
          }
        }
        next_active.clear();
        for (uint32_t slot : gr.active)
          if (b->ctl[lanes_[slot]].status == LANE_RUNNING) next_active.push_back(slot);
        gr.active.swap(next_active);
        if (hr != 0) rc = hr;
      }
      if (gr.active.empty()) {
        finish_load(g);
        load_next(g);
      } else {
        launch(b, g, gr.active);
      }
    }
  }
  end(b);
  b->stats.rounds += rounds;
  b->stats.transfer_seconds += transfer_seconds_;
  b->stats.total_seconds += now_seconds() - t0;
  return rc;
}

// ------------------------------------------------------------------ CPU backend

}  // namespace fevm

#include <sys/mman.h>

namespace fevm {

class CpuBackend final : public Backend {
 public:
  explicit CpuBackend(const fevm_config& cfg) {
    arena_ = cfg.lane_arena_bytes && cfg.backend == FEVM_BACKEND_CPU ? cfg.lane_arena_bytes : (16ull << 20);
    arena_ = (arena_ + 4095) & ~4095ull;
    threads_ = cfg.cpu_threads ? cfg.cpu_threads : std::max(1u, std::thread::hardware_concurrency());
    layout_ = make_layout(arena_, false);
  }
  ~CpuBackend() override { release(); }
  const char* name() const override { return "cpu"; }
  uint64_t arena_bytes() const override { return arena_; }

 protected:
  void begin(fevm_batch*, size_t slots, size_t per_group) override {
    n_ = slots;
    // Arenas persist across batches: lanes leave their tables clean when they finish.
    if (n_ * arena_ > map_bytes_) {
      release();
      map_bytes_ = n_ * arena_;
      void* p = mmap(nullptr, map_bytes_, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
      if (p == MAP_FAILED) throw std::bad_alloc();
      map_ = (uint8_t*)p;
    }
    uint64_t pool_bytes = std::max<uint64_t>(1 << 20, per_group * (16ull << 10));
    if (pool_.size() < pool_bytes) pool_.resize(pool_bytes);
  }

  void load(fevm_batch* b, uint32_t, uint32_t, const std::vector<uint32_t>& lanes) override {
    cursor_ = 0;
    for (uint32_t lane : lanes) b->ctl[lane] = LaneCtl{};
  }

  void run_lane(fevm_batch* b, uint32_t slot, const BaseView& view, ResultPool* rp) {
    uint32_t lane = lanes_[slot];
    Interp it;
    it.arena = map_ + (uint64_t)slot * arena_;
    it.stk = nullptr;
    it.ctl = &b->ctl[lane];
    it.L = &layout_;
    it.base = &view;
    it.blk = &b->blk;
    it.msg = &b->msgs[lane];
    it.pool = rp;
    it.lane = lane;
    it.bind();
    it.run();
  }

  // Runs the whole round before returning; wait() has nothing left to do.
  void launch(fevm_batch* b, uint32_t, const std::vector<uint32_t>& active) override {
    double t0 = now_seconds();
    run_round(b, active);
    round_s_ = now_seconds() - t0;
  }
  double kernel_seconds(uint32_t) override { return round_s_; }

  void run_round(fevm_batch* b, const std::vector<uint32_t>& active) {
    StateCache& C = b->eng->cache;
    BaseView view = C.view(b->blob.data(), C.code.data(), C.acc_lru.data(), C.slot_lru.data());
    ResultPool rp{pool_.data(), pool_.size(), &cursor_};
    size_t n = active.size();
    uint32_t nt = (uint32_t)std::min<size_t>(threads_, n);
    if (nt <= 1) {
      for (uint32_t s : active) run_lane(b, s, view, &rp);
      return;
    }
    std::atomic<size_t> next{0};
    std::vector<std::thread> ws;
    ws.reserve(nt);
    for (uint32_t t = 0; t < nt; t++) {
      ws.emplace_back([&]() {
        for (;;) {
          size_t i = next.fetch_add(1, std::memory_order_relaxed);
          if (i >= n) break;
          run_lane(b, active[i], view, &rp);
        }
      });
    }
    for (auto& w : ws) w.join();
  }

  void wait(fevm_batch*, uint32_t, const std::vector<uint32_t>&) override {}

  void read_lane_bytes(uint32_t, uint32_t slot, Loc loc, uint64_t len, uint8_t* out) override {
    memcpy(out, map_ + (uint64_t)slot * arena_ + (loc & ~LOC_ARENA), len);
  }

  const uint8_t* result_pool(uint32_t, uint64_t* len) override {
    *len = std::min<uint64_t>(cursor_, pool_.size());
    return pool_.data();
  }

  void end(fevm_batch*) override {}

  void scrub(uint32_t, const std::vector<uint32_t>& slots) override {
    for (uint32_t s : slots) memset(map_ + (uint64_t)s * arena_, 0, layout_.heap_off);
  }

 private:
  void release() {
    if (map_) munmap(map_, map_bytes_);
    map_ = nullptr;
    map_bytes_ = 0;
  }
  uint64_t arena_;
  uint32_t threads_;
  LaneLayout layout_;
  uint8_t* map_ = nullptr;
  uint64_t map_bytes_ = 0;
  size_t n_ = 0;
  std::vector<uint8_t> pool_;
  unsigned long long cursor_ = 0;
  double round_s_ = 0;
};

std::unique_ptr<Backend> make_cpu_backend(const fevm_config& cfg) { return std::make_unique<CpuBackend>(cfg); }

#ifndef FASTEVM_WITH_CUDA
std::unique_ptr<Backend> make_gpu_backend(const fevm_config&, const char** err) {
  if (err) *err = "fastevm built without CUDA support";
  return nullptr;
}
bool gpu_available() { return false; }
#endif

}  // namespace fevm

// ------------------------------------------------------------------ C API

using namespace fevm;

extern "C" {

uint32_t fevm_abi_version(void) { return FEVM_ABI_VERSION; }

int fevm_gpu_available(void) { return gpu_available() ? 1 : 0; }

fevm_engine* fevm_engine_create(const fevm_config* cfg, const char** err) {
  auto* e = new fevm_engine();
  if (cfg) e->cfg = *cfg;
  if (e->cfg.state_cache_bytes) e->cache.budget = e->cfg.state_cache_bytes;
  try {
    if (e->cfg.backend == FEVM_BACKEND_GPU) {
      e->backend = make_gpu_backend(e->cfg, err);
      if (!e->backend) {
        delete e;
        return nullptr;
      }
      fevm_config cc = e->cfg;
      cc.backend = FEVM_BACKEND_CPU;
      cc.lane_arena_bytes = 0;
      e->cpu = make_cpu_backend(cc);
    } else {
      e->backend = make_cpu_backend(e->cfg);
    }
  } catch (...) {
    if (err) *err = "engine initialisation failed";
    delete e;
    return nullptr;
  }
  return e;
}

void fevm_engine_destroy(fevm_engine* e) { delete e; }

fevm_batch* fevm_batch_create(fevm_engine* eng, const fevm_block_ctx* blk) {
  auto* b = new fevm_batch();
  b->eng = eng;
  b->blob.reserve(1 << 16);
  b->blob.resize(8, 0);  // offset 0 is valid but never handed out
  b->blk.coinbase = from_addr(blk->coinbase);
  b->blk.fork = blk->fork;
  b->blk.number = blk->number;
  b->blk.timestamp = blk->timestamp;
  b->blk.gas_limit = blk->gas_limit;
  b->blk.prev_randao = u256::from_be(blk->prev_randao.bytes);
  b->blk.base_fee = u256::from_be(blk->base_fee.bytes);
  b->blk.blob_base_fee = u256::from_be(blk->blob_base_fee.bytes);
  b->blk.chain_id = u256::from_be(blk->chain_id.bytes);
  return b;
}

int64_t fevm_batch_add(fevm_batch* b, const fevm_message* m) {
  if (!m) return -1;
  return fevm_batch_add_input(b, m, m->input, m->input_len);
}

int64_t fevm_batch_add_input(fevm_batch* b, const fevm_message* m, const uint8_t* input, uint64_t input_len) {
  if (!b || !m || m->kind > FEVM_MSG_CREATE) return -1;
  Msg msg{};
  msg.kind = m->kind;
  msg.use_host_warm = m->use_host_warm_flags ? 1 : 0;
  msg.nonce_preinc = m->sender_nonce_preincremented ? 1 : 0;
  if (m->frame_mode && m->kind != FEVM_MSG_CALL) return -1;
  msg.frame_mode = m->frame_mode ? 1 : 0;
  msg.frame_create = m->frame_is_create ? 1 : 0;
  msg.code_loc = m->frame_mode ? blob_append(b, m->code, m->code_len) : LOC_NONE;
  msg.code_len = m->frame_mode ? m->code_len : 0;
  msg.sender = from_addr(m->sender);
  msg.recipient = from_addr(m->recipient);
  msg.origin = from_addr(m->origin);
  msg.gas = m->gas;
  msg.value = u256::from_be(m->value.bytes);
  msg.gas_price = u256::from_be(m->gas_price.bytes);
  msg.input_loc = blob_append(b, input, input_len);
  msg.input_len = input_len;
  msg.blob_hashes_loc = blob_append(b, m->blob_hashes, (size_t)m->n_blob_hashes * 32);
  msg.n_blob_hashes = m->n_blob_hashes;
  std::vector<uint8_t> wa, ws;
  for (uint32_t i = 0; i < m->n_access_list; i++) {
    const fevm_access_entry& e = m->access_list[i];
    wa.insert(wa.end(), e.address.bytes, e.address.bytes + 20);
    for (uint32_t k = 0; k < e.n_keys; k++) {
      ws.insert(ws.end(), e.address.bytes, e.address.bytes + 20);
      ws.insert(ws.end(), e.keys[k].bytes, e.keys[k].bytes + 32);
    }
  }
  msg.warm_addrs_loc = blob_append(b, wa.data(), wa.size());
  msg.n_warm_addrs = m->n_access_list;
  msg.warm_slots_loc = blob_append(b, ws.data(), ws.size());
  msg.n_warm_slots = (uint32_t)(ws.size() / 52);
  b->msgs.push_back(msg);
  b->ctl.push_back(LaneCtl{});
  b->results.emplace_back();
  return (int64_t)b->msgs.size() - 1;
}

void fevm_batch_preload_account(fevm_batch* b, const fevm_address* addr, const fevm_account_info* info,
                                const uint8_t* code, uint64_t code_len) {
  bind_cache(b);
  b->eng->cache.put_account(from_addr(*addr), *info, code, code_len, NO_LANE);
}

void fevm_batch_preload_storage(fevm_batch* b, const fevm_address* addr, const fevm_bytes32* key,
                                const fevm_bytes32* value) {
  bind_cache(b);
  u256 v = u256::from_be(value->bytes);
  b->eng->cache.put_slot(from_addr(*addr), u256::from_be(key->bytes), v, v, NO_LANE);
}

int fevm_batch_execute(fevm_batch* b, const fevm_host* host) {
  std::vector<uint32_t> lanes(b->msgs.size());
  for (uint32_t i = 0; i < lanes.size(); i++) lanes[i] = i;
  int rc;
  try {
    bind_cache(b);
    rc = b->eng->backend->execute(b, lanes, host);
    // Lanes that exhausted the GPU arena are retried on the CPU backend.
    if (b->eng->cpu) {
      std::vector<uint32_t> retry;
      for (uint32_t i : lanes)
        if (b->ctl[i].result_status == FEVM_STATUS_FALLBACK && b->ctl[i].result_error == FEVM_ERR_RESOURCES)
          retry.push_back(i);
      if (!retry.empty()) {
        b->stats.cpu_retried_lanes += retry.size();
        int rc2 = b->eng->cpu->execute(b, retry, host);
        if (rc2) rc = rc2;
      }
    }
  } catch (...) {
    return -1;
  }
  const StateCache& C = b->eng->cache;
  b->stats.cache_account_fills = C.acc_puts - b->acc_puts0;
  b->stats.cache_slot_fills = C.slot_puts - b->slot_puts0;
  b->stats.cache_evictions = C.evictions;
  b->stats.cache_bytes = C.bytes();
  b->executed = true;
  return rc;
}

const fevm_result* fevm_batch_result(const fevm_batch* b, uint32_t lane) {
  if (!b || lane >= b->results.size()) return nullptr;
  return &b->results[lane].r;
}

uint32_t fevm_batch_result_status(const fevm_batch* b, uint32_t lane) {
  return lane < b->results.size() ? b->results[lane].r.status : FEVM_STATUS_FALLBACK;
}

uint64_t fevm_batch_result_gas_left(const fevm_batch* b, uint32_t lane) {
  return lane < b->results.size() ? b->results[lane].r.gas_left : 0;
}

void fevm_batch_stats_get(const fevm_batch* b, fevm_batch_stats* out) { *out = b->stats; }

void fevm_batch_reset(fevm_batch* b) {
  b->msgs.clear();
  b->ctl.clear();
  b->results.clear();
  b->stats = fevm_batch_stats{};
  b->executed = false;
  // Same state, new messages: host warm flags of the previous run no longer apply.
  if (b->eng->bound == b) b->eng->cache.seq++;
}

int fevm_batch_set_state_id(fevm_batch* b, const fevm_bytes32* id) {
  if (!b || !id || b->eng->bound == b) return -1;
  b->has_state_id = true;
  memcpy(b->state_id, id->bytes, 32);
  return 0;
}

int fevm_batch_commit(fevm_batch* b, const fevm_bytes32* id) {
  if (!b || !id || !b->executed || b->eng->bound != b) return -1;
  StateCache& C = b->eng->cache;
  bool ok = true;
  for (const LaneResult& lr : b->results)
    if (!C.apply(lr.r)) {
      ok = false;
      break;
    }
  if (!ok) C.flush_state();
  C.has_id = true;
  memcpy(C.id, id->bytes, 32);
  // The next batch binds afresh; it reuses the cache when it declares this id.
  b->eng->bound = nullptr;
  return ok ? 0 : 1;
}

void fevm_engine_cache_clear(fevm_engine* e) {
  e->cache.reset();
  e->bound = nullptr;
}

void fevm_batch_destroy(fevm_batch* b) {
  if (b && b->eng->bound == b) b->eng->bound = nullptr;
  delete b;
}

void fevm_sink_account(fevm_sink* s, uint32_t idx, const fevm_account_info* info, const uint8_t* code,
                       uint64_t code_len) {
  if (!s || idx >= s->reqs->size()) return;
  PendingReq& pr = (*s->reqs)[idx];
  if (pr.req.kind != FEVM_REQ_ACCOUNT) return;
  s->b->eng->cache.put_account(from_addr(pr.req.address), *info, code, code_len, info->warm ? pr.req.lane : NO_LANE);
  pr.answered = true;
}

void fevm_sink_storage(fevm_sink* s, uint32_t idx, const fevm_bytes32* current, const fevm_bytes32* original,
                       uint8_t warm) {
  if (!s || idx >= s->reqs->size()) return;
  PendingReq& pr = (*s->reqs)[idx];
  if (pr.req.kind != FEVM_REQ_STORAGE) return;
  u256 cur = u256::from_be(current->bytes);
  u256 orig = original ? u256::from_be(original->bytes) : cur;
  s->b->eng->cache.put_slot(from_addr(pr.req.address), u256::from_be(pr.req.key.bytes), cur, orig,
                   warm ? pr.req.lane : NO_LANE);
  pr.answered = true;
}

void fevm_sink_blockhash(fevm_sink* s, uint32_t idx, const fevm_bytes32* hash) {
  if (!s || idx >= s->reqs->size()) return;
  PendingReq& pr = (*s->reqs)[idx];
  if (pr.req.kind != FEVM_REQ_BLOCKHASH) return;
  s->b->eng->cache.put_blockhash(pr.req.number, hash->bytes);
  pr.answered = true;
}

void fevm_sink_precompile(fevm_sink* s, uint32_t idx, int status, uint64_t gas_left, const uint8_t* out,
                          uint64_t out_len) {
  if (!s || idx >= s->reqs->size()) return;
  PendingReq& pr = (*s->reqs)[idx];
  if (pr.req.kind != FEVM_REQ_PRECOMPILE) return;
  Loc ol = blob_append(s->b, out, out_len);
  for (uint32_t lane : pr.lanes) {
    LaneCtl& c = s->b->ctl[lane];
    c.resp_ready = 1;
    c.resp_status = status ? 1 : 0;
    c.resp_gas_left = gas_left;
    c.resp_out_loc = ol;
    c.resp_out_len = out_len;
    c.resp_depth = c.req_depth;
    c.resp_pc = c.req_pc;
  }
  pr.answered = true;
}

}  // extern "C"
