// Core EVM data structures shared by the CPU and CUDA backends.
//
// Everything a lane touches lives either in the shared, read-only base state
// (per batch, filled by the host between rounds) or in the lane's own arena.
// References into either are stored as 64-bit "locations" (Loc) rather than
// pointers so the same layout works on host and device and can be copied back.
#pragma once

#include "../common/defs.cuh"
#include "../common/uint256.cuh"

namespace fevm {

// ------------------------------------------------------------------ constants

enum Fork : uint32_t { FORK_CANCUN = 0, FORK_PRAGUE = 1, FORK_OSAKA = 2 };

constexpr uint32_t MAX_DEPTH = 1024;
constexpr uint32_t STACK_LIMIT = 1024;
constexpr uint64_t MAX_CODE_SIZE = 24576;
constexpr uint64_t MAX_INITCODE_SIZE = 2 * MAX_CODE_SIZE;
constexpr uint32_t NO_LANE = 0xffffffffu;

// Empty code hash keccak256("").
#define FEVM_EMPTY_CODE_HASH_BYTES                                                                 \
  {0xc5, 0xd2, 0x46, 0x01, 0x86, 0xf7, 0x23, 0x3c, 0x92, 0x7e, 0x7d, 0xb2, 0xdc, 0xc7, 0x03, 0xc0, \
   0xe5, 0x00, 0xb6, 0x53, 0xca, 0x82, 0x27, 0x3b, 0x7b, 0xfa, 0xd8, 0x04, 0x5d, 0x85, 0xa4, 0x70}
#if defined(__CUDACC__)
__device__ __constant__ const uint8_t kEmptyCodeHashDev[32] = FEVM_EMPTY_CODE_HASH_BYTES;
#endif
static const uint8_t kEmptyCodeHashHost[32] = FEVM_EMPTY_CODE_HASH_BYTES;

FEVM_HD const uint8_t* empty_code_hash() {
#if FEVM_ON_DEVICE
  return kEmptyCodeHashDev;
#else
  return kEmptyCodeHashHost;
#endif
}

// ------------------------------------------------------------------ address

struct Address {
  uint8_t b[20];
};

FEVM_HD bool addr_eq(const Address& a, const Address& b) {
  const uint8_t* x = a.b;
  const uint8_t* y = b.b;
  uint32_t d = 0;
  for (int i = 0; i < 20; i++) d |= x[i] ^ y[i];
  return d == 0;
}

FEVM_HD uint64_t mix64(uint64_t x) {
  x ^= x >> 33;
  x *= 0xff51afd7ed558ccdull;
  x ^= x >> 33;
  x *= 0xc4ceb9fe1a85ec53ull;
  x ^= x >> 33;
  return x;
}

FEVM_HD uint64_t addr_hash(const Address& a) {
  uint64_t h = load_le64(a.b) ^ (load_le64(a.b + 8) * 0x9e3779b97f4a7c15ull) ^
               ((uint64_t)a.b[16] | (uint64_t)a.b[17] << 8 | (uint64_t)a.b[18] << 16 | (uint64_t)a.b[19] << 24) << 17;
  return mix64(h);
}

FEVM_HD uint64_t slot_hash(const Address& a, const u256& k) {
  return mix64(addr_hash(a) ^ mix64(k.w[0] ^ (k.w[1] * 31) ^ (k.w[2] * 131) ^ (k.w[3] * 1031)));
}

FEVM_HD Address addr_from_u256(const u256& v) {
  uint8_t tmp[32];
  v.to_be(tmp);
  Address a;
  for (int i = 0; i < 20; i++) a.b[i] = tmp[12 + i];
  return a;
}

FEVM_HD u256 addr_to_u256(const Address& a) { return u256::from_be_partial(a.b, 20); }

// Precompile address 0x00..00NN (NN up to 0xffff).
FEVM_HD uint32_t addr_low_index(const Address& a) {
  for (int i = 0; i < 18; i++)
    if (a.b[i]) return 0xffffffffu;
  return ((uint32_t)a.b[18] << 8) | a.b[19];
}

// ------------------------------------------------------------------ locations

// Bit 63 set: offset inside the lane arena. Bit 62 set: offset in the engine's
// code cache (persists across batches). Otherwise: offset in the batch blob pool.
typedef uint64_t Loc;
constexpr Loc LOC_ARENA = 1ull << 63;
constexpr Loc LOC_CODE = 1ull << 62;
constexpr Loc LOC_NONE = ~0ull;

// ------------------------------------------------------------------ base state
//
// The base tables belong to the engine's state cache and stay resident (on the
// device for the GPU backend) across batches. An entry is live only while its
// epoch equals the cache epoch; flushing the cache bumps the epoch, so stale
// entries read as empty slots and need no clearing or upload.

struct BaseAccount {
  Address addr;
  uint8_t used;
  uint8_t exists;
  uint8_t has_storage;
  uint8_t _pad;
  uint32_t warm_lane;  // lane for which the host reported this address warm
  uint32_t code_len;
  uint64_t nonce;
  u256 balance;
  uint8_t code_hash[32];
  Loc code_loc;
  Loc jd_loc;  // jumpdest bitmap
  uint32_t epoch;
  uint32_t warm_seq;  // batch in which warm_lane was reported
};

struct BaseSlot {
  Address addr;
  uint8_t used;
  uint8_t _pad[3];
  uint32_t warm_lane;
  uint32_t epoch;
  u256 key;
  u256 value;
  u256 original;
  uint32_t warm_seq;
  uint32_t _pad2;
};

struct BaseBlockHash {
  uint64_t number;
  uint32_t used;
  uint32_t epoch;
  uint8_t hash[32];
};

// Records the batch that last used a cache entry (LRU eviction). Every writer
// stores the same value, so the race between lanes is benign.
FEVM_HD void lru_touch(uint32_t* p, uint32_t v) {
#if FEVM_ON_DEVICE
  if (*p != v) *p = v;
#else
  if (__atomic_load_n(p, __ATOMIC_RELAXED) != v) __atomic_store_n(p, v, __ATOMIC_RELAXED);
#endif
}

struct BaseView {
  const BaseAccount* accounts;
  uint64_t acc_mask;
  const BaseSlot* slots;
  uint64_t slot_mask;
  const BaseBlockHash* bh;
  uint64_t bh_mask;
  const uint8_t* blob;  // batch blob (calldata, access lists, precompile outputs)
  const uint8_t* code;  // code cache (LOC_CODE)
  uint32_t* acc_lru;
  uint32_t* slot_lru;
  uint32_t epoch;
  uint32_t seq;  // current batch

