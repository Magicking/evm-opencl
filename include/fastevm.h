/*
 * fastevm: batch EVM execution engine (CPU reference backend + CUDA backend).
 *
 * Execution model
 * ---------------
 * The engine executes *messages* (the work done by geth's EVM.Call/EVM.Create
 * or besu's MessageCallProcessor/ContractCreationProcessor at depth 0):
 * value transfer, code execution, nested calls/creates, precompiles, journaling.
 * Transaction-level rules (intrinsic gas, nonce/balance validation, gas purchase,
 * refund cap, fee payment, EIP-7702 authorization processing) stay in the client.
 *
 * Messages are grouped in a batch. All messages of a batch see the same
 * pre-state (INDEPENDENT mode) and run in parallel. State is pulled lazily from
 * the client through one batched callback per execution round: lanes that miss
 * state suspend, the engine collects every miss, calls fevm_host.fetch once,
 * and resumes the suspended lanes.
 *
 * All 256-bit values are 32-byte big-endian.
 */
#ifndef FASTEVM_H
#define FASTEVM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FEVM_ABI_VERSION 2

typedef struct { uint8_t bytes[20]; } fevm_address;
typedef struct { uint8_t bytes[32]; } fevm_bytes32;

typedef enum {
  FEVM_FORK_CANCUN = 0,
  FEVM_FORK_PRAGUE = 1,
  FEVM_FORK_OSAKA = 2,
} fevm_fork;

typedef enum {
  FEVM_BACKEND_CPU = 0,
  FEVM_BACKEND_GPU = 1,
} fevm_backend;

typedef struct {
  fevm_backend backend;
  int device;                 /* CUDA device ordinal (GPU backend) */
  uint32_t cpu_threads;       /* worker threads (CPU backend), 0 = hardware concurrency */
  uint64_t lane_arena_bytes;  /* per-lane scratch (frames, stacks, memory), 0 = default 4 MiB */
  uint32_t max_rounds;        /* state-fetch rounds before giving up, 0 = default 4096 */
  uint64_t state_cache_bytes; /* budget of the state cache kept across batches (device memory
                                 for the GPU backend), 0 = default 512 MiB */
} fevm_config;

typedef struct {
  fevm_address coinbase;
  uint64_t number;
  uint64_t timestamp;
  uint64_t gas_limit;
  fevm_bytes32 prev_randao;
  fevm_bytes32 base_fee;
  fevm_bytes32 blob_base_fee;
  fevm_bytes32 chain_id;
  fevm_fork fork;
} fevm_block_ctx;

typedef enum {
  FEVM_MSG_CALL = 0,
  FEVM_MSG_CREATE = 1,
} fevm_msg_kind;

typedef struct {
  fevm_address address;
  uint32_t n_keys;
  const fevm_bytes32* keys;
} fevm_access_entry;

typedef struct {
  uint32_t kind;              /* fevm_msg_kind */
  fevm_address sender;
  fevm_address recipient;     /* ignored for CREATE */
  fevm_bytes32 value;
  uint64_t gas;
  const uint8_t* input;       /* calldata or initcode, copied by fevm_batch_add */
  uint64_t input_len;
  fevm_address origin;
  fevm_bytes32 gas_price;
  const fevm_bytes32* blob_hashes;
  uint32_t n_blob_hashes;
  /* Addresses/slots warm before execution (EIP-2929/2930), in addition to
   * sender, recipient, coinbase and the fork's precompiles which the engine
   * always warms. */
  const fevm_access_entry* access_list;
  uint32_t n_access_list;
  /* When non-zero, warm flags returned by fevm_host.fetch are honoured for this
   * lane (useful when the client tracks the access list itself, e.g. batch of 1). */
  uint32_t use_host_warm_flags;
  /* CREATE only: the client already incremented the sender nonce (besu). The
   * address is derived from nonce-1 and the engine does not increment it again. */
  uint32_t sender_nonce_preincremented;
  /* Frame mode (kind must be FEVM_MSG_CALL): the client already prepared the
   * top-level frame (value transferred; for a CREATE body also nonce bump,
   * account creation and endowment), as evm2 does before running a frame. The
   * engine runs `code` in the context of `recipient` (caller = sender,
   * CALLVALUE = value) without transfer, account creation or code deposit, and
   * returns the frame output as is. `code` is the code to run: the recipient's
   * code, the EIP-7702 delegate's code, or the initcode of a CREATE body. */
  uint32_t frame_mode;
  /* Frame mode: the frame is a CREATE body. Calldata is empty and the
   * recipient counts as created in this transaction (EIP-6780); its CREATED
   * flag in the result diff is already applied by the client. */
  uint32_t frame_is_create;
  const uint8_t* code;
  uint64_t code_len;
} fevm_message;

