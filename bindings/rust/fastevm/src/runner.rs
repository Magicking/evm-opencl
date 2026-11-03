//! evm2 `InterpreterRunner` that executes top-level frames on fastevm.
//!
//! evm2 calls the runner after it prepared a frame: for a call the value is already transferred,
//! for a create the sender nonce is bumped and the contract account exists with its endowment.
//! The runner therefore uses fastevm's *frame mode*: run `message.code` in the prepared context,
//! return the output (evm2 deposits create code itself) and the state diff, which is written into
//! evm2's journaled state so the frame checkpoint still rolls it back on revert/halt.
//!
//! Only depth-0 frames on Cancun/Prague/Osaka without an inspector run on fastevm (evm2 never
//! calls runners while inspecting). Everything else, and every message fastevm reports as
//! `FALLBACK`, runs on the inner interpreter: returning `None` before touching any state.

use crate::{Backend, Batch, Engine, HostFetch, Sink, sys, view};
use alloy_primitives::{Address, B256, Bytes, Log, U256};
use evm2::{
    BaseEvmTypes, Evm, InterpreterRunner, Precompiles, SpecId,
    bytecode::Bytecode,
    interpreter::{GasTracker, Host, InstrStop, Interpreter, Message, MessageKind},
};
use std::{
    cell::RefCell,
    sync::{
        Mutex, OnceLock,
        atomic::{AtomicU64, Ordering::Relaxed},
    },
};

/// How top-level frames were handled, process-wide.
#[derive(Debug, Default)]
pub struct Counters {
    /// Frames executed on fastevm.
    pub executed: AtomicU64,
    /// Frames fastevm handed back (`FALLBACK`, host error, engine unavailable).
    pub fallbacks: AtomicU64,
    /// Top-level frames not offered to fastevm (unsupported fork, static, EIP-8037 reservoir).
    pub skipped: AtomicU64,
}

/// Process-wide counters.
pub static COUNTERS: Counters = Counters {
    executed: AtomicU64::new(0),
    fallbacks: AtomicU64::new(0),
    skipped: AtomicU64::new(0),
};

impl Counters {
    /// `executed=.. fallbacks=.. skipped=..`.
    pub fn summary(&self) -> String {
        format!(
            "fastevm: executed={} fallbacks={} skipped={}",
            self.executed.load(Relaxed),
            self.fallbacks.load(Relaxed),
            self.skipped.load(Relaxed)
        )
    }
}

/// Appends the counters to `$FASTEVM_STATS` (one line per process) at exit, if set.
fn register_stats_at_exit() {
    static ONCE: OnceLock<()> = OnceLock::new();
    ONCE.get_or_init(|| {
        unsafe extern "C" {
            fn atexit(cb: extern "C" fn()) -> core::ffi::c_int;
        }
        extern "C" fn dump() {
            let Some(path) = std::env::var_os("FASTEVM_STATS") else { return };
            if COUNTERS.executed.load(Relaxed) + COUNTERS.fallbacks.load(Relaxed) + COUNTERS.skipped.load(Relaxed)
                == 0
            {
                return;
            }
            use std::io::Write;
            if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
                let _ = writeln!(f, "{}", COUNTERS.summary());
            }
        }
        unsafe { atexit(dump) };
    });
}

thread_local! {
    // The C engine is single-threaded: one CPU engine per thread (evm2 runs several EVMs in
    // parallel, e.g. reth's BAL workers and the ef-tests runner).
    static CPU_ENGINE: RefCell<Option<Engine>> = const { RefCell::new(None) };
}
// One GPU engine per process (device memory), serialised.
static GPU_ENGINE: OnceLock<Option<Mutex<Engine>>> = OnceLock::new();