  FEVM_HD const BaseAccount* find_account(const Address& a) const {
    uint64_t i = addr_hash(a) & acc_mask;
    for (;;) {
      const BaseAccount* e = &accounts[i];
      if (!e->used || e->epoch != epoch) return nullptr;
      if (addr_eq(e->addr, a)) {
        lru_touch(&acc_lru[i], seq);
        return e;
      }
      i = (i + 1) & acc_mask;
    }
  }
  FEVM_HD const BaseSlot* find_slot(const Address& a, const u256& k) const {
    uint64_t i = slot_hash(a, k) & slot_mask;
    for (;;) {
      const BaseSlot* e = &slots[i];
      if (!e->used || e->epoch != epoch) return nullptr;
      if (e->key == k && addr_eq(e->addr, a)) {
        lru_touch(&slot_lru[i], seq);
        return e;
      }
      i = (i + 1) & slot_mask;
    }
  }
  FEVM_HD const BaseBlockHash* find_blockhash(uint64_t n) const {
    uint64_t i = mix64(n) & bh_mask;
    for (;;) {
      const BaseBlockHash* e = &bh[i];
      if (!e->used || e->epoch != epoch) return nullptr;
      if (e->number == n) return e;
      i = (i + 1) & bh_mask;
    }
  }
};

// ------------------------------------------------------------------ batch inputs

struct Block {
  Address coinbase;
  uint32_t fork;
  uint64_t number;
  uint64_t timestamp;
  uint64_t gas_limit;
  u256 prev_randao;
  u256 base_fee;
  u256 blob_base_fee;
  u256 chain_id;
};

struct Msg {
  uint32_t kind;  // 0 call, 1 create
  uint32_t use_host_warm;
  Address sender;
  Address recipient;
  Address origin;
  uint64_t gas;
  u256 value;
  u256 gas_price;
  Loc input_loc;
  uint64_t input_len;
  Loc blob_hashes_loc;  // n * 32 bytes
  uint32_t n_blob_hashes;
  uint32_t n_warm_addrs;
  Loc warm_addrs_loc;  // n * 20 bytes
  Loc warm_slots_loc;  // n * (20 + 32) bytes
  uint32_t n_warm_slots;
  uint32_t nonce_preinc;  // CREATE: sender nonce already incremented by the client
  uint32_t frame_mode;    // run code_loc as a prepared top-level frame (see fevm_message)
  uint32_t frame_create;  // frame mode: CREATE body
  Loc code_loc;
  uint64_t code_len;
};

// ------------------------------------------------------------------ lane control (host visible)

enum LaneStatus : uint32_t { LANE_INIT = 0, LANE_RUNNING = 1, LANE_SUSPENDED = 2, LANE_DONE = 3 };

enum ReqKind : uint32_t { REQ_NONE = 0, REQ_ACCOUNT = 1, REQ_STORAGE = 2, REQ_BLOCKHASH = 3, REQ_PRECOMPILE = 4 };

struct LaneCtl {
  uint32_t status;
  uint32_t req_kind;
  Address req_addr;
  uint32_t req_depth;
  u256 req_key;
  uint64_t req_number;
  Loc req_input_loc;
  uint64_t req_input_len;
  uint64_t req_gas;
  uint32_t req_pc;
  // Precompile response written by the host.
  uint32_t resp_ready;
  uint32_t resp_status;
  uint32_t resp_depth;
  uint32_t resp_pc;
  uint32_t _pad;
  uint64_t resp_gas_left;
  Loc resp_out_loc;
  uint64_t resp_out_len;
  // Final outcome.
  uint32_t result_status;
  uint32_t result_error;
  uint64_t gas_left;
  int64_t refund;
  Loc out_loc;
  uint64_t out_len;
  Address created;
  uint32_t _pad2;
  uint64_t steps;
};

// What the host needs from a lane after a round: the request of a suspended
// lane or the outcome of a finished one. The GPU backend downloads these instead
// of whole LaneCtl records.
struct CtlEvent {
  uint32_t status;
  uint32_t req_kind;
  union {
    struct {
      Address addr;
      uint32_t depth;
      uint64_t key[4];  // u256 words
      uint64_t number;
      Loc input_loc;
      uint64_t input_len;
      uint64_t gas;
      uint32_t pc;
    } req;
    struct {
      uint32_t status;
      uint32_t error;
      uint64_t gas_left;
      int64_t refund;
      Loc out_loc;
      uint64_t out_len;
      Address created;
      uint64_t steps;
    } res;
  };
};

FEVM_HD void ctl_to_event(const LaneCtl& c, CtlEvent* e) {
  e->status = c.status;
  e->req_kind = c.req_kind;
  if (c.status == LANE_SUSPENDED) {
    e->req.addr = c.req_addr;
    e->req.depth = c.req_depth;
    for (int i = 0; i < 4; i++) e->req.key[i] = c.req_key.w[i];
    e->req.number = c.req_number;
    e->req.input_loc = c.req_input_loc;
    e->req.input_len = c.req_input_len;
    e->req.gas = c.req_gas;
    e->req.pc = c.req_pc;
  } else {
    e->res.status = c.result_status;
    e->res.error = c.result_error;
    e->res.gas_left = c.gas_left;
    e->res.refund = c.refund;
    e->res.out_loc = c.out_loc;
    e->res.out_len = c.out_len;
    e->res.created = c.created;
    e->res.steps = c.steps;
  }
}

FEVM_HD void event_to_ctl(const CtlEvent& e, LaneCtl* c) {
  c->status = e.status;
  c->req_kind = e.req_kind;
  if (e.status == LANE_SUSPENDED) {
    c->req_addr = e.req.addr;
    c->req_depth = e.req.depth;
    for (int i = 0; i < 4; i++) c->req_key.w[i] = e.req.key[i];
    c->req_number = e.req.number;
    c->req_input_loc = e.req.input_loc;
    c->req_input_len = e.req.input_len;
    c->req_gas = e.req.gas;
    c->req_pc = e.req.pc;
  } else {
    c->result_status = e.res.status;
    c->result_error = e.res.error;
    c->gas_left = e.res.gas_left;
    c->refund = e.res.refund;
    c->out_loc = e.res.out_loc;
    c->out_len = e.res.out_len;
    c->created = e.res.created;
    c->steps = e.res.steps;
  }
}

// ------------------------------------------------------------------ lane arena structures

struct Acc {
  Address addr;
  uint8_t used;
  uint8_t loaded;
  uint8_t exists;
  uint8_t has_storage;
  uint8_t warm;
  uint8_t touched;
  uint8_t created;     // CreateContract in this message
  uint8_t destructed;  // EIP-6780 selfdestruct
  uint8_t code_set;    // code installed by this message
  uint8_t _pad[3];
  uint32_t code_len;
  uint64_t nonce;
  u256 balance;
  uint8_t code_hash[32];
  Loc code_loc;
  Loc jd_loc;
};

struct Slot {
  Address addr;
  uint8_t used;
  uint8_t loaded;
  uint8_t warm;
  uint8_t _pad;
  u256 key;
  u256 value;
  u256 original;
};

struct TSlot {
  Address addr;
  uint32_t used;
  u256 key;
  u256 value;
};

enum JKind : uint32_t {
  J_BALANCE = 1,
  J_NONCE,
  J_WARM_ACC,
  J_WARM_SLOT,
  J_TOUCH,
  J_EXISTS,
  J_CREATED,
  J_CODE,
  J_DESTRUCT,
  J_STORAGE,
  J_TSTORE,
  J_REFUND,
  J_LOG,
};

struct JEntry {
  uint32_t kind;
  uint32_t idx;
  uint64_t prev2;
  u256 prev;
};

struct LogRec {
  Address addr;
  uint32_t n_topics;
  u256 topics[4];
  Loc data_loc;
  uint64_t data_len;
};

enum FrameKind : uint8_t { FK_CALL = 0, FK_CALLCODE, FK_DELEGATECALL, FK_STATICCALL, FK_CREATE, FK_CREATE2 };

struct Frame {
  Loc code_loc;
  Loc jd_loc;
  uint32_t code_len;
  uint32_t pc;
  int64_t gas;
  uint64_t stack_base;  // index into stack region (u256 units)
  uint32_t sp;          // number of items
  uint8_t kind;
  uint8_t is_static;
  uint16_t _pad;
  uint64_t mem_off;  // arena offset
  uint64_t mem_size;
  uint64_t rd_off;  // arena offset of return data buffer
  uint64_t rd_len;
  Loc input_loc;
  uint64_t input_len;
  Address caller;
  Address address;  // storage / execution context
  Address code_address;
  uint32_t journal_snap;
  u256 value;
  uint64_t ret_off;  // where to write output in parent memory
  uint64_t ret_len;
  uint32_t log_snap;
  uint32_t _pad2;
};

// Per-lane fixed header at arena offset 0.
struct LaneHdr {
  uint32_t phase;  // 0 = top-level start pending, 1 = running frames, 2 = done
  uint32_t depth;  // index of the current frame
  uint32_t n_acc;
  uint32_t n_slot;
  uint32_t n_tslot;
  uint32_t n_journal;
  uint32_t n_logs;
  uint32_t _pad;
  int64_t refund;
  uint64_t heap_top;  // bump pointer (absolute arena offset)
  uint64_t steps;
  Address created;
};

// Arena layout shared by all lanes (computed by the host from the arena size).
struct LaneLayout {
  uint64_t arena_bytes;
  uint64_t acc_off;
  uint32_t acc_cap;  // power of two
  uint32_t slot_cap;
  uint64_t slot_off;
  uint64_t tslot_off;
  uint32_t tslot_cap;
  uint32_t journal_cap;
  uint64_t journal_off;
  uint64_t logs_off;
  uint32_t logs_cap;
  uint32_t _pad;
  uint64_t frames_off;  // Frame[frames_cap]
  uint32_t frames_cap;
  uint32_t _pad3;
  uint64_t stack_off;
  uint64_t stack_cap;  // u256 items
  uint64_t heap_off;
  uint64_t heap_end;
  uint64_t mem_off;  // start of memory / returndata region
  uint64_t mem_end;
  // Insertion-ordered indices of used table entries (iteration and cleanup).
  uint64_t acc_list_off;
  uint64_t slot_list_off;
  uint64_t tslot_list_off;
};

}  // namespace fevm
