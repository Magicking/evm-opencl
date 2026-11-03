// The EVM interpreter (Cancun, Prague, Osaka), written once for host and device.
//
// A lane executes one top-level message. All of its state lives in its arena,
// so execution can stop at any opcode boundary when state is missing
// (SUSPEND) and resume in a later round once the host has supplied it.
//
// Restartability rule: an opcode performs every state lookup before any
// observable mutation (gas, warm sets, journal, stack push). On SUSPEND the
// dispatcher restores pc, gas, sp and memory size, so re-executing the opcode
// after the host answered gives exactly the same result.
#pragma once

#include "../../include/fastevm.h"
#include "../common/keccak.cuh"
#include "precompiles.cuh"
#include "types.cuh"

namespace fevm {

enum RunResult : int { RUN_DONE = 0, RUN_SUSPEND = 1 };

// Lookup outcomes.
enum : int { LK_OK = 0, LK_MISS = 1, LK_FULL = 2 };

FEVM_HD uint64_t mem_cost(uint64_t words) { return words * 3 + (words * words) / 512; }

FEVM_HD bool is_empty_code_hash(const uint8_t* h) { return mem_eq(h, empty_code_hash(), 32); }

FEVM_HD void jumpdest_analysis(const uint8_t* code, uint32_t len, uint8_t* bitmap) {
  uint32_t nbytes = (len + 7) / 8 + 1;
  mem_zero(bitmap, nbytes);
  for (uint32_t pc = 0; pc < len;) {
    uint8_t op = code[pc];
    if (op == 0x5b) {
      bitmap[pc >> 3] |= (uint8_t)(1u << (pc & 7));
      pc++;
    } else if (op >= 0x60 && op <= 0x7f) {
      pc += op - 0x5f + 1;
    } else {
      pc++;
    }
  }
}

// Lane result allocation (packed results are appended to a shared pool).
struct ResultPool {
  uint8_t* data;
  uint64_t cap;
  unsigned long long* cursor;
};

FEVM_HD uint64_t pool_alloc(ResultPool* p, uint64_t n) {
#if FEVM_ON_DEVICE
  unsigned long long off = atomicAdd(p->cursor, (unsigned long long)n);
#else
  unsigned long long off = __atomic_fetch_add(p->cursor, (unsigned long long)n, __ATOMIC_RELAXED);
#endif
  if (off + n > p->cap) return ~0ull;
  return off;
}

// Packed result layout (little-endian, 8-byte aligned records).
struct PackHdr {
  uint32_t n_acc;
  uint32_t n_slot;
  uint32_t n_log;
  uint32_t _pad;
  uint64_t out_len;
  uint64_t total;
};
struct PackAcc {
  Address addr;
  uint32_t flags;
  uint64_t nonce;
  uint8_t balance[32];
  uint8_t code_hash[32];
  uint64_t code_len;  // code bytes follow (padded to 8) when FEVM_ACC_CODE
};
struct PackSlot {
  Address addr;
  uint32_t _pad;
  uint8_t key[32];
  uint8_t value[32];
};
struct PackLog {
  Address addr;
  uint32_t n_topics;
  uint8_t topics[4][32];
  uint64_t data_len;  // data follows (padded to 8)
};

FEVM_HD uint64_t pad8(uint64_t x) { return (x + 7) & ~7ull; }

// Operand stack access. CPU: contiguous per lane (stride 1). GPU: interleaved
// across lanes (stride = lanes in the launch) so a warp's accesses coalesce.
struct StackView {
  u256* p;
  uint64_t stride;
  FEVM_HD u256& operator[](uint64_t i) const { return p[i * stride]; }
};

struct Interp {
  uint8_t* arena;
  u256* stk;           // element 0 of this lane's stack region
  uint64_t stk_stride; // distance between consecutive items, in u256 units
  LaneCtl* ctl;
  const LaneLayout* L;
  const BaseView* base;
  const Block* blk;
  const Msg* msg;
  ResultPool* pool;
  uint32_t lane;

  LaneHdr* hdr;
  Acc* accs;
  Slot* slots;
  TSlot* tslots;
  JEntry* journal;
  LogRec* logs;
  Frame* frames;
  uint32_t* acc_list;
  uint32_t* slot_list;
  uint32_t* tslot_list;
  uint32_t fatal;  // non-zero: resource exhaustion, lane falls back

  FEVM_HD void bind() {
    hdr = (LaneHdr*)arena;
    accs = (Acc*)(arena + L->acc_off);
    slots = (Slot*)(arena + L->slot_off);
    tslots = (TSlot*)(arena + L->tslot_off);
    journal = (JEntry*)(arena + L->journal_off);
    logs = (LogRec*)(arena + L->logs_off);
    frames = (Frame*)(arena + L->frames_off);
    if (!stk) {
      stk = (u256*)(arena + L->stack_off);
      stk_stride = 1;
    }
    acc_list = (uint32_t*)(arena + L->acc_list_off);
    slot_list = (uint32_t*)(arena + L->slot_list_off);
    tslot_list = (uint32_t*)(arena + L->tslot_list_off);
    fatal = 0;
  }

  FEVM_HD uint8_t* ptr(Loc l) const {
    return (l & LOC_ARENA) ? arena + (l & ~LOC_ARENA) : (uint8_t*)base->blob + l;
  }
  FEVM_HD Frame* frame(uint32_t d) const { return frames + d; }
  FEVM_HD StackView stack_of(const Frame* f) const { return StackView{stk + f->stack_base * stk_stride, stk_stride}; }

  FEVM_HD Loc heap_alloc(uint64_t n) {
    uint64_t off = pad8(hdr->heap_top);
    if (off + n > L->heap_end) {
      fatal = FEVM_ERR_RESOURCES;
      return LOC_NONE;
    }
    hdr->heap_top = off + n;
    return off | LOC_ARENA;
  }

  // ---------------------------------------------------------------- state lookups

  FEVM_HD int acc_entry(const Address& a, Acc** out) {
    uint64_t mask = L->acc_cap - 1;
    uint64_t i = addr_hash(a) & mask;
    for (;;) {
      Acc* e = &accs[i];
      if (!e->used) {
        if ((uint64_t)hdr->n_acc * 4 >= (uint64_t)L->acc_cap * 3) {
          fatal = FEVM_ERR_RESOURCES;
          return LK_FULL;
        }
        mem_zero(e, sizeof(Acc));
        e->used = 1;
        e->addr = a;
        e->code_loc = LOC_NONE;
        e->jd_loc = LOC_NONE;
        acc_list[hdr->n_acc++] = (uint32_t)i;
        *out = e;
        return LK_OK;
      }
      if (addr_eq(e->addr, a)) {
        *out = e;
        return LK_OK;
      }
      i = (i + 1) & mask;
    }
  }

  FEVM_HD int acc_get(const Address& a, Acc** out) {
    int r = acc_entry(a, out);
    if (r != LK_OK) return r;
    Acc* e = *out;
    if (!e->loaded) {
      const BaseAccount* b = base->find_account(a);
      if (!b) {
        ctl->req_kind = REQ_ACCOUNT;
        ctl->req_addr = a;
        return LK_MISS;
      }
      e->exists = b->exists;
      e->has_storage = b->has_storage;
      e->nonce = b->nonce;
      e->balance = b->balance;
      mem_copy(e->code_hash, b->code_hash, 32);
      e->code_loc = b->code_loc;
      e->code_len = b->code_len;
      e->jd_loc = b->jd_loc;
      if (msg->use_host_warm && b->warm_lane == lane) e->warm = 1;
      e->loaded = 1;
    }
    return LK_OK;
  }

  FEVM_HD bool account_storage_empty(const Address& a) const {
    const BaseAccount* b = base->find_account(a);
    return b && !b->has_storage;
  }

  FEVM_HD int slot_entry(const Address& a, const u256& k, Slot** out) {
    uint64_t mask = L->slot_cap - 1;
    uint64_t i = slot_hash(a, k) & mask;
    for (;;) {
      Slot* e = &slots[i];
      if (!e->used) {
        if ((uint64_t)hdr->n_slot * 4 >= (uint64_t)L->slot_cap * 3) {
          fatal = FEVM_ERR_RESOURCES;
          return LK_FULL;
        }
        mem_zero(e, sizeof(Slot));
        e->used = 1;
        e->addr = a;
        e->key = k;
        slot_list[hdr->n_slot++] = (uint32_t)i;
        *out = e;
        return LK_OK;
      }
      if (e->key == k && addr_eq(e->addr, a)) {
        *out = e;
        return LK_OK;
      }
      i = (i + 1) & mask;
    }
  }

  FEVM_HD int slot_get(const Address& a, const u256& k, Slot** out) {
    int r = slot_entry(a, k, out);
    if (r != LK_OK) return r;
    Slot* e = *out;
    if (!e->loaded) {
      const BaseSlot* b = base->find_slot(a, k);
      if (!b && !msg->use_host_warm && account_storage_empty(a)) {
        // Account known to have no storage at message start: every unwritten slot is zero.
        // (Not with host warm flags: the host must be asked for the slot's access-list status.)
        e->value = u256::zero();
        e->original = u256::zero();
        e->loaded = 1;
        return LK_OK;
      }
      if (!b) {
        ctl->req_kind = REQ_STORAGE;
        ctl->req_addr = a;
        ctl->req_key = k;
        return LK_MISS;
      }
      e->value = b->value;
      e->original = b->original;
      if (msg->use_host_warm && b->warm_lane == lane) e->warm = 1;
      e->loaded = 1;
    }
    return LK_OK;
  }

  FEVM_HD TSlot* tslot_find(const Address& a, const u256& k, bool insert) {
    uint64_t mask = L->tslot_cap - 1;
    uint64_t i = slot_hash(a, k) & mask;
    for (;;) {
      TSlot* e = &tslots[i];
      if (!e->used) {
        if (!insert) return nullptr;
        if ((uint64_t)hdr->n_tslot * 4 >= (uint64_t)L->tslot_cap * 3) {
          fatal = FEVM_ERR_RESOURCES;
          return nullptr;
        }
        mem_zero(e, sizeof(TSlot));
        e->used = 1;
        e->addr = a;
        e->key = k;
        tslot_list[hdr->n_tslot++] = (uint32_t)i;
        return e;
      }
      if (e->key == k && addr_eq(e->addr, a)) return e;
      i = (i + 1) & mask;
    }
  }

