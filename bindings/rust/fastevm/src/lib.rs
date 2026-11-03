//! Rust binding for libfastevm (`include/fastevm.h`).
//!
//! * [`sys`]: raw C ABI.
//! * [`Engine`]: owned engine handle (one per thread; the C engine is not thread-safe).
//! * [`runner`] (feature `evm2`): an evm2 `InterpreterRunner` that executes top-level frames on
//!   fastevm, used by reth (see `integrations/reth.patch`).

pub mod sys;

#[cfg(feature = "evm2")]
pub mod runner;

use core::ffi::CStr;

/// Execution backend.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Backend {
    /// CPU reference backend.
    Cpu,
    /// CUDA backend.
    Gpu,
}

impl Backend {
    /// Reads `FASTEVM_BACKEND` (`cpu` | `gpu`); `None` when unset or anything else.
    pub fn from_env() -> Option<Self> {
        match std::env::var("FASTEVM_BACKEND").ok()?.as_str() {
            "cpu" => Some(Self::Cpu),
            "gpu" => Some(Self::Gpu),
            _ => None,
        }
    }
}

/// Owned `fevm_engine`.
#[derive(Debug)]
pub struct Engine {
    raw: *mut sys::fevm_engine,
}

// SAFETY: the engine has no thread affinity; it must not be used from two threads at once, which
// `&mut self` on every operation enforces.
unsafe impl Send for Engine {}

impl Engine {
    /// Creates an engine. `cpu_threads` = 0 uses hardware concurrency.
    pub fn new(backend: Backend, cpu_threads: u32, lane_arena_bytes: u64) -> Result<Self, String> {
        assert_eq!(unsafe { sys::fevm_abi_version() }, sys::FEVM_ABI_VERSION, "libfastevm ABI mismatch");
        let cfg = sys::fevm_config {
            backend: match backend {
                Backend::Cpu => sys::FEVM_BACKEND_CPU,
                Backend::Gpu => sys::FEVM_BACKEND_GPU,
            },
            cpu_threads,
            lane_arena_bytes,
            ..Default::default()
        };
        let mut err = core::ptr::null();
        let raw = unsafe { sys::fevm_engine_create(&cfg, &mut err) };
        if raw.is_null() {
            let msg = if err.is_null() {
                "fevm_engine_create failed".to_owned()
            } else {
                unsafe { CStr::from_ptr(err) }.to_string_lossy().into_owned()
            };
            return Err(msg);
        }
        Ok(Self { raw })
    }

    /// Raw handle.
    pub fn as_ptr(&mut self) -> *mut sys::fevm_engine {
        self.raw
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        unsafe { sys::fevm_engine_destroy(self.raw) }
    }
}

/// Owned `fevm_batch`, borrowed from an [`Engine`].
#[derive(Debug)]
pub struct Batch<'e> {
    raw: *mut sys::fevm_batch,
    _engine: core::marker::PhantomData<&'e mut Engine>,
}

impl<'e> Batch<'e> {
    /// Creates a batch sharing `block` (and one pre-state) for all its messages.
    pub fn new(engine: &'e mut Engine, block: &sys::fevm_block_ctx) -> Self {
        let raw = unsafe { sys::fevm_batch_create(engine.as_ptr(), block) };
        assert!(!raw.is_null(), "fevm_batch_create failed");
        Self { raw, _engine: core::marker::PhantomData }
    }

    /// Adds a message; returns its lane, or `None` if the engine rejected it. Input and code are
    /// copied.
    pub fn add(&mut self, msg: &sys::fevm_message) -> Option<u32> {
        let lane = unsafe { sys::fevm_batch_add(self.raw, msg) };
        u32::try_from(lane).ok()
    }