/* ------------------------------------------------------------------ host callbacks */

typedef enum {
  FEVM_REQ_ACCOUNT = 0,     /* address -> fevm_sink_account */
  FEVM_REQ_STORAGE = 1,     /* address,key -> fevm_sink_storage */
  FEVM_REQ_BLOCKHASH = 2,   /* number -> fevm_sink_blockhash */
  FEVM_REQ_PRECOMPILE = 3,  /* address,input,gas -> fevm_sink_precompile */
} fevm_req_kind;

typedef struct {
  uint32_t kind;            /* fevm_req_kind */
  uint32_t lane;            /* index of the requesting message in the batch */
  fevm_address address;
  fevm_bytes32 key;
  uint64_t number;          /* BLOCKHASH */
  const uint8_t* input;     /* PRECOMPILE input */
  uint64_t input_len;
  uint64_t gas;             /* PRECOMPILE gas available */
} fevm_request;

typedef struct {
  uint8_t exists;           /* account object exists in state (geth Exist) */
  uint8_t has_storage;      /* storage root != empty root (EIP-7610 collision check) */
  uint8_t warm;             /* address already in access list (see use_host_warm_flags) */
  uint8_t _pad;
  uint64_t nonce;
  fevm_bytes32 balance;
  fevm_bytes32 code_hash;   /* keccak256(code), or empty-code hash */
} fevm_account_info;

typedef struct fevm_sink fevm_sink;

/* Responses: idx is the index of the request in the array passed to fetch.
 * Pointer arguments are copied before return. */
void fevm_sink_account(fevm_sink* sink, uint32_t idx, const fevm_account_info* info, const uint8_t* code,
                       uint64_t code_len);
void fevm_sink_storage(fevm_sink* sink, uint32_t idx, const fevm_bytes32* current, const fevm_bytes32* original,
                       uint8_t warm);
void fevm_sink_blockhash(fevm_sink* sink, uint32_t idx, const fevm_bytes32* hash);
/* status: 0 success, 1 failure (consumes all gas). gas_left meaningful on success. */
void fevm_sink_precompile(fevm_sink* sink, uint32_t idx, int status, uint64_t gas_left, const uint8_t* out,
                          uint64_t out_len);

typedef struct {
  void* ctx;
  /* Must answer every request through the sink before returning. Return non-zero
   * to abort the batch (all unfinished lanes end with FEVM_STATUS_FALLBACK). */
  int (*fetch)(void* ctx, fevm_sink* sink, const fevm_request* reqs, uint32_t n);
} fevm_host;

/* ------------------------------------------------------------------ results */

typedef enum {
  FEVM_STATUS_SUCCESS = 0,
  FEVM_STATUS_REVERT = 1,
  FEVM_STATUS_HALT = 2,      /* exceptional halt: all gas consumed, state reverted */
  FEVM_STATUS_FAILURE = 3,   /* pre-execution failure (depth, balance, nonce overflow): gas returned */
  FEVM_STATUS_FALLBACK = 4,  /* engine could not run the message: execute it natively */
} fevm_status;

typedef enum {
  FEVM_ERR_NONE = 0,
  FEVM_ERR_OUT_OF_GAS,
  FEVM_ERR_INVALID_OPCODE,
  FEVM_ERR_STACK_UNDERFLOW,
  FEVM_ERR_STACK_OVERFLOW,
  FEVM_ERR_BAD_JUMP,
  FEVM_ERR_STATIC_VIOLATION,
  FEVM_ERR_RETURNDATA_OOB,
  FEVM_ERR_INSUFFICIENT_BALANCE,
  FEVM_ERR_DEPTH,
  FEVM_ERR_NONCE_OVERFLOW,
  FEVM_ERR_CONTRACT_COLLISION,
  FEVM_ERR_CODE_SIZE,
  FEVM_ERR_INITCODE_SIZE,
  FEVM_ERR_INVALID_CODE_PREFIX,
  FEVM_ERR_PRECOMPILE,
  FEVM_ERR_GAS_UINT_OVERFLOW,
  FEVM_ERR_RESOURCES,        /* lane arena / journal exhausted (-> FALLBACK) */
  FEVM_ERR_HOST,             /* host callback aborted (-> FALLBACK) */
} fevm_error;

enum {
  FEVM_ACC_BALANCE = 1u << 0,
  FEVM_ACC_NONCE = 1u << 1,
  FEVM_ACC_CODE = 1u << 2,
  FEVM_ACC_CREATED = 1u << 3,    /* contract created by this message (CreateContract) */
  FEVM_ACC_DESTRUCTED = 1u << 4, /* EIP-6780 selfdestruct of a same-tx contract */
  FEVM_ACC_TOUCHED = 1u << 5,    /* touched (EIP-158 empty-account clearing candidate) */
};