  FEVM_HD bool acc_empty(const Acc* e) const {
    return !e->exists || (e->nonce == 0 && e->balance.is_zero() && e->code_len == 0);
  }
  FEVM_HD bool acc_warm(const Acc* e) const { return e->warm || is_precompile(blk->fork, e->addr); }

  FEVM_HD bool is_delegation(const Acc* e) const {
    if (blk->fork < FORK_PRAGUE || e->code_len != 23) return false;
    const uint8_t* c = ptr(e->code_loc);
    return c[0] == 0xef && c[1] == 0x01 && c[2] == 0x00;
  }
  FEVM_HD Address delegation_target(const Acc* e) const {
    Address a;
    mem_copy(a.b, ptr(e->code_loc) + 3, 20);
    return a;
  }

  // ---------------------------------------------------------------- journaled mutations

  FEVM_HD bool jpush(uint32_t kind, uint32_t idx, const u256& prev, uint64_t prev2) {
    if (hdr->n_journal >= L->journal_cap) {
      fatal = FEVM_ERR_RESOURCES;
      return false;
    }
    JEntry* j = &journal[hdr->n_journal++];
    j->kind = kind;
    j->idx = idx;
    j->prev = prev;
    j->prev2 = prev2;
    return true;
  }
  FEVM_HD uint32_t aidx(const Acc* e) const { return (uint32_t)(e - accs); }

  FEVM_HD bool set_balance(Acc* e, const u256& v) {
    if (!jpush(J_BALANCE, aidx(e), e->balance, 0)) return false;
    e->balance = v;
    return true;
  }
  FEVM_HD bool set_nonce(Acc* e, uint64_t v) {
    if (!jpush(J_NONCE, aidx(e), u256::zero(), e->nonce)) return false;
    e->nonce = v;
    return true;
  }
  FEVM_HD bool warm_acc(Acc* e) {
    if (e->warm) return true;
    if (!jpush(J_WARM_ACC, aidx(e), u256::zero(), 0)) return false;
    e->warm = 1;
    return true;
  }
  // geth AddBalance(addr, 0) / Transfer: touch + implicit account creation.
  FEVM_HD bool touch(Acc* e) {
    if (!e->touched) {
      if (!jpush(J_TOUCH, aidx(e), u256::zero(), 0)) return false;
      e->touched = 1;
    }
    return mark_exists(e);
  }
  FEVM_HD bool mark_exists(Acc* e) {
    if (e->exists) return true;
    if (!jpush(J_EXISTS, aidx(e), u256::zero(), 0)) return false;
    e->exists = 1;
    return true;
  }
  FEVM_HD bool add_balance(Acc* e, const u256& v) {
    if (!touch(e)) return false;
    if (v.is_zero()) return true;
    return set_balance(e, add(e->balance, v));
  }
  FEVM_HD bool sub_balance(Acc* e, const u256& v) {
    if (!touch(e)) return false;
    if (v.is_zero()) return true;
    return set_balance(e, sub(e->balance, v));
  }
  FEVM_HD bool transfer(Acc* from, Acc* to, const u256& v) { return sub_balance(from, v) && add_balance(to, v); }

  FEVM_HD bool add_refund(int64_t d) {
    if (!jpush(J_REFUND, 0, u256::zero(), (uint64_t)hdr->refund)) return false;
    hdr->refund += d;
    return true;
  }

  FEVM_HD void revert_to(uint32_t snap) {
    while (hdr->n_journal > snap) {
      JEntry* j = &journal[--hdr->n_journal];
      switch (j->kind) {
        case J_BALANCE: accs[j->idx].balance = j->prev; break;
        case J_NONCE: accs[j->idx].nonce = j->prev2; break;
        case J_WARM_ACC: accs[j->idx].warm = 0; break;
        case J_WARM_SLOT: slots[j->idx].warm = 0; break;
        case J_TOUCH: accs[j->idx].touched = 0; break;
        case J_EXISTS: accs[j->idx].exists = 0; break;
        case J_CREATED: accs[j->idx].created = 0; break;
        case J_DESTRUCT: accs[j->idx].destructed = 0; break;
        case J_CODE: {
          Acc* e = &accs[j->idx];
          e->code_set = 0;
          e->code_len = 0;
          e->code_loc = LOC_NONE;
          e->jd_loc = LOC_NONE;
          mem_copy(e->code_hash, empty_code_hash(), 32);
          break;
        }
        case J_STORAGE: slots[j->idx].value = j->prev; break;
        case J_TSTORE: tslots[j->idx].value = j->prev; break;
        case J_REFUND: hdr->refund = (int64_t)j->prev2; break;
        case J_LOG: hdr->n_logs = (uint32_t)j->prev2; break;
        default: break;
      }
    }
  }

  // ---------------------------------------------------------------- frames & memory

  FEVM_HD Loc ensure_jd(Acc* e) {
    if (e->jd_loc != LOC_NONE) return e->jd_loc;
    Loc l = heap_alloc((e->code_len + 7) / 8 + 1);
    if (l == LOC_NONE) return LOC_NONE;
    jumpdest_analysis(ptr(e->code_loc), e->code_len, ptr(l));
    e->jd_loc = l;
    return l;
  }

  // Allocates a new frame on top of the current one. Returns nullptr on resource exhaustion.
  FEVM_HD Frame* push_frame() {
    uint32_t d = hdr->phase == 0 ? 0 : hdr->depth + 1;
    uint64_t stack_base, mem_off, rd_off;
    if (d == 0) {
      stack_base = 0;
      mem_off = L->mem_off;
      rd_off = L->mem_end;
    } else {
      Frame* p = frame(d - 1);
      stack_base = p->stack_base + p->sp;
      mem_off = (p->mem_off + p->mem_size + 31) & ~31ull;
      rd_off = p->rd_off;
    }
    if (d >= L->frames_cap || stack_base + STACK_LIMIT > L->stack_cap || mem_off > rd_off) {
      fatal = FEVM_ERR_RESOURCES;
      return nullptr;
    }
    Frame* f = frame(d);
    mem_zero(f, sizeof(Frame));
    f->stack_base = stack_base;
    f->mem_off = mem_off;
    f->rd_off = rd_off;
    hdr->depth = d;
    hdr->phase = 1;
    return f;
  }

  // Memory end for (off,len); false on overflow beyond geth's limit.
  FEVM_HD static bool mem_end(const u256& off, const u256& len, uint64_t* end) {
    if (len.is_zero()) {
      *end = 0;
      return true;
    }
    if (!off.fits_u64() || !len.fits_u64()) return false;
    uint64_t o = off.w[0], l = len.w[0];
    if (o > 0x1FFFFFFFE0ull || l > 0x1FFFFFFFE0ull || o + l > 0x1FFFFFFFE0ull) return false;
    *end = o + l;
    return true;
  }

  // Charge and grow memory to `end` bytes. 0 ok, 1 OOG, 2 resources.
  FEVM_HD int mem_grow(Frame* f, int64_t* gas, uint64_t end) {
    if (end <= f->mem_size) return 0;
    uint64_t nw = (end + 31) / 32;
    uint64_t ow = f->mem_size / 32;
    uint64_t cost = mem_cost(nw) - mem_cost(ow);
    if ((uint64_t)*gas < cost) return 1;
    uint64_t ns = nw * 32;
    if (f->mem_off + ns > f->rd_off) {
      fatal = FEVM_ERR_RESOURCES;
      return 2;
    }
    *gas -= (int64_t)cost;
    mem_zero(arena + f->mem_off + f->mem_size, ns - f->mem_size);
    f->mem_size = ns;
    return 0;
  }

  // Sets frame f's return data to a copy of [src, src+len).
  FEVM_HD bool set_returndata(uint32_t d, const uint8_t* src, uint64_t len) {
    Frame* f = frame(d);
    uint64_t top = d == 0 ? L->mem_end : frame(d - 1)->rd_off;
    if (len == 0) {
      f->rd_off = top;
      f->rd_len = 0;
      return true;
    }
    if (len > top) {
      fatal = FEVM_ERR_RESOURCES;
      return false;
    }
    uint64_t off = (top - len) & ~31ull;
    if (off < f->mem_off + f->mem_size) {
      fatal = FEVM_ERR_RESOURCES;
      return false;
    }
    mem_move(arena + off, src, len);
    f->rd_off = off;
    f->rd_len = len;
    return true;
  }

  // Copies data into memory with zero padding from a source of size src_len.
  FEVM_HD void copy_padded(uint8_t* dst, const uint8_t* src, uint64_t src_len, const u256& src_off, uint64_t len) {
    uint64_t o = src_off.fits_u64() ? src_off.w[0] : ~0ull;
    for (uint64_t i = 0; i < len; i++) {
      uint64_t s = o + i;
      dst[i] = (o != ~0ull && s >= o && s < src_len) ? src[s] : 0;
    }
  }

  // ---------------------------------------------------------------- logs

  FEVM_HD bool add_log(const Address& a, const u256* topics, uint32_t n, const uint8_t* data, uint64_t len) {
    if (hdr->n_logs >= L->logs_cap) {
      fatal = FEVM_ERR_RESOURCES;
      return false;
    }
    Loc dl = LOC_NONE;
    if (len) {
      dl = heap_alloc(len);
      if (dl == LOC_NONE) return false;
      mem_copy(ptr(dl), data, len);
    }
    if (!jpush(J_LOG, 0, u256::zero(), hdr->n_logs)) return false;
    LogRec* r = &logs[hdr->n_logs++];
    r->addr = a;
    r->n_topics = n;
    for (uint32_t i = 0; i < n; i++) r->topics[i] = topics[i];
    r->data_loc = dl;
    r->data_len = len;
    return true;
  }

  // ---------------------------------------------------------------- lane lifecycle

  FEVM_HD void finish_lane(uint32_t status, uint32_t err, int64_t gas_left, const uint8_t* out, uint64_t out_len) {
    hdr->phase = 2;
    ctl->status = LANE_DONE;
    ctl->result_status = status;
    ctl->result_error = err;
    ctl->gas_left = gas_left < 0 ? 0 : (uint64_t)gas_left;
    ctl->refund = hdr->refund;
    ctl->created = hdr->created;
    ctl->steps = hdr->steps;
    pack(out, out_len);
    release_tables();
  }