fn with_engine<R>(backend: Backend, f: impl FnOnce(&mut Engine) -> R) -> Option<R> {
    match backend {
        Backend::Cpu => CPU_ENGINE.with(|cell| {
            let mut slot = cell.borrow_mut();
            if slot.is_none() {
                *slot = Some(Engine::new(Backend::Cpu, 1, 0).ok()?);
            }
            Some(f(slot.as_mut()?))
        }),
        Backend::Gpu => {
            let engine = GPU_ENGINE.get_or_init(|| match Engine::new(Backend::Gpu, 1, 0) {
                Ok(e) => Some(Mutex::new(e)),
                Err(err) => {
                    eprintln!("fastevm: GPU engine unavailable ({err}); using evm2");
                    None
                }
            });
            let mut guard = engine.as_ref()?.lock().unwrap_or_else(|e| e.into_inner());
            Some(f(&mut guard))
        }
    }
}

/// evm2 interpreter runner backed by fastevm.
#[derive(Clone, Copy, Debug)]
pub struct FastEvmRunner {
    backend: Backend,
}

impl FastEvmRunner {
    /// Runner for `backend`.
    pub fn new(backend: Backend) -> Self {
        register_stats_at_exit();
        Self { backend }
    }

    /// Runner selected by `FASTEVM_BACKEND=cpu|gpu`, or `None` when unset.
    pub fn from_env() -> Option<Self> {
        Backend::from_env().map(Self::new)
    }
}

const fn fork_of(spec: SpecId) -> Option<u32> {
    match spec {
        SpecId::CANCUN => Some(sys::FEVM_FORK_CANCUN),
        SpecId::PRAGUE => Some(sys::FEVM_FORK_PRAGUE),
        SpecId::OSAKA => Some(sys::FEVM_FORK_OSAKA),
        _ => None,
    }
}

fn addr(a: &Address) -> sys::fevm_address {
    sys::fevm_address { bytes: a.0.0 }
}
fn word(v: &U256) -> sys::fevm_bytes32 {
    sys::fevm_bytes32 { bytes: v.to_be_bytes() }
}
fn u64_sat(v: &U256) -> u64 {
    u64::try_from(*v).unwrap_or(u64::MAX)
}

/// Serves fastevm state requests from evm2's journaled state.
struct EvmHost<'h, 'a> {
    evm: &'h mut Evm<'a, BaseEvmTypes>,
    precompiles: Precompiles<BaseEvmTypes>,
    caller: Address,
}

impl HostFetch for EvmHost<'_, '_> {
    fn fetch(&mut self, sink: &Sink, reqs: &[sys::fevm_request]) -> bool {
        for (i, r) in reqs.iter().enumerate() {
            let i = i as u32;
            let a = Address::from(r.address.bytes);
            match r.kind {
                sys::FEVM_REQ_ACCOUNT => {
                    let Ok(mut acc) = self.evm.state_mut().account(&a) else { return false };
                    let mut info = sys::fevm_account_info {
                        exists: u8::from(acc.exists()),
                        warm: u8::from(acc.is_warm()),
                        ..Default::default()
                    };
                    if !acc.exists() {
                        sink.account(i, &info, &[]);
                        continue;
                    }
                    // Storage emptiness is not known cheaply mid-block: let the engine ask.
                    info.has_storage = 1;
                    info.nonce = acc.nonce();
                    info.balance = word(&acc.balance());
                    info.code_hash = sys::fevm_bytes32 { bytes: acc.code_hash().0 };
                    let Ok(code) = acc.load_code() else { return false };
                    sink.account(i, &info, code.original_byte_slice());
                }
                sys::FEVM_REQ_STORAGE => {
                    let key = U256::from_be_bytes(r.key.bytes);
                    let Ok(slot) = self.evm.state_mut().storage_slot(&a, key) else { return false };
                    sink.storage(i, &slot.current().to_be_bytes(), &slot.original().to_be_bytes(), slot.is_warm());
                }
                sys::FEVM_REQ_BLOCKHASH => {
                    let Ok(h) = Host::block_hash(self.evm, &U256::from(r.number)) else { return false };
                    sink.block_hash(i, &h.0);
                }
                sys::FEVM_REQ_PRECOMPILE => {
                    let message = Message::<BaseEvmTypes> {
                        kind: MessageKind::Call,
                        depth: 1,
                        gas_limit: r.gas,
                        destination: a,
                        call_target: a,
                        caller: self.caller,
                        input: Bytes::copy_from_slice(view::request_input(r)),
                        code_address: a,
                        ..Default::default()
                    };
                    let mut gas = GasTracker::new(r.gas);
                    use evm2::evm::precompile::PrecompileProvider;
                    match self.precompiles.execute(self.evm, &message, &mut gas) {
                        Some(Ok(out)) => sink.precompile(i, true, gas.remaining(), out.bytes()),
                        _ => sink.precompile(i, false, 0, &[]),
                    }
                }
                _ => return false,
            }
        }
        true
    }
}

