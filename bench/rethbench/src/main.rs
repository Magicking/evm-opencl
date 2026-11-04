//! rethbench measures batch throughput of N independent EVM messages (distinct senders, same
//! contract, same pre-state) on reth's EVM, evm2, at the revision reth pins:
//!
//!   --engine reth      evm2 interpreter (reth's default; `--jit` is off by default)
//!   --engine reth-jit  evm2 + LLVM JIT, contract compiled before the timed runs (warm node)
//!
//! Each worker thread owns one `evm2::Evm` over the same in-memory pre-state and runs messages
//! with `call_tx` (execute, discard state), like gethbench's snapshot/revert per message.
//! Output: one JSON line with the same keys as bench/gethbench.

use alloy_consensus::{TxLegacy, transaction::Recovered};
use alloy_primitives::{Address, B256, Bytes, TxKind, U256, keccak256};
use evm2::{
    BaseEvmTypes, Evm, ExecutionConfig, InterpreterRunner, Precompiles, SpecId, Version,
    bytecode::Bytecode,
    env::{BlockEnv, BlockEnvExt},
    ethereum::{RecoveredTxEnvelope, TxEnvelope, ethereum_tx_registry},
    evm::{AccountInfo, InMemoryDB},
    interpreter::{InstrStop, Interpreter},
};
use evm2_jit::{EvmCompiler, EvmCompilerFn};
use std::{
    collections::HashMap,
    sync::{Arc, Barrier, Mutex},
    time::Instant,
};

#[global_allocator]
static ALLOC: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;

const CONTRACT: Address = {
    let mut a = [0u8; 20];
    a[18] = 0xc0;
    a[19] = 0xde;
    Address::new(a)
};
const SPEC: SpecId = SpecId::OSAKA;

#[derive(serde::Deserialize)]
struct CorpusItem {
    name: String,
    code: String,
    #[serde(default)]
    input: String,
    gas: u64,
}

fn sender(i: usize) -> Address {
    Address::left_padding_from(&((0x100000 + i) as u64).to_be_bytes())
}

#[derive(Clone, Debug)]
struct FixedJitRunner {
    functions: Arc<HashMap<B256, EvmCompilerFn>>,
}

impl InterpreterRunner<BaseEvmTypes> for FixedJitRunner {
    fn run<'frame, 'host>(
        &self,
        interpreter: &mut Interpreter<'frame, 'host, BaseEvmTypes>,
        host: &mut Evm<'host, BaseEvmTypes>,
    ) -> Option<InstrStop> {
        // Compiled code treats the remaining gas as signed.
        if interpreter.gas().remaining() > i64::MAX as u64 {
            return None;
        }
        let func = *self.functions.get(&interpreter.original_bytecode_hash())?;
        interpreter.prepare_run(host);
        Some(unsafe { func.call_with_interpreter(interpreter) })
    }
}

struct Args {
    corpus: String,
    engine: String,
    n: usize,
    threads: usize,
    repeat: usize,
}

fn parse_args() -> Args {
    let mut a = Args {
        corpus: String::new(),
        engine: "reth".into(),
        n: 1000,
        threads: std::thread::available_parallelism().map_or(1, |n| n.get()),
        repeat: 5,
    };
    let mut it = std::env::args().skip(1);
    while let Some(k) = it.next() {
        let k = k.trim_start_matches('-').to_owned();
        let (k, v) = match k.split_once('=') {
            Some((k, v)) => (k.to_owned(), v.to_owned()),
            None => (k, it.next().expect("missing flag value")),
        };
        match k.as_str() {
            "corpus" => a.corpus = v,
            "engine" => a.engine = v,
            "n" => a.n = v.parse().unwrap(),
            "threads" => a.threads = v.parse().unwrap(),
            "repeat" => a.repeat = v.parse().unwrap(),
            "arena" => {} // accepted for CLI parity with gethbench
            _ => panic!("unknown flag --{k}"),
        }
    }
    a
}