  // Returns the lane's tables to the all-zero state so the arena can be reused
  // without clearing it (only touched entries are visited).
  FEVM_HD void release_tables() {
    for (uint32_t li = 0; li < hdr->n_acc; li++) mem_zero(&accs[acc_list[li]], sizeof(Acc));
    for (uint32_t li = 0; li < hdr->n_slot; li++) mem_zero(&slots[slot_list[li]], sizeof(Slot));
    for (uint32_t li = 0; li < hdr->n_tslot; li++) mem_zero(&tslots[tslot_list[li]], sizeof(TSlot));
    hdr->n_acc = hdr->n_slot = hdr->n_tslot = 0;
    hdr->n_journal = hdr->n_logs = 0;
  }

  FEVM_HD void fallback(uint32_t err) {
    hdr->phase = 2;
    ctl->status = LANE_DONE;
    ctl->result_status = FEVM_STATUS_FALLBACK;
    ctl->result_error = err;
    ctl->out_loc = LOC_NONE;
    ctl->out_len = 0;
    release_tables();
  }

  // Writes the state diff, logs and output to the shared result pool.
  FEVM_HD void pack(const uint8_t* out, uint64_t out_len) {
    uint64_t total = sizeof(PackHdr);
    uint32_t na = 0, ns = 0;
    bool ok_status = ctl->result_status == FEVM_STATUS_SUCCESS;
    for (uint32_t li = 0; li < hdr->n_acc; li++) {
      const Acc* e = &accs[acc_list[li]];
      if (!e->loaded) continue;
      uint32_t fl = acc_flags(e);
      if (!fl) continue;
      na++;
      total += sizeof(PackAcc);
      if (fl & FEVM_ACC_CODE) total += pad8(e->code_len);
    }
    for (uint32_t li = 0; li < hdr->n_slot; li++) {
      const Slot* e = &slots[slot_list[li]];
      if (!e->loaded) continue;
      const BaseSlot* b = base->find_slot(e->addr, e->key);
      if (b && b->value == e->value) continue;
      if (!b && e->value.is_zero()) continue;
      ns++;
    }
    total += (uint64_t)ns * sizeof(PackSlot);
    uint32_t nl = ok_status ? hdr->n_logs : 0;
    for (uint32_t i = 0; i < nl; i++) total += sizeof(PackLog) + pad8(logs[i].data_len);
    total += pad8(out_len);
    uint64_t off = pool_alloc(pool, total);
    if (off == ~0ull) {
      fallback(FEVM_ERR_RESOURCES);
      return;
    }
    uint8_t* w = pool->data + off;
    PackHdr* ph = (PackHdr*)w;
    ph->n_acc = na;
    ph->n_slot = ns;
    ph->n_log = nl;
    ph->_pad = 0;
    ph->out_len = out_len;
    ph->total = total;
    w += sizeof(PackHdr);
    for (uint32_t li = 0; li < hdr->n_acc; li++) {
      const Acc* e = &accs[acc_list[li]];
      if (!e->loaded) continue;
      uint32_t fl = acc_flags(e);
      if (!fl) continue;
      PackAcc* pa = (PackAcc*)w;
      pa->addr = e->addr;
      pa->flags = fl;
      pa->nonce = e->nonce;
      e->balance.to_be(pa->balance);
      mem_copy(pa->code_hash, e->code_hash, 32);
      pa->code_len = (fl & FEVM_ACC_CODE) ? e->code_len : 0;
      w += sizeof(PackAcc);
      if (fl & FEVM_ACC_CODE) {
        mem_copy(w, ptr(e->code_loc), e->code_len);
        w += pad8(e->code_len);
      }
    }
    for (uint32_t li = 0; li < hdr->n_slot; li++) {
      const Slot* e = &slots[slot_list[li]];
      if (!e->loaded) continue;
      const BaseSlot* b = base->find_slot(e->addr, e->key);
      if (b && b->value == e->value) continue;
      if (!b && e->value.is_zero()) continue;
      PackSlot* ps = (PackSlot*)w;
      ps->addr = e->addr;
      ps->_pad = 0;
      e->key.to_be(ps->key);
      e->value.to_be(ps->value);
      w += sizeof(PackSlot);
    }
    for (uint32_t i = 0; i < nl; i++) {
      const LogRec* r = &logs[i];
      PackLog* pl = (PackLog*)w;
      pl->addr = r->addr;
      pl->n_topics = r->n_topics;
      for (uint32_t t = 0; t < 4; t++) {
        if (t < r->n_topics)
          r->topics[t].to_be(pl->topics[t]);
        else
          mem_zero(pl->topics[t], 32);
      }
      pl->data_len = r->data_len;
      w += sizeof(PackLog);
      if (r->data_len) mem_copy(w, ptr(r->data_loc), r->data_len);
      w += pad8(r->data_len);
    }
    if (out_len) mem_copy(w, out, out_len);
    ctl->out_loc = off;
    ctl->out_len = total;
  }

  FEVM_HD uint32_t acc_flags(const Acc* e) const {
    const BaseAccount* b = base->find_account(e->addr);
    uint32_t fl = 0;
    if (!b) return 0;
    if (e->balance != b->balance) fl |= FEVM_ACC_BALANCE;
    if (e->nonce != b->nonce) fl |= FEVM_ACC_NONCE;
    if (e->code_set) fl |= FEVM_ACC_CODE;
    if (e->created) fl |= FEVM_ACC_CREATED;
    if (e->destructed) fl |= FEVM_ACC_DESTRUCTED;
    // A touch only matters for EIP-158 clearing of accounts that end up empty.
    if (e->touched && acc_empty(e)) fl |= FEVM_ACC_TOUCHED;
    return fl;
  }

  // ---------------------------------------------------------------- lane initialisation

  FEVM_HD void init_lane() {
    // Tables are clean (fresh arena or released by the previous lane).
    hdr->phase = 0;
    hdr->depth = 0;
    hdr->n_journal = 0;
    hdr->n_logs = 0;
    hdr->heap_top = L->heap_off;
    hdr->refund = 0;
    hdr->steps = 0;
    mem_zero(hdr->created.b, 20);
    ctl->req_kind = REQ_NONE;
    ctl->resp_ready = 0;
    // Pre-warm: sender, recipient (or created address later), coinbase, access list.
    Acc* e;
    if (acc_entry(msg->sender, &e) != LK_OK) return;
    e->warm = 1;
    if (msg->kind == FEVM_MSG_CALL) {
      if (acc_entry(msg->recipient, &e) != LK_OK) return;
      e->warm = 1;
    }
    if (acc_entry(blk->coinbase, &e) != LK_OK) return;
    e->warm = 1;
    const uint8_t* wa = ptr(msg->warm_addrs_loc);
    for (uint32_t i = 0; i < msg->n_warm_addrs; i++) {
      Address a;
      mem_copy(a.b, wa + i * 20, 20);
      if (acc_entry(a, &e) != LK_OK) return;
      e->warm = 1;
    }
    const uint8_t* ws = ptr(msg->warm_slots_loc);
    for (uint32_t i = 0; i < msg->n_warm_slots; i++) {
      Address a;
      mem_copy(a.b, ws + i * 52, 20);
      u256 k = u256::from_be(ws + i * 52 + 20);
      Slot* s;
      if (slot_entry(a, k, &s) != LK_OK) return;
      s->warm = 1;
    }
  }

  FEVM_HD void suspend_request_precompile(const Address& a, Loc in, uint64_t len, uint64_t gas, uint32_t pc) {
    ctl->req_kind = REQ_PRECOMPILE;
    ctl->req_addr = a;
    ctl->req_input_loc = in;
    ctl->req_input_len = len;
    ctl->req_gas = gas;
    ctl->req_depth = hdr->phase == 0 ? 0xffffffffu : hdr->depth;
    ctl->req_pc = pc;
  }
  FEVM_HD bool precompile_ready(uint32_t pc) const {
    uint32_t d = hdr->phase == 0 ? 0xffffffffu : hdr->depth;
    return ctl->resp_ready && ctl->resp_depth == d && ctl->resp_pc == pc;
  }

  // Runs a precompile synchronously when possible. Returns:
  //   0 = done (*ok, *gas_left, output in *out/*out_len), 1 = suspended (host request issued)
  FEVM_HD int call_precompile(const Address& a, const uint8_t* in, Loc in_loc, uint64_t in_len, uint64_t gas,
                              uint32_t pc, bool* ok, uint64_t* gas_left, const uint8_t** out, uint64_t* out_len,
                              uint8_t* scratch) {
    uint32_t where = precompile_where(blk->fork, a);
    if (where == PC_LANE) {
      uint64_t used = 0;
      uint32_t idx = addr_low_index(a);
      bool r = run_lane_precompile(idx, in, in_len, gas, &used, scratch, out_len);
      *ok = r;
      *gas_left = r ? gas - used : 0;
      *out = idx == 0x04 ? in : scratch;
      if (!r) *out_len = 0;
      return 0;
    }
    if (!precompile_ready(pc)) {
      suspend_request_precompile(a, in_loc, in_len, gas, pc);
      return 1;
    }
    *ok = ctl->resp_status == 0;
    *gas_left = *ok ? ctl->resp_gas_left : 0;
    *out = ptr(ctl->resp_out_loc);
    *out_len = *ok ? ctl->resp_out_len : 0;
    return 0;
  }
  FEVM_HD void consume_precompile_response() { ctl->resp_ready = 0; }

  // ---------------------------------------------------------------- top-level message start