fn halt_stop(err: u32) -> InstrStop {
    match err {
        sys::FEVM_ERR_INVALID_OPCODE => InstrStop::OpcodeNotFound,
        sys::FEVM_ERR_STACK_UNDERFLOW => InstrStop::StackUnderflow,
        sys::FEVM_ERR_STACK_OVERFLOW => InstrStop::StackOverflow,
        sys::FEVM_ERR_BAD_JUMP => InstrStop::InvalidJump,
        sys::FEVM_ERR_STATIC_VIOLATION => InstrStop::StateChangeDuringStaticCall,
        sys::FEVM_ERR_RETURNDATA_OOB => InstrStop::OutOfOffset,
        sys::FEVM_ERR_PRECOMPILE => InstrStop::PrecompileError,
        _ => InstrStop::OutOfGas,
    }
}

/// Writes the frame's state diff into evm2's journaled state.
fn apply(
    evm: &mut Evm<'_, BaseEvmTypes>,
    r: &sys::fevm_result,
    create_body: Option<Address>,
) -> evm2::evm::DbResult<()> {
    let state = evm.state_mut();
    for d in view::accounts(r) {
        let a = Address::from(d.address.bytes);
        let mut acc = state.account(&a)?;
        // The create body's own account was created by evm2 before the frame ran.
        if d.flags & sys::FEVM_ACC_CREATED != 0 && create_body != Some(a) {
            acc.get_or_insert();
            acc.mark_created();
            acc.touch();
        }
        if d.flags & sys::FEVM_ACC_BALANCE != 0 {
            acc.set_balance(U256::from_be_bytes(d.balance.bytes));
        } else if d.flags & sys::FEVM_ACC_TOUCHED != 0 {
            acc.touch();
        }
        if d.flags & sys::FEVM_ACC_NONCE != 0 {
            acc.set_nonce(d.nonce);
        }
        if d.flags & sys::FEVM_ACC_CODE != 0 {
            let code = Bytecode::new_legacy(Bytes::copy_from_slice(view::code(d)));
            acc.set_code(B256::from(d.code_hash.bytes), code);
        }
        if d.flags & sys::FEVM_ACC_DESTRUCTED != 0 {
            acc.mark_destructed();
        }
    }
    for s in view::slots(r) {
        let a = Address::from(s.address.bytes);
        state.storage_slot(&a, U256::from_be_bytes(s.key.bytes))?.set(U256::from_be_bytes(s.value.bytes));
    }
    for l in view::logs(r) {
        let topics = l.topics[..l.n_topics as usize].iter().map(|t| B256::from(t.bytes)).collect();
        state.logs_mut().push(Log::new_unchecked(
            Address::from(l.address.bytes),
            topics,
            Bytes::copy_from_slice(view::log_data(l)),
        ));
    }
    Ok(())
}

