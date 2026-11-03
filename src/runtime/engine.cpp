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

// ------------------------------------------------------------------ HostTables

HostTables::HostTables() { clear(); }

void HostTables::clear() {
  accounts.assign(1024, BaseAccount{});
  slots.assign(4096, BaseSlot{});
  bh.assign(512, BaseBlockHash{});
  blob.clear();
  blob.reserve(1 << 20);
  // Reserve offset 0..7 so that location 0 is valid but never handed out for data.
  blob.resize(8, 0);
  n_acc = n_slot = n_bh = 0;
  code_by_hash.clear();
  generation++;
  rehashed = true;
}

Loc HostTables::blob_append(const void* p, size_t n, size_t align) {
  size_t off = (blob.size() + align - 1) & ~(align - 1);
  blob.resize(off + n);
  if (n) memcpy(blob.data() + off, p, n);
  generation++;
  return off;
}

template <typename T>
void HostTables::grow(std::vector<T>& v, size_t n) {
  if (n * 4 < v.size() * 3) return;
  std::vector<T> old;
  old.swap(v);
  v.assign(old.size() * 2, T{});
  uint64_t mask = v.size() - 1;
  for (auto& e : old) {
    if (!e.used) continue;
    uint64_t i;
    if constexpr (std::is_same<T, BaseAccount>::value)
      i = addr_hash(e.addr) & mask;
    else if constexpr (std::is_same<T, BaseSlot>::value)
      i = slot_hash(e.addr, e.key) & mask;
    else
      i = mix64(e.number) & mask;
    while (v[i].used) i = (i + 1) & mask;
    v[i] = e;
  }
  rehashed = true;
}

void HostTables::put_account(const Address& a, const fevm_account_info& info, const uint8_t* code, uint64_t len,
                             uint32_t warm_lane) {
  grow(accounts, n_acc + 1);
  uint64_t mask = accounts.size() - 1;
  uint64_t i = addr_hash(a) & mask;
  while (accounts[i].used && !addr_eq(accounts[i].addr, a)) i = (i + 1) & mask;
  BaseAccount& e = accounts[i];
  if (!e.used) n_acc++;
  e = BaseAccount{};
  e.addr = a;
  e.used = 1;
  e.exists = info.exists;
  e.has_storage = info.has_storage;
  e.warm_lane = warm_lane;
  e.nonce = info.nonce;
  e.balance = u256::from_be(info.balance.bytes);
  e.code_len = (uint32_t)len;
  if (len == 0) {
    memcpy(e.code_hash, empty_code_hash(), 32);
    e.code_loc = LOC_NONE;
    e.jd_loc = LOC_NONE;
  } else {
    memcpy(e.code_hash, info.code_hash.bytes, 32);
    std::string key((const char*)info.code_hash.bytes, 32);
    auto it = code_by_hash.find(key);
    if (it != code_by_hash.end()) {
      e.code_loc = it->second.first;
      e.jd_loc = it->second.second;
    } else {
      Loc cl = blob_append(code, len);
      std::vector<uint8_t> jd((len + 7) / 8 + 1);
      jumpdest_analysis(code, (uint32_t)len, jd.data());
      Loc jl = blob_append(jd.data(), jd.size());
      code_by_hash.emplace(key, std::make_pair(cl, jl));
      e.code_loc = cl;
      e.jd_loc = jl;
    }
  }
  generation++;
}

void HostTables::put_slot(const Address& a, const u256& key, const u256& value, const u256& original,
                          uint32_t warm_lane) {
  grow(slots, n_slot + 1);
  uint64_t mask = slots.size() - 1;
  uint64_t i = slot_hash(a, key) & mask;
  while (slots[i].used && !(slots[i].key == key && addr_eq(slots[i].addr, a))) i = (i + 1) & mask;
  BaseSlot& e = slots[i];
  if (!e.used) n_slot++;
  e = BaseSlot{};
  e.addr = a;
  e.used = 1;
  e.key = key;
  e.value = value;
  e.original = original;
  e.warm_lane = warm_lane;
  generation++;
}