  // Returns RUN_SUSPEND if state is missing; otherwise the lane is either done or has frame 0.
  FEVM_HD int start_message() {
    Acc *snd, *tgt = nullptr, *del = nullptr;
    int r = acc_get(msg->sender, &snd);
    if (r) return r == LK_MISS ? RUN_SUSPEND : (fallback(FEVM_ERR_RESOURCES), RUN_DONE);
    int64_t gas = (int64_t)msg->gas;
    const u256& value = msg->value;
    if (msg->kind == FEVM_MSG_CREATE) {
      // Address from the sender nonce before the increment.
      const bool preinc = msg->nonce_preinc != 0;
      Address na = create_address(msg->sender, preinc ? snd->nonce - 1 : snd->nonce);
      r = acc_get(na, &tgt);
      if (r) return r == LK_MISS ? RUN_SUSPEND : (fallback(FEVM_ERR_RESOURCES), RUN_DONE);
      if (lt(snd->balance, value)) {
        finish_lane(FEVM_STATUS_FAILURE, FEVM_ERR_INSUFFICIENT_BALANCE, gas, nullptr, 0);
        return RUN_DONE;
      }
      if (!preinc && snd->nonce + 1 < snd->nonce) {
        finish_lane(FEVM_STATUS_FAILURE, FEVM_ERR_NONCE_OVERFLOW, gas, nullptr, 0);
        return RUN_DONE;
      }
      if ((!preinc && !set_nonce(snd, snd->nonce + 1)) || !warm_acc(tgt)) return (fallback(fatal), RUN_DONE);
      hdr->created = na;
      if (tgt->nonce != 0 || tgt->code_len != 0) {
        finish_lane(FEVM_STATUS_HALT, FEVM_ERR_CONTRACT_COLLISION, 0, nullptr, 0);
        return RUN_DONE;
      }
      uint32_t snap = hdr->n_journal;
      if (!begin_create_account(snd, tgt, value)) return (fallback(fatal), RUN_DONE);
      Frame* f = push_frame();
      if (!f) return (fallback(fatal), RUN_DONE);
      Loc jd = heap_alloc((msg->input_len + 7) / 8 + 1);
      if (jd == LOC_NONE) return (fallback(fatal), RUN_DONE);
      jumpdest_analysis(ptr(msg->input_loc), (uint32_t)msg->input_len, ptr(jd));
      f->code_loc = msg->input_loc;
      f->code_len = (uint32_t)msg->input_len;
      f->jd_loc = jd;
      f->gas = gas;
      f->kind = FK_CREATE;
      f->input_loc = LOC_NONE;
      f->input_len = 0;
      f->caller = msg->sender;
      f->address = na;
      f->code_address = na;
      f->value = value;
      f->journal_snap = snap;
      return RUN_DONE;
    }
    r = acc_get(msg->recipient, &tgt);
    if (r) return r == LK_MISS ? RUN_SUSPEND : (fallback(FEVM_ERR_RESOURCES), RUN_DONE);
    if (msg->frame_mode) return start_frame(tgt, gas);
    bool pre = is_precompile(blk->fork, msg->recipient);
    if (!pre && is_delegation(tgt)) {
      r = acc_get(delegation_target(tgt), &del);
      if (r) return r == LK_MISS ? RUN_SUSPEND : (fallback(FEVM_ERR_RESOURCES), RUN_DONE);
    }
    if (!value.is_zero() && lt(snd->balance, value)) {
      finish_lane(FEVM_STATUS_FAILURE, FEVM_ERR_INSUFFICIENT_BALANCE, gas, nullptr, 0);
      return RUN_DONE;
    }
    if (!tgt->exists && !pre && value.is_zero()) {
      finish_lane(FEVM_STATUS_SUCCESS, FEVM_ERR_NONE, gas, nullptr, 0);
      return RUN_DONE;
    }
    if (pre) {
      bool ok;
      uint64_t gl, olen;
      const uint8_t* out;
      uint8_t scratch[64];
      if (call_precompile(msg->recipient, ptr(msg->input_loc), msg->input_loc, msg->input_len, (uint64_t)gas, 0, &ok,
                          &gl, &out, &olen, scratch))
        return RUN_SUSPEND;
      consume_precompile_response();
      if (!mark_exists(tgt) || !transfer(snd, tgt, value)) return (fallback(fatal), RUN_DONE);
      if (!ok) {
        revert_to(0);
        finish_lane(FEVM_STATUS_HALT, FEVM_ERR_PRECOMPILE, 0, nullptr, 0);
      } else {
        finish_lane(FEVM_STATUS_SUCCESS, FEVM_ERR_NONE, (int64_t)gl, out, olen);
      }
      return RUN_DONE;
    }
    if (!mark_exists(tgt) || !transfer(snd, tgt, value)) return (fallback(fatal), RUN_DONE);
    Acc* code_acc = del ? del : tgt;
    if (code_acc->code_len == 0) {
      finish_lane(FEVM_STATUS_SUCCESS, FEVM_ERR_NONE, gas, nullptr, 0);
      return RUN_DONE;
    }
    Loc jd = ensure_jd(code_acc);
    if (jd == LOC_NONE) return (fallback(fatal), RUN_DONE);
    Frame* f = push_frame();
    if (!f) return (fallback(fatal), RUN_DONE);
    f->code_loc = code_acc->code_loc;
    f->code_len = code_acc->code_len;
    f->jd_loc = jd;
    f->gas = gas;
    f->kind = FK_CALL;
    f->input_loc = msg->input_loc;
    f->input_len = msg->input_len;
    f->caller = msg->sender;
    f->address = msg->recipient;
    f->code_address = msg->recipient;
    f->value = value;
    f->journal_snap = 0;
    return RUN_DONE;
  }

  // Frame mode: the client applied transfer/creation already; run msg->code_loc as frame 0.
  FEVM_HD int start_frame(Acc* tgt, int64_t gas) {
    if (msg->frame_create && !tgt->created) {
      // Created by the client in this transaction: same-tx SELFDESTRUCT rules apply (EIP-6780).
      if (!jpush(J_CREATED, aidx(tgt), u256::zero(), 0)) return (fallback(fatal), RUN_DONE);
      tgt->created = 1;
      hdr->created = msg->recipient;
    }
    if (msg->code_len == 0) {
      finish_lane(FEVM_STATUS_SUCCESS, FEVM_ERR_NONE, gas, nullptr, 0);
      return RUN_DONE;
    }
    Loc jd = heap_alloc((msg->code_len + 7) / 8 + 1);
    if (jd == LOC_NONE) return (fallback(fatal), RUN_DONE);
    jumpdest_analysis(ptr(msg->code_loc), (uint32_t)msg->code_len, ptr(jd));
    Frame* f = push_frame();
    if (!f) return (fallback(fatal), RUN_DONE);
    f->code_loc = msg->code_loc;
    f->code_len = (uint32_t)msg->code_len;
    f->jd_loc = jd;
    f->gas = gas;
    f->kind = FK_CALL;
    f->input_loc = msg->frame_create ? LOC_NONE : msg->input_loc;
    f->input_len = msg->frame_create ? 0 : msg->input_len;
    f->caller = msg->sender;
    f->address = msg->recipient;
    f->code_address = msg->recipient;
    f->value = msg->value;
    f->journal_snap = 0;
    return RUN_DONE;
  }

  FEVM_HD static Address create_address(const Address& sender, uint64_t nonce) {
    uint8_t buf[32];
    uint32_t n = 0;
    uint8_t nb[8];
    uint32_t nlen = 0;
    for (int i = 7; i >= 0; i--) {
      uint8_t b = (uint8_t)(nonce >> (i * 8));
      if (nlen == 0 && b == 0) continue;
      nb[nlen++] = b;
    }
    uint32_t nonce_enc = (nonce == 0) ? 1 : (nonce < 0x80 ? 1 : 1 + nlen);
    buf[n++] = (uint8_t)(0xc0 + 21 + nonce_enc);
    buf[n++] = 0x94;
    for (int i = 0; i < 20; i++) buf[n++] = sender.b[i];
    if (nonce == 0) {
      buf[n++] = 0x80;
    } else if (nonce < 0x80) {
      buf[n++] = (uint8_t)nonce;
    } else {
      buf[n++] = (uint8_t)(0x80 + nlen);
      for (uint32_t i = 0; i < nlen; i++) buf[n++] = nb[i];
    }
    uint8_t h[32];
    keccak256(buf, n, h);
    Address a;
    mem_copy(a.b, h + 12, 20);
    return a;
  }

  FEVM_HD static Address create2_address(const Address& sender, const u256& salt, const uint8_t* code, uint64_t len) {
    uint8_t buf[85];
    buf[0] = 0xff;
    mem_copy(buf + 1, sender.b, 20);
    salt.to_be(buf + 21);
    keccak256(code, len, buf + 53);
    uint8_t h[32];
    keccak256(buf, 85, h);
    Address a;
    mem_copy(a.b, h + 12, 20);
    return a;
  }

  // CreateAccount/CreateContract/SetNonce(1)/Transfer for a new contract.
  FEVM_HD bool begin_create_account(Acc* creator, Acc* tgt, const u256& value) {
    if (!mark_exists(tgt)) return false;
    if (!tgt->created) {
      if (!jpush(J_CREATED, aidx(tgt), u256::zero(), 0)) return false;
      tgt->created = 1;
    }
    if (!set_nonce(tgt, 1)) return false;
    return transfer(creator, tgt, value);
  }

  // ---------------------------------------------------------------- frame completion

  // Ends the current frame. Handles code deposit, revert, and resumption of the parent.
  FEVM_HD void end_frame(uint32_t status, uint32_t err, int64_t gas, const uint8_t* out, uint64_t out_len) {
    uint32_t d = hdr->depth;
    Frame* f = frame(d);
    bool is_create = f->kind == FK_CREATE || f->kind == FK_CREATE2;
    if (status == FEVM_STATUS_SUCCESS && is_create) {
      if (out_len >= 1 && out[0] == 0xef) {
        status = FEVM_STATUS_HALT;
        err = FEVM_ERR_INVALID_CODE_PREFIX;
      } else if ((uint64_t)gas < out_len * 200) {
        status = FEVM_STATUS_HALT;
        err = FEVM_ERR_OUT_OF_GAS;
      } else if (out_len > MAX_CODE_SIZE) {
        status = FEVM_STATUS_HALT;
        err = FEVM_ERR_CODE_SIZE;
      } else {
        gas -= (int64_t)(out_len * 200);
        if (out_len > 0) {
          Acc* e;
          if (acc_entry(f->address, &e) != LK_OK) return fallback(fatal);
          Loc cl = heap_alloc(out_len);
          if (cl == LOC_NONE) return fallback(fatal);
          mem_copy(ptr(cl), out, out_len);
          if (!jpush(J_CODE, aidx(e), u256::zero(), 0)) return fallback(fatal);
          e->code_loc = cl;
          e->code_len = (uint32_t)out_len;
          e->code_set = 1;
          e->jd_loc = LOC_NONE;
          keccak256(out, out_len, e->code_hash);
        }
      }
    }
    if (status != FEVM_STATUS_SUCCESS) revert_to(f->journal_snap);
    if (status == FEVM_STATUS_HALT) gas = 0;

    if (d == 0) {
      // Top-level message completes.
      if (is_create && status == FEVM_STATUS_SUCCESS) {
        finish_lane(status, err, gas, out, out_len);
      } else if (status == FEVM_STATUS_HALT) {
        finish_lane(status, err, 0, nullptr, 0);
      } else {
        finish_lane(status, err, gas, out, out_len);
      }
      return;
    }

    // The child frame header lives at the parent's stack top: read it before pushing.
    const Address child_addr = f->address;
    const uint64_t ret_off = f->ret_off, ret_len = f->ret_len;
    Frame* p = frame(d - 1);
    StackView pst = stack_of(p);
    p->gas += gas;
    if (is_create) {
      pst[p->sp++] = status == FEVM_STATUS_SUCCESS ? addr_to_u256(child_addr) : u256::zero();
    } else {
      pst[p->sp++] = status == FEVM_STATUS_SUCCESS ? u256::from_u64(1) : u256::zero();
      if (status != FEVM_STATUS_HALT && ret_len && out_len) {
        uint64_t n = min_u64(out_len, ret_len);
        mem_move(arena + p->mem_off + ret_off, out, n);
      }
    }
    hdr->depth = d - 1;
    bool keep = (status == FEVM_STATUS_REVERT) || (!is_create && status == FEVM_STATUS_SUCCESS);
    if (!set_returndata(d - 1, out, keep ? out_len : 0)) return fallback(fatal);
  }