typedef struct {
  fevm_address address;
  uint32_t flags;
  uint64_t nonce;
  fevm_bytes32 balance;
  fevm_bytes32 code_hash;
  const uint8_t* code;
  uint64_t code_len;
} fevm_account_diff;

typedef struct {
  fevm_address address;
  fevm_bytes32 key;
  fevm_bytes32 value;
} fevm_slot_diff;

typedef struct {
  fevm_address address;
  uint32_t n_topics;
  fevm_bytes32 topics[4];
  const uint8_t* data;
  uint64_t data_len;
} fevm_log;

typedef struct {
  uint32_t status;          /* fevm_status */
  uint32_t error;           /* fevm_error */
  uint64_t gas_left;
  int64_t refund;           /* refund counter delta (EIP-3529 SSTORE refunds) */
  const uint8_t* output;
  uint64_t output_len;
  fevm_address created_address;  /* CREATE messages */
  uint32_t n_accounts;
  const fevm_account_diff* accounts;
  uint32_t n_slots;
  const fevm_slot_diff* slots;
  uint32_t n_logs;
  const fevm_log* logs;
  uint64_t steps;           /* opcodes executed (statistics) */
} fevm_result;

typedef struct {
  uint32_t rounds;          /* execution rounds (1 + number of state-fetch rounds) */
  uint64_t requests;        /* host requests served */
  double exec_seconds;      /* time inside kernels / interpreter workers */
  double host_seconds;      /* time inside host callbacks */
  double transfer_seconds;  /* host<->device copies (GPU backend) */
  double total_seconds;
  uint64_t cpu_retried_lanes; /* lanes that exceeded GPU arena limits and re-ran on the CPU backend */
  uint64_t cache_account_fills; /* accounts the host supplied for this batch (misses in the cache) */
  uint64_t cache_slot_fills;    /* storage slots the host supplied for this batch */
  uint64_t cache_evictions;     /* LRU evictions of the engine's state cache so far */
  uint64_t cache_bytes;         /* size of the state cache after the batch */
} fevm_batch_stats;

/* ------------------------------------------------------------------ API */

typedef struct fevm_engine fevm_engine;
typedef struct fevm_batch fevm_batch;

uint32_t fevm_abi_version(void);
/* Returns NULL on failure; *err (optional) receives a static message. */
fevm_engine* fevm_engine_create(const fevm_config* cfg, const char** err);
void fevm_engine_destroy(fevm_engine* engine);
int fevm_gpu_available(void);

fevm_batch* fevm_batch_create(fevm_engine* engine, const fevm_block_ctx* block);
/* Returns lane index, or -1 on error. */
int64_t fevm_batch_add(fevm_batch* batch, const fevm_message* msg);
/* Same as fevm_batch_add but takes the input as separate arguments (msg->input
 * is ignored). Lets garbage-collected callers pass their own buffers. */
int64_t fevm_batch_add_input(fevm_batch* batch, const fevm_message* msg, const uint8_t* input, uint64_t input_len);
/* Optional state preload (avoids fetch rounds). Same semantics as sink responses. */
void fevm_batch_preload_account(fevm_batch* batch, const fevm_address* addr, const fevm_account_info* info,
                                const uint8_t* code, uint64_t code_len);
void fevm_batch_preload_storage(fevm_batch* batch, const fevm_address* addr, const fevm_bytes32* key,
                                const fevm_bytes32* value);
/* Runs every message. Returns 0 on success (individual messages may still fail). */
int fevm_batch_execute(fevm_batch* batch, const fevm_host* host);
const fevm_result* fevm_batch_result(const fevm_batch* batch, uint32_t lane);
/* Cheap accessors that avoid touching the diff arrays. */
uint32_t fevm_batch_result_status(const fevm_batch* batch, uint32_t lane);
uint64_t fevm_batch_result_gas_left(const fevm_batch* batch, uint32_t lane);
void fevm_batch_stats_get(const fevm_batch* batch, fevm_batch_stats* out);
/* Clears messages and results; the engine's state cache keeps the pre-state (reuse
 * for a new batch against the same state). */
void fevm_batch_reset(fevm_batch* batch);

/* State cache. The engine keeps code (by code hash), accounts, storage slots and
 * block hashes across batches, resident in device memory for the GPU backend,
 * and evicts the least recently used entries beyond fevm_config.state_cache_bytes.
 * Code is always reused. Accounts, slots and block hashes are reused only when
 * consecutive batches declare the same state id (any 32-byte name of the
 * pre-state, e.g. a block hash); a batch without one, or with a different one,
 * starts from an empty state cache. Within one id, storage `original` values are
 * reused as given, so an id names a transaction boundary.
 * Call before the batch's first preload or execute; returns 0, or -1 if too late. */