    /// Executes all messages. `host` answers state requests (see [`HostFetch`]).
    pub fn execute<H: HostFetch>(&mut self, host: &mut H) -> i32 {
        unsafe extern "C" fn trampoline<H: HostFetch>(
            ctx: *mut core::ffi::c_void,
            sink: *mut sys::fevm_sink,
            reqs: *const sys::fevm_request,
            n: u32,
        ) -> core::ffi::c_int {
            let host = unsafe { &mut *ctx.cast::<H>() };
            let reqs = unsafe { core::slice::from_raw_parts(reqs, n as usize) };
            let sink = Sink { raw: sink };
            // A panic must not unwind through C.
            match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| host.fetch(&sink, reqs))) {
                Ok(true) => 0,
                _ => 1,
            }
        }
        let h = sys::fevm_host { ctx: (host as *mut H).cast(), fetch: Some(trampoline::<H>) };
        unsafe { sys::fevm_batch_execute(self.raw, &h) }
    }

    /// Result of `lane` after [`Self::execute`].
    pub fn result(&self, lane: u32) -> Option<&sys::fevm_result> {
        unsafe { sys::fevm_batch_result(self.raw, lane).as_ref() }
    }
}

impl Drop for Batch<'_> {
    fn drop(&mut self) {
        unsafe { sys::fevm_batch_destroy(self.raw) }
    }
}

/// Answers requests through the C sink (`fevm_sink_*`).
#[derive(Debug)]
pub struct Sink {
    raw: *mut sys::fevm_sink,
}

impl Sink {
    /// Answers request `idx` with an account and its code.
    pub fn account(&self, idx: u32, info: &sys::fevm_account_info, code: &[u8]) {
        unsafe { sys::fevm_sink_account(self.raw, idx, info, code.as_ptr(), code.len() as u64) }
    }
    /// Answers request `idx` with a slot's current and transaction-original value.
    pub fn storage(&self, idx: u32, current: &[u8; 32], original: &[u8; 32], warm: bool) {
        let (c, o) = (sys::fevm_bytes32 { bytes: *current }, sys::fevm_bytes32 { bytes: *original });
        unsafe { sys::fevm_sink_storage(self.raw, idx, &c, &o, u8::from(warm)) }
    }
    /// Answers request `idx` with a block hash.
    pub fn block_hash(&self, idx: u32, hash: &[u8; 32]) {
        let h = sys::fevm_bytes32 { bytes: *hash };
        unsafe { sys::fevm_sink_blockhash(self.raw, idx, &h) }
    }
    /// Answers request `idx` with a precompile outcome (`ok` = success).
    pub fn precompile(&self, idx: u32, ok: bool, gas_left: u64, out: &[u8]) {
        let st = if ok { 0 } else { 1 };
        unsafe { sys::fevm_sink_precompile(self.raw, idx, st, gas_left, out.as_ptr(), out.len() as u64) }
    }
}

/// Client state access for a batch. Must answer every request through the sink; returning
/// `false` aborts the batch (unfinished lanes end with `FEVM_STATUS_FALLBACK`).
pub trait HostFetch {
    /// Serves `reqs`.
    fn fetch(&mut self, sink: &Sink, reqs: &[sys::fevm_request]) -> bool;
}

/// Borrowed views of a result's arrays.
pub mod view {
    use super::sys;

    fn slice<'a, T>(p: *const T, n: usize) -> &'a [T] {
        if n == 0 || p.is_null() { &[] } else { unsafe { core::slice::from_raw_parts(p, n) } }
    }

    /// Output (return or revert data).
    pub fn output(r: &sys::fevm_result) -> &[u8] {
        slice(r.output, r.output_len as usize)
    }
    /// Account diffs.
    pub fn accounts(r: &sys::fevm_result) -> &[sys::fevm_account_diff] {
        slice(r.accounts, r.n_accounts as usize)
    }
    /// Storage diffs.
    pub fn slots(r: &sys::fevm_result) -> &[sys::fevm_slot_diff] {
        slice(r.slots, r.n_slots as usize)
    }
    /// Logs.
    pub fn logs(r: &sys::fevm_result) -> &[sys::fevm_log] {
        slice(r.logs, r.n_logs as usize)
    }
    /// Code of an account diff.
    pub fn code(d: &sys::fevm_account_diff) -> &[u8] {
        slice(d.code, d.code_len as usize)
    }
    /// Data of a log.
    pub fn log_data(l: &sys::fevm_log) -> &[u8] {
        slice(l.data, l.data_len as usize)
    }
    /// Input of a precompile request.
    pub fn request_input(r: &sys::fevm_request) -> &[u8] {
        slice(r.input, r.input_len as usize)
    }
}