void HostTables::put_blockhash(uint64_t n, const uint8_t* hash) {
  grow(bh, n_bh + 1);
  uint64_t mask = bh.size() - 1;
  uint64_t i = mix64(n) & mask;
  while (bh[i].used && bh[i].number != n) i = (i + 1) & mask;
  if (!bh[i].used) n_bh++;
  bh[i].used = 1;
  bh[i].number = n;
  memcpy(bh[i].hash, hash, 32);
  generation++;
}

BaseView HostTables::view(const uint8_t* blob_base) const {
  BaseView v;
  v.accounts = accounts.data();
  v.acc_mask = accounts.size() - 1;
  v.slots = slots.data();
  v.slot_mask = slots.size() - 1;
  v.bh = bh.data();
  v.bh_mask = bh.size() - 1;
  v.blob = blob_base;
  return v;
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

int Backend::execute(fevm_batch* b, const std::vector<uint32_t>& lanes, const fevm_host* host) {
  double t0 = now_seconds();
  lanes_ = lanes;
  transfer_seconds_ = 0;
  begin(b, lanes);
  uint32_t max_rounds = b->eng->cfg.max_rounds ? b->eng->cfg.max_rounds : 4096;
  std::vector<uint32_t> active(lanes.size());
  for (uint32_t i = 0; i < lanes.size(); i++) active[i] = i;
  int rc = 0;
  uint32_t rounds = 0;
  while (!active.empty()) {
    double te = now_seconds();
    run_round(b, active);
    double kt = kernel_seconds();
    b->stats.exec_seconds += kt >= 0 ? kt : now_seconds() - te;
    rounds++;
    // Gather requests from suspended lanes.
    std::vector<PendingReq> reqs;
    std::unordered_map<std::string, uint32_t> dedupe;
    std::vector<uint32_t> next;
    for (uint32_t slot : active) {
      uint32_t lane = lanes_[slot];
      LaneCtl& c = b->ctl[lane];
      if (c.status != LANE_SUSPENDED) continue;
      next.push_back(slot);
      fevm_request r{};
      r.lane = lane;
      std::string key;
      switch (c.req_kind) {
        case REQ_ACCOUNT:
          r.kind = FEVM_REQ_ACCOUNT;
          to_addr(&r.address, c.req_addr);
          key.assign("A");
          key.append((const char*)c.req_addr.b, 20);
          break;
        case REQ_STORAGE:
          r.kind = FEVM_REQ_STORAGE;
          to_addr(&r.address, c.req_addr);
          c.req_key.to_be(r.key.bytes);
          key.assign("S");
          key.append((const char*)c.req_addr.b, 20);
          key.append((const char*)r.key.bytes, 32);
          break;
        case REQ_BLOCKHASH:
          r.kind = FEVM_REQ_BLOCKHASH;
          r.number = c.req_number;
          key.assign("B");
          key.append((const char*)&c.req_number, 8);
          break;
        case REQ_PRECOMPILE:
          r.kind = FEVM_REQ_PRECOMPILE;
          to_addr(&r.address, c.req_addr);
          r.gas = c.req_gas;
          break;
        default:
          c.status = LANE_DONE;
          c.result_status = FEVM_STATUS_FALLBACK;
          c.result_error = FEVM_ERR_HOST;
          next.pop_back();
          continue;
      }
      bool host_warm = b->msgs[lane].use_host_warm != 0;
      if (!key.empty() && !host_warm) {
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
            read_lane_bytes(slot, c.req_input_loc, c.req_input_len, pr.input.data());
          else
            memcpy(pr.input.data(), b->T.blob.data() + c.req_input_loc, c.req_input_len);
        }
      }
      reqs.push_back(std::move(pr));
    }
    active.swap(next);
    if (active.empty()) break;
    if (rounds >= max_rounds || !host || !host->fetch) {
      for (uint32_t slot : active) {
        LaneCtl& c = b->ctl[lanes_[slot]];
        c.status = LANE_DONE;
        c.result_status = FEVM_STATUS_FALLBACK;
        c.result_error = FEVM_ERR_HOST;
      }
      active.clear();
      break;
    }
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
    std::vector<uint32_t> still;
    for (uint32_t slot : active) {
      LaneCtl& c = b->ctl[lanes_[slot]];
      c.status = LANE_RUNNING;
      still.push_back(slot);
    }
    for (auto& pr : reqs) {
      if (pr.answered && hr == 0) continue;
      for (uint32_t lane : pr.lanes) {
        LaneCtl& c = b->ctl[lane];
        c.status = LANE_DONE;
        c.result_status = FEVM_STATUS_FALLBACK;
        c.result_error = FEVM_ERR_HOST;
      }
    }
    active.clear();
    for (uint32_t slot : still)
      if (b->ctl[lanes_[slot]].status == LANE_RUNNING) active.push_back(slot);
    if (hr != 0) rc = hr;
  }
  std::vector<uint32_t> aborted;
  for (uint32_t slot = 0; slot < lanes_.size(); slot++) {
    const LaneCtl& c = b->ctl[lanes_[slot]];
    if (c.result_status == FEVM_STATUS_FALLBACK && c.result_error == FEVM_ERR_HOST) aborted.push_back(slot);
  }
  if (!aborted.empty()) scrub(aborted);
  uint64_t pool_len = 0;
  const uint8_t* pool = result_pool(&pool_len);
  for (uint32_t slot = 0; slot < lanes_.size(); slot++) {
    uint32_t lane = lanes_[slot];
    LaneCtl& c = b->ctl[lane];
    LaneResult& lr = b->results[lane];
    lr = LaneResult{};
    if (c.result_status != FEVM_STATUS_FALLBACK && c.out_loc != LOC_NONE && c.out_loc + sizeof(PackHdr) <= pool_len)
      unpack_result(pool + c.out_loc, &lr);
    lr.r.status = c.result_status;
    lr.r.error = c.result_error;
    lr.r.gas_left = c.gas_left;
    lr.r.refund = c.refund;
    lr.r.steps = c.steps;
    memcpy(lr.r.created_address.bytes, c.created.b, 20);
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
  void begin(fevm_batch* b, const std::vector<uint32_t>& lanes) override {
    n_ = lanes.size();
    // Arenas persist across batches: lanes leave their tables clean when they finish.
    if (n_ * arena_ > map_bytes_) {
      release();
      map_bytes_ = n_ * arena_;
      void* p = mmap(nullptr, map_bytes_, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
      if (p == MAP_FAILED) throw std::bad_alloc();
      map_ = (uint8_t*)p;
    }
    uint64_t pool_bytes = std::max<uint64_t>(1 << 20, n_ * (16ull << 10));
    if (pool_.size() < pool_bytes) pool_.resize(pool_bytes);
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

  void run_round(fevm_batch* b, const std::vector<uint32_t>& active) override {
    BaseView view = b->T.view(b->T.blob.data());
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

  void read_lane_bytes(uint32_t slot, Loc loc, uint64_t len, uint8_t* out) override {
    memcpy(out, map_ + (uint64_t)slot * arena_ + (loc & ~LOC_ARENA), len);
  }

  const uint8_t* result_pool(uint64_t* len) override {
    *len = std::min<uint64_t>(cursor_, pool_.size());
    return pool_.data();
  }

  void end(fevm_batch*) override {}

  void scrub(const std::vector<uint32_t>& slots) override {
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
  msg.code_loc = m->frame_mode ? b->T.blob_append(m->code, m->code_len) : LOC_NONE;
  msg.code_len = m->frame_mode ? m->code_len : 0;
  msg.sender = from_addr(m->sender);
  msg.recipient = from_addr(m->recipient);
  msg.origin = from_addr(m->origin);
  msg.gas = m->gas;
  msg.value = u256::from_be(m->value.bytes);
  msg.gas_price = u256::from_be(m->gas_price.bytes);
  msg.input_loc = b->T.blob_append(input, input_len);
  msg.input_len = input_len;
  msg.blob_hashes_loc = b->T.blob_append(m->blob_hashes, (size_t)m->n_blob_hashes * 32);
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
  msg.warm_addrs_loc = b->T.blob_append(wa.data(), wa.size());
  msg.n_warm_addrs = m->n_access_list;
  msg.warm_slots_loc = b->T.blob_append(ws.data(), ws.size());
  msg.n_warm_slots = (uint32_t)(ws.size() / 52);
  b->msgs.push_back(msg);
  b->ctl.push_back(LaneCtl{});
  b->results.emplace_back();
  return (int64_t)b->msgs.size() - 1;
}

void fevm_batch_preload_account(fevm_batch* b, const fevm_address* addr, const fevm_account_info* info,
                                const uint8_t* code, uint64_t code_len) {
  b->T.put_account(from_addr(*addr), *info, code, code_len, NO_LANE);
}

void fevm_batch_preload_storage(fevm_batch* b, const fevm_address* addr, const fevm_bytes32* key,
                                const fevm_bytes32* value) {
  u256 v = u256::from_be(value->bytes);
  b->T.put_slot(from_addr(*addr), u256::from_be(key->bytes), v, v, NO_LANE);
}

int fevm_batch_execute(fevm_batch* b, const fevm_host* host) {
  std::vector<uint32_t> lanes(b->msgs.size());
  for (uint32_t i = 0; i < lanes.size(); i++) lanes[i] = i;
  int rc;
  try {
    rc = 0;
    size_t chunk = b->eng->backend->max_lanes();
    for (size_t off = 0; off < lanes.size(); off += chunk) {
      size_t end = std::min(lanes.size(), off + chunk);
      std::vector<uint32_t> part(lanes.begin() + off, lanes.begin() + end);
      int r = b->eng->backend->execute(b, part, host);
      if (r) rc = r;
    }
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
}

void fevm_batch_destroy(fevm_batch* b) { delete b; }

void fevm_sink_account(fevm_sink* s, uint32_t idx, const fevm_account_info* info, const uint8_t* code,
                       uint64_t code_len) {
  if (!s || idx >= s->reqs->size()) return;
  PendingReq& pr = (*s->reqs)[idx];
  if (pr.req.kind != FEVM_REQ_ACCOUNT) return;
  s->b->T.put_account(from_addr(pr.req.address), *info, code, code_len, info->warm ? pr.req.lane : NO_LANE);
  pr.answered = true;
}

void fevm_sink_storage(fevm_sink* s, uint32_t idx, const fevm_bytes32* current, const fevm_bytes32* original,
                       uint8_t warm) {
  if (!s || idx >= s->reqs->size()) return;
  PendingReq& pr = (*s->reqs)[idx];
  if (pr.req.kind != FEVM_REQ_STORAGE) return;
  u256 cur = u256::from_be(current->bytes);
  u256 orig = original ? u256::from_be(original->bytes) : cur;
  s->b->T.put_slot(from_addr(pr.req.address), u256::from_be(pr.req.key.bytes), cur, orig,
                   warm ? pr.req.lane : NO_LANE);
  pr.answered = true;
}

void fevm_sink_blockhash(fevm_sink* s, uint32_t idx, const fevm_bytes32* hash) {
  if (!s || idx >= s->reqs->size()) return;
  PendingReq& pr = (*s->reqs)[idx];
  if (pr.req.kind != FEVM_REQ_BLOCKHASH) return;
  s->b->T.put_blockhash(pr.req.number, hash->bytes);
  pr.answered = true;
}

void fevm_sink_precompile(fevm_sink* s, uint32_t idx, int status, uint64_t gas_left, const uint8_t* out,
                          uint64_t out_len) {
  if (!s || idx >= s->reqs->size()) return;
  PendingReq& pr = (*s->reqs)[idx];
  if (pr.req.kind != FEVM_REQ_PRECOMPILE) return;
  Loc ol = s->b->T.blob_append(out, out_len);
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
