// Flat FFI API: thin wrappers over the struct-based API (see fastevm.h).
#include <cstring>

#include "fastevm.h"

static void cp20(fevm_address* d, const uint8_t* s) {
  if (s)
    memcpy(d->bytes, s, 20);
  else
    memset(d->bytes, 0, 20);
}
static void cp32(fevm_bytes32* d, const uint8_t* s) {
  if (s)
    memcpy(d->bytes, s, 32);
  else
    memset(d->bytes, 0, 32);
}

extern "C" {

fevm_engine* fevm_engine_create_flat(uint32_t backend, int32_t device, uint32_t cpu_threads, uint64_t lane_arena_bytes,
                                     uint32_t max_rounds) {
  fevm_config c{};
  c.backend = (fevm_backend)backend;
  c.device = device;
  c.cpu_threads = cpu_threads;
  c.lane_arena_bytes = lane_arena_bytes;
  c.max_rounds = max_rounds;
  return fevm_engine_create(&c, nullptr);
}

fevm_batch* fevm_batch_create_flat(fevm_engine* engine, const uint8_t* coinbase, uint64_t number, uint64_t timestamp,
                                   uint64_t gas_limit, const uint8_t* prev_randao, const uint8_t* base_fee,
                                   const uint8_t* blob_base_fee, const uint8_t* chain_id, uint32_t fork) {
  fevm_block_ctx b{};
  cp20(&b.coinbase, coinbase);
  b.number = number;
  b.timestamp = timestamp;
  b.gas_limit = gas_limit;
  cp32(&b.prev_randao, prev_randao);
  cp32(&b.base_fee, base_fee);
  cp32(&b.blob_base_fee, blob_base_fee);
  cp32(&b.chain_id, chain_id);
  b.fork = (fevm_fork)fork;
  return fevm_batch_create(engine, &b);
}

int64_t fevm_batch_add_flat(fevm_batch* batch, uint32_t kind, const uint8_t* sender, const uint8_t* recipient,
                            const uint8_t* value, uint64_t gas, const uint8_t* input, uint64_t input_len,
                            const uint8_t* origin, const uint8_t* gas_price, const uint8_t* blob_hashes,
                            uint32_t n_blob_hashes, uint32_t use_host_warm_flags, uint32_t sender_nonce_preincremented) {
  fevm_message m{};
  m.kind = kind;
  cp20(&m.sender, sender);
  cp20(&m.recipient, recipient);
  cp32(&m.value, value);
  m.gas = gas;
  cp20(&m.origin, origin);
  cp32(&m.gas_price, gas_price);
  m.blob_hashes = (const fevm_bytes32*)blob_hashes;
  m.n_blob_hashes = n_blob_hashes;
  m.use_host_warm_flags = use_host_warm_flags;
  m.sender_nonce_preincremented = sender_nonce_preincremented;
  return fevm_batch_add_input(batch, &m, input, input_len);
}

uint32_t fevm_request_kind(const fevm_request* r, uint32_t i) { return r[i].kind; }
uint32_t fevm_request_lane(const fevm_request* r, uint32_t i) { return r[i].lane; }
void fevm_request_address(const fevm_request* r, uint32_t i, uint8_t* out) { memcpy(out, r[i].address.bytes, 20); }
void fevm_request_key(const fevm_request* r, uint32_t i, uint8_t* out) { memcpy(out, r[i].key.bytes, 32); }
uint64_t fevm_request_number(const fevm_request* r, uint32_t i) { return r[i].number; }
uint64_t fevm_request_gas(const fevm_request* r, uint32_t i) { return r[i].gas; }
uint64_t fevm_request_input_len(const fevm_request* r, uint32_t i) { return r[i].input_len; }
void fevm_request_input(const fevm_request* r, uint32_t i, uint8_t* out) {
  if (r[i].input_len) memcpy(out, r[i].input, r[i].input_len);
}

void fevm_sink_account_flat(fevm_sink* sink, uint32_t idx, uint32_t exists, uint32_t has_storage, uint32_t warm,
                            uint64_t nonce, const uint8_t* balance, const uint8_t* code_hash, const uint8_t* code,
                            uint64_t code_len) {
  fevm_account_info info{};
  info.exists = exists ? 1 : 0;
  info.has_storage = has_storage ? 1 : 0;
  info.warm = warm ? 1 : 0;
  info.nonce = nonce;
  cp32(&info.balance, balance);
  cp32(&info.code_hash, code_hash);
  fevm_sink_account(sink, idx, &info, code, code_len);
}

void fevm_sink_storage_flat(fevm_sink* sink, uint32_t idx, const uint8_t* current, const uint8_t* original,
                            uint32_t warm) {
  fevm_bytes32 c, o;
  cp32(&c, current);
  cp32(&o, original ? original : current);
  fevm_sink_storage(sink, idx, &c, &o, warm ? 1 : 0);
}

void fevm_sink_blockhash_flat(fevm_sink* sink, uint32_t idx, const uint8_t* hash) {
  fevm_bytes32 h;
  cp32(&h, hash);
  fevm_sink_blockhash(sink, idx, &h);
}

int fevm_batch_execute_flat(fevm_batch* batch, void* ctx,
                            int (*fetch)(void* ctx, fevm_sink* sink, const fevm_request* reqs, uint32_t n)) {
  fevm_host h{ctx, fetch};
  return fevm_batch_execute(batch, &h);
}

void fevm_result_summary(const fevm_batch* batch, uint32_t lane, uint32_t* status, uint32_t* error,
                         uint64_t* gas_left, int64_t* refund, uint8_t* created20, uint64_t* counts4) {
  const fevm_result* r = fevm_batch_result(batch, lane);
  if (!r) {
    *status = FEVM_STATUS_FALLBACK;
    return;
  }
  *status = r->status;
  *error = r->error;
  *gas_left = r->gas_left;
  *refund = r->refund;
  memcpy(created20, r->created_address.bytes, 20);
  counts4[0] = r->n_accounts;
  counts4[1] = r->n_slots;
  counts4[2] = r->n_logs;
  counts4[3] = r->output_len;
}

void fevm_result_output(const fevm_batch* batch, uint32_t lane, uint8_t* out) {
  const fevm_result* r = fevm_batch_result(batch, lane);
  if (r && r->output_len) memcpy(out, r->output, r->output_len);
}

uint64_t fevm_result_account(const fevm_batch* batch, uint32_t lane, uint32_t i, uint8_t* addr20, uint32_t* flags,
                             uint64_t* nonce, uint8_t* balance32, uint8_t* code_out) {
  const fevm_account_diff& d = fevm_batch_result(batch, lane)->accounts[i];
  memcpy(addr20, d.address.bytes, 20);
  *flags = d.flags;
  *nonce = d.nonce;
  memcpy(balance32, d.balance.bytes, 32);
  if (code_out && d.code_len) memcpy(code_out, d.code, d.code_len);
  return d.code_len;
}

void fevm_result_slot(const fevm_batch* batch, uint32_t lane, uint32_t i, uint8_t* addr20, uint8_t* key32,
                      uint8_t* value32) {
  const fevm_slot_diff& d = fevm_batch_result(batch, lane)->slots[i];
  memcpy(addr20, d.address.bytes, 20);
  memcpy(key32, d.key.bytes, 32);
  memcpy(value32, d.value.bytes, 32);
}

uint64_t fevm_result_log(const fevm_batch* batch, uint32_t lane, uint32_t i, uint8_t* addr20, uint32_t* n_topics,
                         uint8_t* topics128, uint8_t* data_out) {
  const fevm_log& l = fevm_batch_result(batch, lane)->logs[i];
  memcpy(addr20, l.address.bytes, 20);
  *n_topics = l.n_topics;
  if (topics128) memcpy(topics128, l.topics, 32 * l.n_topics);
  if (data_out && l.data_len) memcpy(data_out, l.data, l.data_len);
  return l.data_len;
}

}  // extern "C"
