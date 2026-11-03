//! Raw declarations for `include/fastevm.h` (ABI version 1). Layouts mirror the header.

#![allow(non_camel_case_types, missing_docs)]

use core::ffi::{c_char, c_int, c_void};

pub const FEVM_ABI_VERSION: u32 = 1;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct fevm_address {
    pub bytes: [u8; 20],
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct fevm_bytes32 {
    pub bytes: [u8; 32],
}

pub const FEVM_FORK_CANCUN: u32 = 0;
pub const FEVM_FORK_PRAGUE: u32 = 1;
pub const FEVM_FORK_OSAKA: u32 = 2;

pub const FEVM_BACKEND_CPU: u32 = 0;
pub const FEVM_BACKEND_GPU: u32 = 1;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct fevm_config {
    pub backend: u32,
    pub device: c_int,
    pub cpu_threads: u32,
    pub lane_arena_bytes: u64,
    pub max_rounds: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct fevm_block_ctx {
    pub coinbase: fevm_address,
    pub number: u64,
    pub timestamp: u64,
    pub gas_limit: u64,
    pub prev_randao: fevm_bytes32,
    pub base_fee: fevm_bytes32,
    pub blob_base_fee: fevm_bytes32,
    pub chain_id: fevm_bytes32,
    pub fork: u32,
}

pub const FEVM_MSG_CALL: u32 = 0;
pub const FEVM_MSG_CREATE: u32 = 1;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct fevm_access_entry {
    pub address: fevm_address,
    pub n_keys: u32,
    pub keys: *const fevm_bytes32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct fevm_message {
    pub kind: u32,
    pub sender: fevm_address,
    pub recipient: fevm_address,
    pub value: fevm_bytes32,
    pub gas: u64,
    pub input: *const u8,
    pub input_len: u64,
    pub origin: fevm_address,
    pub gas_price: fevm_bytes32,
    pub blob_hashes: *const fevm_bytes32,
    pub n_blob_hashes: u32,
    pub access_list: *const fevm_access_entry,
    pub n_access_list: u32,
    pub use_host_warm_flags: u32,
    pub sender_nonce_preincremented: u32,
    pub frame_mode: u32,
    pub frame_is_create: u32,
    pub code: *const u8,
    pub code_len: u64,
}

impl Default for fevm_message {
    fn default() -> Self {
        // SAFETY: all-zero is a valid fevm_message (null pointers, zero lengths).
        unsafe { core::mem::zeroed() }
    }
}

pub const FEVM_REQ_ACCOUNT: u32 = 0;
pub const FEVM_REQ_STORAGE: u32 = 1;
pub const FEVM_REQ_BLOCKHASH: u32 = 2;
pub const FEVM_REQ_PRECOMPILE: u32 = 3;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct fevm_request {
    pub kind: u32,
    pub lane: u32,
    pub address: fevm_address,
    pub key: fevm_bytes32,
    pub number: u64,
    pub input: *const u8,
    pub input_len: u64,
    pub gas: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct fevm_account_info {
    pub exists: u8,
    pub has_storage: u8,
    pub warm: u8,
    pub _pad: u8,
    pub nonce: u64,
    pub balance: fevm_bytes32,
    pub code_hash: fevm_bytes32,
}

#[repr(C)]
pub struct fevm_sink {
    _private: [u8; 0],
}

pub type fevm_fetch_fn =
    unsafe extern "C" fn(ctx: *mut c_void, sink: *mut fevm_sink, reqs: *const fevm_request, n: u32) -> c_int;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct fevm_host {
    pub ctx: *mut c_void,
    pub fetch: Option<fevm_fetch_fn>,
}

pub const FEVM_STATUS_SUCCESS: u32 = 0;
pub const FEVM_STATUS_REVERT: u32 = 1;
pub const FEVM_STATUS_HALT: u32 = 2;
pub const FEVM_STATUS_FAILURE: u32 = 3;
pub const FEVM_STATUS_FALLBACK: u32 = 4;

pub const FEVM_ERR_NONE: u32 = 0;
pub const FEVM_ERR_OUT_OF_GAS: u32 = 1;
pub const FEVM_ERR_INVALID_OPCODE: u32 = 2;
pub const FEVM_ERR_STACK_UNDERFLOW: u32 = 3;
pub const FEVM_ERR_STACK_OVERFLOW: u32 = 4;
pub const FEVM_ERR_BAD_JUMP: u32 = 5;
pub const FEVM_ERR_STATIC_VIOLATION: u32 = 6;
pub const FEVM_ERR_RETURNDATA_OOB: u32 = 7;
pub const FEVM_ERR_INSUFFICIENT_BALANCE: u32 = 8;
pub const FEVM_ERR_DEPTH: u32 = 9;
pub const FEVM_ERR_NONCE_OVERFLOW: u32 = 10;
pub const FEVM_ERR_CONTRACT_COLLISION: u32 = 11;
pub const FEVM_ERR_CODE_SIZE: u32 = 12;
pub const FEVM_ERR_INITCODE_SIZE: u32 = 13;
pub const FEVM_ERR_INVALID_CODE_PREFIX: u32 = 14;
pub const FEVM_ERR_PRECOMPILE: u32 = 15;
pub const FEVM_ERR_GAS_UINT_OVERFLOW: u32 = 16;
pub const FEVM_ERR_RESOURCES: u32 = 17;
pub const FEVM_ERR_HOST: u32 = 18;

pub const FEVM_ACC_BALANCE: u32 = 1 << 0;
pub const FEVM_ACC_NONCE: u32 = 1 << 1;
pub const FEVM_ACC_CODE: u32 = 1 << 2;
pub const FEVM_ACC_CREATED: u32 = 1 << 3;
pub const FEVM_ACC_DESTRUCTED: u32 = 1 << 4;
pub const FEVM_ACC_TOUCHED: u32 = 1 << 5;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct fevm_account_diff {
    pub address: fevm_address,
    pub flags: u32,
    pub nonce: u64,
    pub balance: fevm_bytes32,
    pub code_hash: fevm_bytes32,
    pub code: *const u8,
    pub code_len: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct fevm_slot_diff {
    pub address: fevm_address,
    pub key: fevm_bytes32,
    pub value: fevm_bytes32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct fevm_log {
    pub address: fevm_address,
    pub n_topics: u32,
    pub topics: [fevm_bytes32; 4],
    pub data: *const u8,
    pub data_len: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct fevm_result {
    pub status: u32,
    pub error: u32,
    pub gas_left: u64,
    pub refund: i64,
    pub output: *const u8,
    pub output_len: u64,
    pub created_address: fevm_address,
    pub n_accounts: u32,
    pub accounts: *const fevm_account_diff,
    pub n_slots: u32,
    pub slots: *const fevm_slot_diff,
    pub n_logs: u32,
    pub logs: *const fevm_log,
    pub steps: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct fevm_batch_stats {
    pub rounds: u32,
    pub requests: u64,
    pub exec_seconds: f64,
    pub host_seconds: f64,
    pub transfer_seconds: f64,
    pub total_seconds: f64,
    pub cpu_retried_lanes: u64,
}

#[repr(C)]
pub struct fevm_engine {
    _private: [u8; 0],
}

#[repr(C)]
pub struct fevm_batch {
    _private: [u8; 0],
}

unsafe extern "C" {
    pub fn fevm_abi_version() -> u32;
    pub fn fevm_engine_create(cfg: *const fevm_config, err: *mut *const c_char) -> *mut fevm_engine;
    pub fn fevm_engine_destroy(engine: *mut fevm_engine);
    pub fn fevm_gpu_available() -> c_int;
    pub fn fevm_batch_create(engine: *mut fevm_engine, block: *const fevm_block_ctx) -> *mut fevm_batch;
    pub fn fevm_batch_add(batch: *mut fevm_batch, msg: *const fevm_message) -> i64;
    pub fn fevm_batch_preload_account(
        batch: *mut fevm_batch,
        addr: *const fevm_address,
        info: *const fevm_account_info,
        code: *const u8,
        code_len: u64,
    );
    pub fn fevm_batch_preload_storage(
        batch: *mut fevm_batch,
        addr: *const fevm_address,
        key: *const fevm_bytes32,
        value: *const fevm_bytes32,
    );
    pub fn fevm_batch_execute(batch: *mut fevm_batch, host: *const fevm_host) -> c_int;
    pub fn fevm_batch_result(batch: *const fevm_batch, lane: u32) -> *const fevm_result;
    pub fn fevm_batch_stats_get(batch: *const fevm_batch, out: *mut fevm_batch_stats);
    pub fn fevm_batch_reset(batch: *mut fevm_batch);
    pub fn fevm_batch_destroy(batch: *mut fevm_batch);

    pub fn fevm_sink_account(
        sink: *mut fevm_sink,
        idx: u32,
        info: *const fevm_account_info,
        code: *const u8,
        code_len: u64,
    );
    pub fn fevm_sink_storage(
        sink: *mut fevm_sink,
        idx: u32,
        current: *const fevm_bytes32,
        original: *const fevm_bytes32,
        warm: u8,
    );
    pub fn fevm_sink_blockhash(sink: *mut fevm_sink, idx: u32, hash: *const fevm_bytes32);
    pub fn fevm_sink_precompile(
        sink: *mut fevm_sink,
        idx: u32,
        status: c_int,
        gas_left: u64,
        out: *const u8,
        out_len: u64,
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn abi_version_matches() {
        assert_eq!(unsafe { fevm_abi_version() }, FEVM_ABI_VERSION);
    }

    #[test]
    fn layouts_match_header() {
        // sizeof() from include/fastevm.h on x86_64 (gcc).
        assert_eq!(core::mem::size_of::<fevm_config>(), 32);
        assert_eq!(core::mem::size_of::<fevm_block_ctx>(), 184);
        assert_eq!(core::mem::size_of::<fevm_message>(), 224);
        assert_eq!(core::mem::size_of::<fevm_request>(), 96);
        assert_eq!(core::mem::size_of::<fevm_account_info>(), 80);
        assert_eq!(core::mem::size_of::<fevm_result>(), 112);
        assert_eq!(core::mem::size_of::<fevm_account_diff>(), 112);
        assert_eq!(core::mem::size_of::<fevm_log>(), 168);
        assert_eq!(core::mem::size_of::<fevm_batch_stats>(), 56);
    }
}