impl InterpreterRunner<BaseEvmTypes> for FastEvmRunner {
    fn run<'frame, 'host>(
        &self,
        interp: &mut Interpreter<'frame, 'host, BaseEvmTypes>,
        host: &mut Evm<'host, BaseEvmTypes>,
    ) -> Option<InstrStop> {
        // Wires spec, version and host into the frame; `spec()`/`version()` read them.
        interp.prepare_run(host);
        let msg = interp.message();
        if msg.depth != interp.version().initial_call_depth {
            return None; // nested frames of evm2-run messages stay on evm2
        }
        let spec = interp.spec();
        let create_body = matches!(msg.kind, MessageKind::Create | MessageKind::Create2);
        let Some(fork) = fork_of(spec) else {
            COUNTERS.skipped.fetch_add(1, Relaxed);
            return None;
        };
        if interp.is_static() || msg.reservoir != 0 || !(create_body || msg.kind == MessageKind::Call) {
            COUNTERS.skipped.fetch_add(1, Relaxed);
            return None;
        }

        let tx = interp.tx_env();
        let blk = Host::block_env(host);
        let block = sys::fevm_block_ctx {
            coinbase: addr(&blk.beneficiary),
            number: u64_sat(&blk.number),
            timestamp: u64_sat(&blk.timestamp),
            gas_limit: u64_sat(&blk.gas_limit),
            prev_randao: word(&blk.prevrandao),
            base_fee: word(&blk.basefee),
            blob_base_fee: word(&blk.blob_basefee),
            chain_id: word(&tx.chain_id),
            fork,
        };
        let blob_hashes: Vec<sys::fevm_bytes32> = tx.blob_hashes.iter().map(word).collect();
        let code = msg.code.original_byte_slice();
        let input: &[u8] = if create_body { &[] } else { &msg.input };
        let m = sys::fevm_message {
            kind: sys::FEVM_MSG_CALL,
            sender: addr(&msg.caller),
            recipient: addr(&msg.destination),
            value: word(&msg.value),
            gas: interp.gas().tracker().remaining(),
            input: input.as_ptr(),
            input_len: input.len() as u64,
            origin: addr(&tx.origin),
            gas_price: word(&tx.gas_price),
            blob_hashes: blob_hashes.as_ptr(),
            n_blob_hashes: blob_hashes.len() as u32,
            use_host_warm_flags: 1,
            frame_mode: 1,
            frame_is_create: u32::from(create_body),
            code: code.as_ptr(),
            code_len: code.len() as u64,
            ..Default::default()
        };
        let destination = msg.destination;
        let caller = msg.caller;

        let outcome = with_engine(self.backend, |engine| {
            let mut batch = Batch::new(engine, &block);
            batch.add(&m)?;
            let mut eh = EvmHost { evm: &mut *host, precompiles: Precompiles::base(spec), caller };
            let rc = batch.execute(&mut eh);
            drop(eh);
            if rc != 0 {
                return None;
            }
            let r = batch.result(0)?;
            if r.status == sys::FEVM_STATUS_FALLBACK || r.status == sys::FEVM_STATUS_FAILURE {
                return None;
            }
            // From here on the frame is fastevm's: apply the diff, then hand evm2 the outcome.
            let applied = apply(host, r, create_body.then_some(destination));
            Some((r.status, r.error, r.gas_left, r.refund, view::output(r).to_vec(), applied))
        })
        .flatten();
        let Some((status, error, gas_left, refund, output, applied)) = outcome else {
            COUNTERS.fallbacks.fetch_add(1, Relaxed);
            return None;
        };
        COUNTERS.executed.fetch_add(1, Relaxed);
        if let Err(e) = applied {
            return Some(interp.fail(e));
        }

        let gas = interp.gas_mut().tracker_mut();
        gas.set_remaining(gas_left);
        if status == sys::FEVM_STATUS_SUCCESS {
            gas.record_refund(refund);
        }
        let stop = match status {
            sys::FEVM_STATUS_SUCCESS => InstrStop::Return,
            sys::FEVM_STATUS_REVERT => InstrStop::Revert,
            _ => return Some(halt_stop(error)),
        };
        let len = output.len();
        if len > 0 {
            let mem = interp.memory_mut();
            if mem.len() < len {
                if mem.resize(0, len).is_err() {
                    return Some(InstrStop::MemoryLimitOOG);
                }
            }
            mem.set(0, &output);
        }
        interp.set_output(0..len as u32);
        Some(stop)
    }
}