int fevm_batch_set_state_id(fevm_batch* batch, const fevm_bytes32* state_id);
/* After execute: declares that the client committed every lane's result in lane
 * order and nothing else changed, so the cache now holds state `new_state_id`.
 * Returns 0 when the cache followed the diffs, 1 when it had to drop accounts and
 * slots instead (fallback lanes, created or destroyed accounts), -1 on misuse. */
int fevm_batch_commit(fevm_batch* batch, const fevm_bytes32* new_state_id);
/* Drops everything, including code. */
void fevm_engine_cache_clear(fevm_engine* engine);
void fevm_batch_destroy(fevm_batch* batch);

/* ------------------------------------------------------------------ flat FFI API
 * Same functionality with primitive arguments only (addresses: 20 bytes,
 * words: 32 bytes big-endian), for JNA/FFM/ctypes bindings. */

fevm_engine* fevm_engine_create_flat(uint32_t backend, int32_t device, uint32_t cpu_threads, uint64_t lane_arena_bytes,
                                     uint32_t max_rounds);
fevm_batch* fevm_batch_create_flat(fevm_engine* engine, const uint8_t* coinbase, uint64_t number, uint64_t timestamp,
                                   uint64_t gas_limit, const uint8_t* prev_randao, const uint8_t* base_fee,
                                   const uint8_t* blob_base_fee, const uint8_t* chain_id, uint32_t fork);
int64_t fevm_batch_add_flat(fevm_batch* batch, uint32_t kind, const uint8_t* sender, const uint8_t* recipient,
                            const uint8_t* value, uint64_t gas, const uint8_t* input, uint64_t input_len,
                            const uint8_t* origin, const uint8_t* gas_price, const uint8_t* blob_hashes,
                            uint32_t n_blob_hashes, uint32_t use_host_warm_flags, uint32_t sender_nonce_preincremented);
/* Request accessors (reqs is the array handed to fevm_host.fetch). */
uint32_t fevm_request_kind(const fevm_request* reqs, uint32_t i);
uint32_t fevm_request_lane(const fevm_request* reqs, uint32_t i);
void fevm_request_address(const fevm_request* reqs, uint32_t i, uint8_t* out20);
void fevm_request_key(const fevm_request* reqs, uint32_t i, uint8_t* out32);
uint64_t fevm_request_number(const fevm_request* reqs, uint32_t i);
uint64_t fevm_request_gas(const fevm_request* reqs, uint32_t i);
uint64_t fevm_request_input_len(const fevm_request* reqs, uint32_t i);
void fevm_request_input(const fevm_request* reqs, uint32_t i, uint8_t* out);
void fevm_sink_account_flat(fevm_sink* sink, uint32_t idx, uint32_t exists, uint32_t has_storage, uint32_t warm,
                            uint64_t nonce, const uint8_t* balance, const uint8_t* code_hash, const uint8_t* code,
                            uint64_t code_len);
void fevm_sink_storage_flat(fevm_sink* sink, uint32_t idx, const uint8_t* current, const uint8_t* original,
                            uint32_t warm);
void fevm_sink_blockhash_flat(fevm_sink* sink, uint32_t idx, const uint8_t* hash);
/* Executes with a host given as a bare callback. */
int fevm_batch_execute_flat(fevm_batch* batch, void* ctx,
                            int (*fetch)(void* ctx, fevm_sink* sink, const fevm_request* reqs, uint32_t n));
/* Result accessors. counts: [n_accounts, n_slots, n_logs, output_len]. */
void fevm_result_summary(const fevm_batch* batch, uint32_t lane, uint32_t* status, uint32_t* error,
                         uint64_t* gas_left, int64_t* refund, uint8_t* created20, uint64_t* counts4);
void fevm_result_output(const fevm_batch* batch, uint32_t lane, uint8_t* out);
/* Returns code_len; copies code into code_out when non-NULL. */
uint64_t fevm_result_account(const fevm_batch* batch, uint32_t lane, uint32_t i, uint8_t* addr20, uint32_t* flags,
                             uint64_t* nonce, uint8_t* balance32, uint8_t* code_out);
void fevm_result_slot(const fevm_batch* batch, uint32_t lane, uint32_t i, uint8_t* addr20, uint8_t* key32,
                      uint8_t* value32);
/* Returns data_len; copies topics (n*32 bytes) and data when non-NULL. */
uint64_t fevm_result_log(const fevm_batch* batch, uint32_t lane, uint32_t i, uint8_t* addr20, uint32_t* n_topics,
                         uint8_t* topics128, uint8_t* data_out);

#ifdef __cplusplus
}
#endif

#endif /* FASTEVM_H */