fn main() {
    let args = parse_args();
    let item: CorpusItem =
        serde_json::from_slice(&std::fs::read(&args.corpus).expect("read corpus")).expect("corpus json");
    let code = hex::decode(&item.code).expect("code hex");
    let input = Bytes::from(hex::decode(&item.input).expect("input hex"));

    let bytecode = Bytecode::new_legacy(Bytes::copy_from_slice(&code));
    let mut db = InMemoryDB::default();
    db.insert_account_info(&CONTRACT, AccountInfo::default().with_nonce(1).with_code(bytecode));

    // Messages carry the corpus gas (up to 1e9), above Osaka's EIP-7825 cap: lift the cap so the
    // same programs as geth's `evm.Call` run unchanged. Everything else is reth's Osaka config.
    let mut version = Version::base(SPEC).clone();
    version.tx_gas_limit_cap = u64::MAX;
    let block: BlockEnv = BlockEnvExt {
        number: U256::from(1),
        timestamp: U256::from(1),
        gas_limit: U256::from(u64::MAX),
        ..BlockEnvExt::default()
    };
    let txs: Vec<RecoveredTxEnvelope> = (0..args.n)
        .map(|i| {
            let tx = TxLegacy {
                chain_id: None,
                nonce: 0,
                gas_price: 0,
                gas_limit: item.gas,
                to: TxKind::Call(CONTRACT),
                value: U256::ZERO,
                input: input.clone(),
            };
            Recovered::new_unchecked(TxEnvelope::Legacy(tx), sender(i))
        })
        .collect();

    let (runner, _compiler) = match args.engine.as_str() {
        "reth" => (None, None),
        "reth-jit" => {
            let mut compiler = EvmCompiler::new_llvm(false).expect("llvm");
            let f = unsafe { compiler.jit("contract", code.as_slice(), SPEC) }.expect("jit");
            let functions = Arc::new(HashMap::from([(keccak256(&code), f)]));
            (Some(FixedJitRunner { functions }), Some(compiler))
        }
        e => panic!("unknown engine {e}"),
    };

    let new_evm = || {
        let mut evm = Evm::new_with_execution_config(
            ExecutionConfig::for_spec_and_version(SPEC, version.clone()),
            SPEC,
            block,
            ethereum_tx_registry(SPEC),
            db.clone(),
            Precompiles::base(SPEC),
        );
        if let Some(r) = &runner {
            evm.set_interpreter_runner(r.clone());
        }
        evm
    };
    let work = |evm: &mut Evm<'static, BaseEvmTypes>, t: usize, stride: usize| {
        let (mut g, mut f) = (0u64, 0u64);
        for tx in txs.iter().skip(t).step_by(stride) {
            let r = evm.call_tx(tx).expect("tx rejected");
            g += r.total_gas_spent;
            f += u64::from(!r.status);
        }
        (g, f)
    };

    // One EVM per worker thread, reused across messages and runs (warm caches, like gethbench's
    // per-goroutine StateDBs). `Evm` is not `Send`, so each worker builds its own and the main
    // thread times the runs between barriers. With one thread, run inline (latency runs).
    let rounds = args.repeat + 1; // first round = warmup
    let mut times = Vec::with_capacity(args.repeat);
    let (mut gas, mut failed) = (0, 0);
    if args.threads == 1 {
        let mut evm = new_evm();
        for round in 0..rounds {
            let t0 = Instant::now();
            (gas, failed) = work(&mut evm, 0, 1);
            let dt = t0.elapsed().as_secs_f64();
            if round > 0 {
                times.push(dt);
            }
        }
    } else {
        let barrier = Barrier::new(args.threads + 1);
        let totals: Vec<Mutex<(u64, u64)>> = (0..args.threads).map(|_| Mutex::new((0, 0))).collect();
        std::thread::scope(|s| {
            for t in 0..args.threads {
                let (barrier, totals, new_evm, work) = (&barrier, &totals, &new_evm, &work);
                s.spawn(move || {
                    let mut evm = new_evm();
                    for _ in 0..rounds {
                        barrier.wait();
                        *totals[t].lock().unwrap() = work(&mut evm, t, args.threads);
                        barrier.wait();
                    }
                });
            }
            for round in 0..rounds {
                // Start the clock before releasing the workers: with one worker per core the main
                // thread can be descheduled right after the barrier.
                let t0 = Instant::now();
                barrier.wait();
                barrier.wait();
                let dt = t0.elapsed().as_secs_f64();
                if round > 0 {
                    times.push(dt);
                }
            }
        });
        (gas, failed) =
            totals.iter().map(|m| *m.lock().unwrap()).fold((0, 0), |a, b| (a.0 + b.0, a.1 + b.1));
    }
    times.sort_by(f64::total_cmp);
    let (best, median) = (times[0], times[times.len() / 2]);
    // Report execution gas like gethbench (tx-level total minus intrinsic: 21000 + calldata).
    let calldata_gas: u64 = input.iter().map(|&b| if b == 0 { 4 } else { 16 }).sum();
    let exec_gas = gas.saturating_sub(args.n as u64 * (21000 + calldata_gas));
    println!(
        "{}",
        serde_json::json!({
            "engine": args.engine, "name": item.name, "batch": args.n, "threads": args.threads,
            "best_s": best, "median_s": median, "msgs_per_s": args.n as f64 / median,
            "gas_used": exec_gas, "tx_gas_used": gas, "failed": failed,
            "mgas_per_s": exec_gas as f64 / median / 1e6,
        })
    );
}