  // ---------------------------------------------------------------- main loop

  FEVM_HD int run() {
    if (ctl->status == LANE_INIT) {
      init_lane();
      if (fatal) {
        fallback(fatal);
        return RUN_DONE;
      }
      ctl->status = LANE_RUNNING;
    }
    if (ctl->status == LANE_SUSPENDED) ctl->status = LANE_RUNNING;  // resumed after a host round
    ctl->req_kind = REQ_NONE;
    if (hdr->phase == 0) {
      int r = start_message();
      if (r == RUN_SUSPEND) {
        ctl->status = LANE_SUSPENDED;
        return RUN_SUSPEND;
      }
      if (fatal && hdr->phase != 2) {
        fallback(fatal);
        return RUN_DONE;
      }
    }
    while (hdr->phase == 1) {
      int r = exec();
      if (r == RUN_SUSPEND) {
        ctl->status = LANE_SUSPENDED;
        return RUN_SUSPEND;
      }
      if (fatal && hdr->phase != 2) {
        fallback(fatal);
        return RUN_DONE;
      }
    }
    return RUN_DONE;
  }

  // Executes the current frame until it ends, calls into a child, or suspends.
  FEVM_HDN int exec();
};

// ------------------------------------------------------------------ opcode loop

#define FEVM_SAVE()     \
  do {                  \
    f->pc = pc;         \
    f->gas = gas;       \
    f->sp = sp;         \
  } while (0)

#define FEVM_HALT(e)  \
  do {                \
    herr = (e);       \
    goto halt;        \
  } while (0)

#define FEVM_NEED(nin, nout)                                         \
  do {                                                               \
    if (sp < (nin)) FEVM_HALT(FEVM_ERR_STACK_UNDERFLOW);             \
    if (sp - (nin) + (nout) > STACK_LIMIT) FEVM_HALT(FEVM_ERR_STACK_OVERFLOW); \
  } while (0)

#define FEVM_GAS(c)                                                  \
  do {                                                               \
    uint64_t _c = (uint64_t)(c);                                     \
    if ((uint64_t)gas < _c) FEVM_HALT(FEVM_ERR_OUT_OF_GAS);          \
    gas -= (int64_t)_c;                                              \
  } while (0)

#define FEVM_SUSPEND()      \
  do {                      \
    pc = pc0;               \
    gas = gas0;             \
    sp = sp0;               \
    f->mem_size = mem0;     \
    FEVM_SAVE();            \
    return RUN_SUSPEND;     \
  } while (0)

#define FEVM_LOOKUP(expr)                         \
  do {                                            \
    int _r = (expr);                              \
    if (_r == LK_MISS) FEVM_SUSPEND();            \
    if (_r != LK_OK) goto fatal_exit;             \
  } while (0)

#define FEVM_CHECK(expr)          \
  do {                            \
    if (!(expr)) goto fatal_exit; \
  } while (0)

#define FEVM_MEM(endv)                                  \
  do {                                                  \
    int _m = mem_grow(f, &gas, (endv));                 \
    if (_m == 1) FEVM_HALT(FEVM_ERR_OUT_OF_GAS);        \
    if (_m == 2) goto fatal_exit;                       \
  } while (0)

#define FEVM_MEMRANGE(off, len, endvar)                               \
  do {                                                                \
    if (!mem_end((off), (len), &(endvar))) FEVM_HALT(FEVM_ERR_OUT_OF_GAS); \
  } while (0)

FEVM_HDN int Interp::exec() {
  Frame* f = frame(hdr->depth);
  const uint8_t* code = ptr(f->code_loc);
  const uint8_t* jd = ptr(f->jd_loc);
  const uint32_t code_len = f->code_len;
  const StackView st = stack_of(f);
  uint32_t pc = f->pc;
  int64_t gas = f->gas;
  uint32_t sp = f->sp;
  uint32_t herr = 0;
  const uint32_t fork = blk->fork;
  uint64_t steps = 0;

  // Opcode-start snapshot for restartable suspension.
  uint32_t pc0 = pc, sp0 = sp;
  int64_t gas0 = gas;
  uint64_t mem0 = f->mem_size;

  for (;;) {
    pc0 = pc;
    sp0 = sp;
    gas0 = gas;
    mem0 = f->mem_size;
    uint8_t op = pc < code_len ? code[pc] : 0x00;
    steps++;
    switch (op) {
      case 0x00:  // STOP
        FEVM_SAVE();
        hdr->steps += steps;
        end_frame(FEVM_STATUS_SUCCESS, FEVM_ERR_NONE, gas, nullptr, 0);
        return RUN_DONE;

      // ------------------------------------------------ arithmetic
      case 0x01: FEVM_NEED(2, 1); FEVM_GAS(3); st[sp - 2] = add(st[sp - 1], st[sp - 2]); sp--; pc++; break;
      case 0x02: FEVM_NEED(2, 1); FEVM_GAS(5); st[sp - 2] = mul(st[sp - 1], st[sp - 2]); sp--; pc++; break;
      case 0x03: FEVM_NEED(2, 1); FEVM_GAS(3); st[sp - 2] = sub(st[sp - 1], st[sp - 2]); sp--; pc++; break;
      case 0x04: FEVM_NEED(2, 1); FEVM_GAS(5); st[sp - 2] = udiv(st[sp - 1], st[sp - 2]); sp--; pc++; break;
      case 0x05: FEVM_NEED(2, 1); FEVM_GAS(5); st[sp - 2] = sdiv(st[sp - 1], st[sp - 2]); sp--; pc++; break;
      case 0x06: FEVM_NEED(2, 1); FEVM_GAS(5); st[sp - 2] = umod(st[sp - 1], st[sp - 2]); sp--; pc++; break;
      case 0x07: FEVM_NEED(2, 1); FEVM_GAS(5); st[sp - 2] = smod(st[sp - 1], st[sp - 2]); sp--; pc++; break;
      case 0x08:
        FEVM_NEED(3, 1); FEVM_GAS(8);
        st[sp - 3] = addmod(st[sp - 1], st[sp - 2], st[sp - 3]); sp -= 2; pc++; break;
      case 0x09:
        FEVM_NEED(3, 1); FEVM_GAS(8);
        st[sp - 3] = mulmod(st[sp - 1], st[sp - 2], st[sp - 3]); sp -= 2; pc++; break;
      case 0x0a: {  // EXP
        FEVM_NEED(2, 1);
        FEVM_GAS(10 + 50 * (uint64_t)st[sp - 2].byte_len());
        st[sp - 2] = exp(st[sp - 1], st[sp - 2]);
        sp--; pc++; break;
      }
      case 0x0b: FEVM_NEED(2, 1); FEVM_GAS(5); st[sp - 2] = signextend(st[sp - 1], st[sp - 2]); sp--; pc++; break;

      // ------------------------------------------------ comparison & bitwise
      case 0x10: FEVM_NEED(2, 1); FEVM_GAS(3); st[sp - 2] = u256::from_u64(lt(st[sp - 1], st[sp - 2])); sp--; pc++; break;
      case 0x11: FEVM_NEED(2, 1); FEVM_GAS(3); st[sp - 2] = u256::from_u64(lt(st[sp - 2], st[sp - 1])); sp--; pc++; break;
      case 0x12: FEVM_NEED(2, 1); FEVM_GAS(3); st[sp - 2] = u256::from_u64(slt(st[sp - 1], st[sp - 2])); sp--; pc++; break;
      case 0x13: FEVM_NEED(2, 1); FEVM_GAS(3); st[sp - 2] = u256::from_u64(slt(st[sp - 2], st[sp - 1])); sp--; pc++; break;
      case 0x14: FEVM_NEED(2, 1); FEVM_GAS(3); st[sp - 2] = u256::from_u64(st[sp - 1] == st[sp - 2]); sp--; pc++; break;
      case 0x15: FEVM_NEED(1, 1); FEVM_GAS(3); st[sp - 1] = u256::from_u64(st[sp - 1].is_zero()); pc++; break;
      case 0x16: FEVM_NEED(2, 1); FEVM_GAS(3); st[sp - 2] = bit_and(st[sp - 1], st[sp - 2]); sp--; pc++; break;
      case 0x17: FEVM_NEED(2, 1); FEVM_GAS(3); st[sp - 2] = bit_or(st[sp - 1], st[sp - 2]); sp--; pc++; break;
      case 0x18: FEVM_NEED(2, 1); FEVM_GAS(3); st[sp - 2] = bit_xor(st[sp - 1], st[sp - 2]); sp--; pc++; break;
      case 0x19: FEVM_NEED(1, 1); FEVM_GAS(3); st[sp - 1] = bit_not(st[sp - 1]); pc++; break;
      case 0x1a: FEVM_NEED(2, 1); FEVM_GAS(3); st[sp - 2] = byte_op(st[sp - 1], st[sp - 2]); sp--; pc++; break;
      case 0x1b: {
        FEVM_NEED(2, 1); FEVM_GAS(3);
        const u256& s = st[sp - 1];
        st[sp - 2] = s.fits_u64() && s.w[0] < 256 ? shl(st[sp - 2], (unsigned)s.w[0]) : u256::zero();
        sp--; pc++; break;
      }
      case 0x1c: {
        FEVM_NEED(2, 1); FEVM_GAS(3);
        const u256& s = st[sp - 1];
        st[sp - 2] = s.fits_u64() && s.w[0] < 256 ? shr(st[sp - 2], (unsigned)s.w[0]) : u256::zero();
        sp--; pc++; break;
      }
      case 0x1d: {
        FEVM_NEED(2, 1); FEVM_GAS(3);
        const u256& s = st[sp - 1];
        st[sp - 2] = sar(st[sp - 2], s.fits_u64() && s.w[0] < 256 ? (unsigned)s.w[0] : 256);
        sp--; pc++; break;
      }
      case 0x1e:  // CLZ (EIP-7939)
        if (fork < FORK_OSAKA) FEVM_HALT(FEVM_ERR_INVALID_OPCODE);
        FEVM_NEED(1, 1); FEVM_GAS(5);
        st[sp - 1] = clz256(st[sp - 1]);
        pc++; break;

      case 0x20: {  // KECCAK256
        FEVM_NEED(2, 1);
        FEVM_GAS(30);
        uint64_t end;
        FEVM_MEMRANGE(st[sp - 1], st[sp - 2], end);
        uint64_t len = st[sp - 2].w[0];
        FEVM_GAS(6 * ((len + 31) / 32));
        FEVM_MEM(end);
        uint8_t h[32];
        keccak256(len ? arena + f->mem_off + st[sp - 1].w[0] : nullptr, len, h);
        st[sp - 2] = u256::from_be(h);
        sp--; pc++; break;
      }

      // ------------------------------------------------ environment
      case 0x30: FEVM_NEED(0, 1); FEVM_GAS(2); st[sp++] = addr_to_u256(f->address); pc++; break;
      case 0x31: {  // BALANCE
        FEVM_NEED(1, 1);
        Acc* e;
        FEVM_LOOKUP(acc_get(addr_from_u256(st[sp - 1]), &e));
        FEVM_GAS(acc_warm(e) ? 100 : 2600);
        FEVM_CHECK(warm_acc(e));
        st[sp - 1] = e->balance;
        pc++; break;
      }
      case 0x32: FEVM_NEED(0, 1); FEVM_GAS(2); st[sp++] = addr_to_u256(msg->origin); pc++; break;
      case 0x33: FEVM_NEED(0, 1); FEVM_GAS(2); st[sp++] = addr_to_u256(f->caller); pc++; break;
      case 0x34: FEVM_NEED(0, 1); FEVM_GAS(2); st[sp++] = f->value; pc++; break;
      case 0x35: {  // CALLDATALOAD
        FEVM_NEED(1, 1); FEVM_GAS(3);
        uint8_t buf[32];
        copy_padded(buf, f->input_len ? ptr(f->input_loc) : nullptr, f->input_len, st[sp - 1], 32);
        st[sp - 1] = u256::from_be(buf);
        pc++; break;
      }
      case 0x36: FEVM_NEED(0, 1); FEVM_GAS(2); st[sp++] = u256::from_u64(f->input_len); pc++; break;
      case 0x37:    // CALLDATACOPY
      case 0x39:    // CODECOPY
      case 0x3e: {  // RETURNDATACOPY
        FEVM_NEED(3, 0);
        FEVM_GAS(3);
        const u256& moff = st[sp - 1];
        const u256& soff = st[sp - 2];
        const u256& len = st[sp - 3];
        uint64_t end;
        FEVM_MEMRANGE(moff, len, end);
        if (op == 0x3e) {
          // Bounds check against the return data buffer.
          bool carry;
          u256 e2 = add(soff, len, &carry);
          if (carry || !e2.fits_u64() || e2.w[0] > f->rd_len) FEVM_HALT(FEVM_ERR_RETURNDATA_OOB);
        }
        uint64_t l = len.w[0];
        FEVM_GAS(3 * ((l + 31) / 32));
        FEVM_MEM(end);
        if (l) {
          const uint8_t* src;
          uint64_t src_len;
          if (op == 0x37) {
            src = f->input_len ? ptr(f->input_loc) : nullptr;
            src_len = f->input_len;
          } else if (op == 0x39) {
            src = code;
            src_len = code_len;
          } else {
            src = arena + f->rd_off;
            src_len = f->rd_len;
          }
          copy_padded(arena + f->mem_off + moff.w[0], src, src_len, soff, l);
        }
        sp -= 3; pc++; break;
      }
      case 0x38: FEVM_NEED(0, 1); FEVM_GAS(2); st[sp++] = u256::from_u64(code_len); pc++; break;
      case 0x3a: FEVM_NEED(0, 1); FEVM_GAS(2); st[sp++] = msg->gas_price; pc++; break;
      case 0x3b:    // EXTCODESIZE
      case 0x3f: {  // EXTCODEHASH
        FEVM_NEED(1, 1);
        Acc* e;
        FEVM_LOOKUP(acc_get(addr_from_u256(st[sp - 1]), &e));
        FEVM_GAS(acc_warm(e) ? 100 : 2600);
        FEVM_CHECK(warm_acc(e));
        if (op == 0x3b)
          st[sp - 1] = u256::from_u64(e->code_len);
        else
          st[sp - 1] = acc_empty(e) ? u256::zero() : u256::from_be(e->code_hash);
        pc++; break;
      }
      case 0x3c: {  // EXTCODECOPY
        FEVM_NEED(4, 0);
        Acc* e;
        FEVM_LOOKUP(acc_get(addr_from_u256(st[sp - 1]), &e));
        FEVM_GAS(acc_warm(e) ? 100 : 2600);
        uint64_t end;
        FEVM_MEMRANGE(st[sp - 2], st[sp - 4], end);
        uint64_t l = st[sp - 4].w[0];
        FEVM_GAS(3 * ((l + 31) / 32));
        FEVM_MEM(end);
        FEVM_CHECK(warm_acc(e));
        if (l) copy_padded(arena + f->mem_off + st[sp - 2].w[0], e->code_len ? ptr(e->code_loc) : nullptr, e->code_len, st[sp - 3], l);
        sp -= 4; pc++; break;
      }
      case 0x3d: FEVM_NEED(0, 1); FEVM_GAS(2); st[sp++] = u256::from_u64(f->rd_len); pc++; break;

      // ------------------------------------------------ block
      case 0x40: {  // BLOCKHASH
        FEVM_NEED(1, 1);
        FEVM_GAS(20);
        const u256& n = st[sp - 1];
        u256 res = u256::zero();
        if (n.fits_u64() && n.w[0] < blk->number && n.w[0] + 256 >= blk->number) {
          const BaseBlockHash* bh = base->find_blockhash(n.w[0]);
          if (!bh) {
            ctl->req_kind = REQ_BLOCKHASH;
            ctl->req_number = n.w[0];
            FEVM_SUSPEND();
          }
          res = u256::from_be(bh->hash);
        }
        st[sp - 1] = res;
        pc++; break;
      }
      case 0x41: FEVM_NEED(0, 1); FEVM_GAS(2); st[sp++] = addr_to_u256(blk->coinbase); pc++; break;
      case 0x42: FEVM_NEED(0, 1); FEVM_GAS(2); st[sp++] = u256::from_u64(blk->timestamp); pc++; break;
      case 0x43: FEVM_NEED(0, 1); FEVM_GAS(2); st[sp++] = u256::from_u64(blk->number); pc++; break;
      case 0x44: FEVM_NEED(0, 1); FEVM_GAS(2); st[sp++] = blk->prev_randao; pc++; break;
      case 0x45: FEVM_NEED(0, 1); FEVM_GAS(2); st[sp++] = u256::from_u64(blk->gas_limit); pc++; break;
      case 0x46: FEVM_NEED(0, 1); FEVM_GAS(2); st[sp++] = blk->chain_id; pc++; break;
      case 0x47: {  // SELFBALANCE
        FEVM_NEED(0, 1);
        Acc* e;
        FEVM_LOOKUP(acc_get(f->address, &e));
        FEVM_GAS(5);
        st[sp++] = e->balance;
        pc++; break;
      }
      case 0x48: FEVM_NEED(0, 1); FEVM_GAS(2); st[sp++] = blk->base_fee; pc++; break;
      case 0x49: {  // BLOBHASH
        FEVM_NEED(1, 1); FEVM_GAS(3);
        const u256& i = st[sp - 1];
        if (i.fits_u64() && i.w[0] < msg->n_blob_hashes)
          st[sp - 1] = u256::from_be(ptr(msg->blob_hashes_loc) + i.w[0] * 32);
        else
          st[sp - 1] = u256::zero();
        pc++; break;
      }
      case 0x4a: FEVM_NEED(0, 1); FEVM_GAS(2); st[sp++] = blk->blob_base_fee; pc++; break;

      // ------------------------------------------------ stack, memory, storage, flow
      case 0x50: FEVM_NEED(1, 0); FEVM_GAS(2); sp--; pc++; break;
      case 0x51: {  // MLOAD
        FEVM_NEED(1, 1); FEVM_GAS(3);
        uint64_t end;
        FEVM_MEMRANGE(st[sp - 1], u256::from_u64(32), end);
        FEVM_MEM(end);
        st[sp - 1] = u256::from_be(arena + f->mem_off + st[sp - 1].w[0]);
        pc++; break;
      }
      case 0x52: {  // MSTORE
        FEVM_NEED(2, 0); FEVM_GAS(3);
        uint64_t end;
        FEVM_MEMRANGE(st[sp - 1], u256::from_u64(32), end);
        FEVM_MEM(end);
        st[sp - 2].to_be(arena + f->mem_off + st[sp - 1].w[0]);
        sp -= 2; pc++; break;
      }
      case 0x53: {  // MSTORE8
        FEVM_NEED(2, 0); FEVM_GAS(3);
        uint64_t end;
        FEVM_MEMRANGE(st[sp - 1], u256::from_u64(1), end);
        FEVM_MEM(end);
        arena[f->mem_off + st[sp - 1].w[0]] = (uint8_t)st[sp - 2].w[0];
        sp -= 2; pc++; break;
      }
      case 0x54: {  // SLOAD
        FEVM_NEED(1, 1);
        Slot* s;
        FEVM_LOOKUP(slot_get(f->address, st[sp - 1], &s));
        if (s->warm) {
          FEVM_GAS(100);
        } else {
          FEVM_GAS(2100);
          FEVM_CHECK(jpush(J_WARM_SLOT, (uint32_t)(s - slots), u256::zero(), 0));
          s->warm = 1;
        }
        st[sp - 1] = s->value;
        pc++; break;
      }
      case 0x55: {  // SSTORE
        if (f->is_static) FEVM_HALT(FEVM_ERR_STATIC_VIOLATION);
        FEVM_NEED(2, 0);
        if (gas <= 2300) FEVM_HALT(FEVM_ERR_OUT_OF_GAS);
        Slot* s;
        FEVM_LOOKUP(slot_get(f->address, st[sp - 1], &s));
        const u256& v = st[sp - 2];
        uint64_t cost = s->warm ? 0 : 2100;
        int64_t refund = 0;
        const u256& cur = s->value;
        const u256& orig = s->original;
        if (cur == v) {
          cost += 100;
        } else if (orig == cur) {
          if (orig.is_zero()) {
            cost += 20000;
          } else {
            if (v.is_zero()) refund += 4800;
            cost += 2900;
          }
        } else {
          if (!orig.is_zero()) {
            if (cur.is_zero())
              refund -= 4800;
            else if (v.is_zero())
              refund += 4800;
          }
          if (orig == v) refund += orig.is_zero() ? 19900 : 2800;
          cost += 100;
        }
        FEVM_GAS(cost);
        if (!s->warm) {
          FEVM_CHECK(jpush(J_WARM_SLOT, (uint32_t)(s - slots), u256::zero(), 0));
          s->warm = 1;
        }
        if (refund) FEVM_CHECK(add_refund(refund));
        if (cur != v) {
          FEVM_CHECK(jpush(J_STORAGE, (uint32_t)(s - slots), s->value, 0));
          s->value = v;
        }
        sp -= 2; pc++; break;
      }
      case 0x56: {  // JUMP
        FEVM_NEED(1, 0); FEVM_GAS(8);
        const u256& dst = st[sp - 1];
        if (!dst.fits_u64() || dst.w[0] >= code_len || !((jd[dst.w[0] >> 3] >> (dst.w[0] & 7)) & 1))
          FEVM_HALT(FEVM_ERR_BAD_JUMP);
        pc = (uint32_t)dst.w[0];
        sp--; break;
      }
      case 0x57: {  // JUMPI
        FEVM_NEED(2, 0); FEVM_GAS(10);
        if (!st[sp - 2].is_zero()) {
          const u256& dst = st[sp - 1];
          if (!dst.fits_u64() || dst.w[0] >= code_len || !((jd[dst.w[0] >> 3] >> (dst.w[0] & 7)) & 1))
            FEVM_HALT(FEVM_ERR_BAD_JUMP);
          pc = (uint32_t)dst.w[0];
        } else {
          pc++;
        }
        sp -= 2; break;
      }
      case 0x58: FEVM_NEED(0, 1); FEVM_GAS(2); st[sp++] = u256::from_u64(pc); pc++; break;
      case 0x59: FEVM_NEED(0, 1); FEVM_GAS(2); st[sp++] = u256::from_u64(f->mem_size); pc++; break;
      case 0x5a: FEVM_NEED(0, 1); FEVM_GAS(2); st[sp++] = u256::from_u64((uint64_t)gas); pc++; break;
      case 0x5b: FEVM_GAS(1); pc++; break;
      case 0x5c: {  // TLOAD
        FEVM_NEED(1, 1); FEVM_GAS(100);
        TSlot* t = tslot_find(f->address, st[sp - 1], false);
        st[sp - 1] = t ? t->value : u256::zero();
        pc++; break;
      }
      case 0x5d: {  // TSTORE
        if (f->is_static) FEVM_HALT(FEVM_ERR_STATIC_VIOLATION);
        FEVM_NEED(2, 0); FEVM_GAS(100);
        TSlot* t = tslot_find(f->address, st[sp - 1], true);
        FEVM_CHECK(t);
        if (t->value != st[sp - 2]) {
          FEVM_CHECK(jpush(J_TSTORE, (uint32_t)(t - tslots), t->value, 0));
          t->value = st[sp - 2];
        }
        sp -= 2; pc++; break;
      }
      case 0x5e: {  // MCOPY
        FEVM_NEED(3, 0); FEVM_GAS(3);
        uint64_t e1, e2;
        FEVM_MEMRANGE(st[sp - 1], st[sp - 3], e1);
        FEVM_MEMRANGE(st[sp - 2], st[sp - 3], e2);
        uint64_t l = st[sp - 3].w[0];
        FEVM_GAS(3 * ((l + 31) / 32));
        FEVM_MEM(max_u64(e1, e2));
        if (l) mem_move(arena + f->mem_off + st[sp - 1].w[0], arena + f->mem_off + st[sp - 2].w[0], l);
        sp -= 3; pc++; break;
      }
      case 0x5f: FEVM_NEED(0, 1); FEVM_GAS(2); st[sp++] = u256::zero(); pc++; break;

      // ------------------------------------------------ push / dup / swap
      case 0x60: case 0x61: case 0x62: case 0x63: case 0x64: case 0x65: case 0x66: case 0x67:
      case 0x68: case 0x69: case 0x6a: case 0x6b: case 0x6c: case 0x6d: case 0x6e: case 0x6f:
      case 0x70: case 0x71: case 0x72: case 0x73: case 0x74: case 0x75: case 0x76: case 0x77:
      case 0x78: case 0x79: case 0x7a: case 0x7b: case 0x7c: case 0x7d: case 0x7e: case 0x7f: {
        FEVM_NEED(0, 1); FEVM_GAS(3);
        uint32_t n = op - 0x5f;
        u256 v = u256::zero();
        for (uint32_t i = 0; i < n; i++) {
          uint32_t p = pc + 1 + i;
          uint8_t b = p < code_len ? code[p] : 0;
          uint32_t bit = (n - 1 - i) * 8;
          v.w[bit / 64] |= (uint64_t)b << (bit % 64);
        }
        st[sp++] = v;
        pc += n + 1;
        break;
      }
      case 0x80: case 0x81: case 0x82: case 0x83: case 0x84: case 0x85: case 0x86: case 0x87:
      case 0x88: case 0x89: case 0x8a: case 0x8b: case 0x8c: case 0x8d: case 0x8e: case 0x8f: {
        uint32_t n = op - 0x7f;
        FEVM_NEED(n, n + 1); FEVM_GAS(3);
        st[sp] = st[sp - n];
        sp++; pc++; break;
      }
      case 0x90: case 0x91: case 0x92: case 0x93: case 0x94: case 0x95: case 0x96: case 0x97:
      case 0x98: case 0x99: case 0x9a: case 0x9b: case 0x9c: case 0x9d: case 0x9e: case 0x9f: {
        uint32_t n = op - 0x8f;
        FEVM_NEED(n + 1, n + 1); FEVM_GAS(3);
        u256 t = st[sp - 1];
        st[sp - 1] = st[sp - 1 - n];
        st[sp - 1 - n] = t;
        pc++; break;
      }

      // ------------------------------------------------ logs
      case 0xa0: case 0xa1: case 0xa2: case 0xa3: case 0xa4: {
        uint32_t n = op - 0xa0;
        if (f->is_static) FEVM_HALT(FEVM_ERR_STATIC_VIOLATION);
        FEVM_NEED(2 + n, 0);
        uint64_t end;
        FEVM_MEMRANGE(st[sp - 1], st[sp - 2], end);
        uint64_t l = st[sp - 2].w[0];
        if (st[sp - 2].is_zero()) l = 0;
        FEVM_GAS(375 + 375 * (uint64_t)n);
        FEVM_GAS(8 * l);
        FEVM_MEM(end);
        u256 topics[4];
        for (uint32_t i = 0; i < n; i++) topics[i] = st[sp - 3 - i];
        FEVM_CHECK(add_log(f->address, topics, n, l ? arena + f->mem_off + st[sp - 1].w[0] : nullptr, l));
        sp -= 2 + n; pc++; break;
      }

      // ------------------------------------------------ system
      case 0xf0:    // CREATE
      case 0xf5: {  // CREATE2
        if (f->is_static) FEVM_HALT(FEVM_ERR_STATIC_VIOLATION);
        bool c2 = op == 0xf5;
        FEVM_NEED(c2 ? 4 : 3, 1);
        const u256 value = st[sp - 1];
        const u256 off = st[sp - 2];
        const u256 len = st[sp - 3];
        const u256 salt = c2 ? st[sp - 4] : u256::zero();
        FEVM_GAS(32000);
        uint64_t end;
        FEVM_MEMRANGE(off, len, end);
        if (!len.fits_u64() || len.w[0] > MAX_INITCODE_SIZE) FEVM_HALT(FEVM_ERR_INITCODE_SIZE);
        uint64_t l = len.w[0];
        if (len.is_zero()) l = 0;
        uint64_t words = (l + 31) / 32;
        FEVM_GAS(2 * words + (c2 ? 6 * words : 0));
        FEVM_MEM(end);
        const uint8_t* init = l ? arena + f->mem_off + off.w[0] : arena + f->mem_off;
        Acc* self;
        FEVM_LOOKUP(acc_get(f->address, &self));
        Address na = c2 ? create2_address(f->address, salt, init, l) : create_address(f->address, self->nonce);
        Acc* tgt;
        FEVM_LOOKUP(acc_get(na, &tgt));
        // Commit: forward all but 1/64.
        int64_t child = gas - gas / 64;
        gas -= child;
        sp -= c2 ? 4 : 3;
        uint32_t d = hdr->depth;
        if (d + 1 > MAX_DEPTH || lt(self->balance, value) || self->nonce + 1 < self->nonce) {
          gas += child;
          st[sp++] = u256::zero();
          pc++;
          FEVM_SAVE();
          FEVM_CHECK(set_returndata(d, nullptr, 0));
          break;
        }
        FEVM_CHECK(set_nonce(self, self->nonce + 1));
        FEVM_CHECK(warm_acc(tgt));
        if (tgt->nonce != 0 || tgt->code_len != 0) {
          st[sp++] = u256::zero();
          pc++;
          FEVM_SAVE();
          FEVM_CHECK(set_returndata(d, nullptr, 0));
          break;
        }
        uint32_t snap = hdr->n_journal;
        FEVM_CHECK(begin_create_account(self, tgt, value));
        Loc jdl = heap_alloc((l + 7) / 8 + 1);
        FEVM_CHECK(jdl != LOC_NONE);
        jumpdest_analysis(init, (uint32_t)l, ptr(jdl));
        pc++;
        FEVM_SAVE();
        hdr->steps += steps;
        Frame* c = push_frame();
        FEVM_CHECK(c);
        c->code_loc = (uint64_t)(init - arena) | LOC_ARENA;
        c->code_len = (uint32_t)l;
        c->jd_loc = jdl;
        c->gas = child;
        c->kind = c2 ? FK_CREATE2 : FK_CREATE;
        c->input_loc = LOC_NONE;
        c->input_len = 0;
        c->caller = f->address;
        c->address = na;
        c->code_address = na;
        c->value = value;
        c->journal_snap = snap;
        return RUN_DONE;
      }

      case 0xf1:    // CALL
      case 0xf2:    // CALLCODE
      case 0xf4:    // DELEGATECALL
      case 0xfa: {  // STATICCALL
        bool has_value = op == 0xf1 || op == 0xf2;
        uint32_t nin = has_value ? 7 : 6;
        FEVM_NEED(nin, 1);
        const u256 req_gas = st[sp - 1];
        const Address to = addr_from_u256(st[sp - 2]);
        const u256 value = has_value ? st[sp - 3] : (op == 0xf4 ? f->value : u256::zero());
        const u256 in_off = st[sp - nin + 3];
        const u256 in_len = st[sp - nin + 2];
        const u256 out_off = st[sp - nin + 1];
        const u256 out_len = st[sp - nin];
        bool transfers = has_value && !value.is_zero();
        if (op == 0xf1 && transfers && f->is_static) FEVM_HALT(FEVM_ERR_STATIC_VIOLATION);
        FEVM_GAS(100);
        // Lookups.
        Acc* tgt;
        FEVM_LOOKUP(acc_get(to, &tgt));
        Acc* del = nullptr;
        if (is_delegation(tgt)) FEVM_LOOKUP(acc_get(delegation_target(tgt), &del));
        Acc* self;
        FEVM_LOOKUP(acc_get(f->address, &self));
        // Gas.
        uint64_t e1, e2;
        FEVM_MEMRANGE(in_off, in_len, e1);
        FEVM_MEMRANGE(out_off, out_len, e2);
        uint64_t cost = 0;
        if (!acc_warm(tgt)) cost += 2500;
        if (transfers) {
          cost += 9000;
          if (op == 0xf1 && acc_empty(tgt)) cost += 25000;
        }
        FEVM_GAS(cost);
        FEVM_MEM(max_u64(e1, e2));
        // The target is warmed before the delegate is checked (it may delegate to itself).
        if (del) FEVM_GAS((acc_warm(del) || del == tgt) ? 100 : 2600);
        uint64_t avail = (uint64_t)gas - (uint64_t)gas / 64;
        uint64_t child = (req_gas.fits_u64() && req_gas.w[0] < avail) ? req_gas.w[0] : avail;
        uint64_t il = in_len.is_zero() ? 0 : in_len.w[0];
        uint64_t ol = out_len.is_zero() ? 0 : out_len.w[0];
        uint8_t* in_ptr = arena + f->mem_off + (il ? in_off.w[0] : 0);
        uint32_t d = hdr->depth;
        bool pre = is_precompile(fork, to);
        bool fail_pre = d + 1 > MAX_DEPTH || (transfers && lt(self->balance, value));
        // Host precompile request must happen before any mutation.
        bool p_ok = false;
        uint64_t p_gas = 0, p_olen = 0;
        const uint8_t* p_out = nullptr;
        uint8_t scratch[64];
        uint64_t child_total = child + (transfers ? 2300 : 0);
        if (pre && !fail_pre) {
          if (call_precompile(to, in_ptr, (uint64_t)(in_ptr - arena) | LOC_ARENA, il, child_total, pc, &p_ok, &p_gas,
                              &p_out, &p_olen, scratch))
            FEVM_SUSPEND();
          consume_precompile_response();
        }
        // Commit.
        FEVM_CHECK(warm_acc(tgt));
        if (del) FEVM_CHECK(warm_acc(del));
        gas -= (int64_t)child;
        sp -= nin;
        if (fail_pre) {
          gas += (int64_t)child_total;
          st[sp++] = u256::zero();
          pc++;
          FEVM_SAVE();
          FEVM_CHECK(set_returndata(d, nullptr, 0));
          break;
        }
        uint32_t snap = hdr->n_journal;
        if (op == 0xf1) {
          if (!tgt->exists && !pre && !transfers) {
            gas += (int64_t)child_total;
            st[sp++] = u256::from_u64(1);
            pc++;
            FEVM_SAVE();
            FEVM_CHECK(set_returndata(d, nullptr, 0));
            break;
          }
          FEVM_CHECK(mark_exists(tgt));
          FEVM_CHECK(transfer(self, tgt, value));
        } else if (op == 0xfa) {
          FEVM_CHECK(touch(tgt));
        }
        if (pre) {
          if (!p_ok) {
            revert_to(snap);
            st[sp++] = u256::zero();
            pc++;
            FEVM_SAVE();
            FEVM_CHECK(set_returndata(d, nullptr, 0));
            break;
          }
          gas += (int64_t)p_gas;
          st[sp++] = u256::from_u64(1);
          pc++;
          FEVM_SAVE();
          // Capture return data first: the output may alias memory (identity).
          FEVM_CHECK(set_returndata(d, p_out, p_olen));
          if (ol && p_olen) mem_move(arena + f->mem_off + out_off.w[0], arena + f->rd_off, min_u64(ol, p_olen));
          break;
        }
        Acc* code_acc = del ? del : tgt;
        if (code_acc->code_len == 0) {
          gas += (int64_t)child_total;
          st[sp++] = u256::from_u64(1);
          pc++;
          FEVM_SAVE();
          FEVM_CHECK(set_returndata(d, nullptr, 0));
          break;
        }
        Loc jdl = ensure_jd(code_acc);
        FEVM_CHECK(jdl != LOC_NONE);
        pc++;
        FEVM_SAVE();
        hdr->steps += steps;
        Frame* c = push_frame();
        FEVM_CHECK(c);
        c->code_loc = code_acc->code_loc;
        c->code_len = code_acc->code_len;
        c->jd_loc = jdl;
        c->gas = (int64_t)child_total;
        c->input_loc = (uint64_t)(in_ptr - arena) | LOC_ARENA;
        c->input_len = il;
        c->ret_off = ol ? out_off.w[0] : 0;
        c->ret_len = ol;
        c->journal_snap = snap;
        c->is_static = f->is_static || op == 0xfa;
        c->code_address = to;
        switch (op) {
          case 0xf1:
            c->kind = FK_CALL;
            c->caller = f->address;
            c->address = to;
            c->value = value;
            break;
          case 0xf2:
            c->kind = FK_CALLCODE;
            c->caller = f->address;
            c->address = f->address;
            c->value = value;
            break;
          case 0xf4:
            c->kind = FK_DELEGATECALL;
            c->caller = f->caller;
            c->address = f->address;
            c->value = f->value;
            break;
          default:
            c->kind = FK_STATICCALL;
            c->caller = f->address;
            c->address = to;
            c->value = u256::zero();
            break;
        }
        return RUN_DONE;
      }

      case 0xf3:    // RETURN
      case 0xfd: {  // REVERT
        FEVM_NEED(2, 0);
        uint64_t end;
        FEVM_MEMRANGE(st[sp - 1], st[sp - 2], end);
        FEVM_MEM(end);
        uint64_t l = st[sp - 2].is_zero() ? 0 : st[sp - 2].w[0];
        const uint8_t* out = l ? arena + f->mem_off + st[sp - 1].w[0] : nullptr;
        sp -= 2;
        FEVM_SAVE();
        hdr->steps += steps;
        end_frame(op == 0xf3 ? FEVM_STATUS_SUCCESS : FEVM_STATUS_REVERT, op == 0xf3 ? FEVM_ERR_NONE : FEVM_ERR_NONE,
                  gas, out, l);
        return RUN_DONE;
      }

      case 0xff: {  // SELFDESTRUCT (EIP-6780)
        if (f->is_static) FEVM_HALT(FEVM_ERR_STATIC_VIOLATION);
        FEVM_NEED(1, 0);
        FEVM_GAS(5000);
        Acc* ben;
        FEVM_LOOKUP(acc_get(addr_from_u256(st[sp - 1]), &ben));
        Acc* self;
        FEVM_LOOKUP(acc_get(f->address, &self));
        uint64_t cost = acc_warm(ben) ? 0 : 2600;
        if (acc_empty(ben) && !self->balance.is_zero()) cost += 25000;
        FEVM_GAS(cost);
        FEVM_CHECK(warm_acc(ben));
        u256 bal = self->balance;
        bool same = addr_eq(ben->addr, self->addr);
        if (self->created) {
          if (!same) {
            FEVM_CHECK(add_balance(ben, bal));
            FEVM_CHECK(sub_balance(self, bal));
          } else {
            FEVM_CHECK(sub_balance(self, bal));
          }
          if (!self->destructed) {
            FEVM_CHECK(jpush(J_DESTRUCT, aidx(self), u256::zero(), 0));
            self->destructed = 1;
          }
        } else if (!same) {
          FEVM_CHECK(sub_balance(self, bal));
          FEVM_CHECK(add_balance(ben, bal));
        }
        sp--;
        FEVM_SAVE();
        hdr->steps += steps;
        end_frame(FEVM_STATUS_SUCCESS, FEVM_ERR_NONE, gas, nullptr, 0);
        return RUN_DONE;
      }

      default:
        FEVM_HALT(FEVM_ERR_INVALID_OPCODE);
    }
  }

halt:
  FEVM_SAVE();
  hdr->steps += steps;
  end_frame(FEVM_STATUS_HALT, herr, 0, nullptr, 0);
  return RUN_DONE;

fatal_exit:
  FEVM_SAVE();
  hdr->steps += steps;
  if (!fatal) fatal = FEVM_ERR_RESOURCES;
  return RUN_DONE;
}

#undef FEVM_SAVE
#undef FEVM_HALT
#undef FEVM_NEED
#undef FEVM_GAS
#undef FEVM_SUSPEND
#undef FEVM_LOOKUP
#undef FEVM_CHECK
#undef FEVM_MEM
#undef FEVM_MEMRANGE

}  // namespace fevm
