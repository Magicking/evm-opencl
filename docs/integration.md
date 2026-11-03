# Using fastevm from reth, go-ethereum and Besu

## What exists today

Both clients get an **opt-in, per-message** hook: the depth-0 message of a
transaction (what geth's `EVM.Call`/`EVM.Create` or Besu's initial
`MessageFrame` would run) is executed by fastevm as a batch of one, state is
read lazily from the client's state view, and the diff is written back before
the client continues with its own transaction-level logic (gas purchase,
refund cap, fees, receipts). Anything the engine cannot run (unsupported fork,
tracer attached, system call, arena limits, host error) returns *not handled*
and the client's interpreter runs the message unchanged.

| | go-ethereum | Besu |
|---|---|---|
| Interface | `vm.ExternalEngine` (`core/vm/engine.go`), `vm.Config.Engine`, `vm.DefaultEngine` | `FastEvmExecutor.tryExecute(frame, evm, precompiles, preincremented)` |
| Hook | top of `EVM.Call` / `EVM.Create` when `depth == 0`, no tracer, not a system call | around the initial-frame loop in `MainnetTransactionProcessor` when the tracer is `NO_TRACING` |
| Binding | cgo (`bindings/go/fastevm`), adapter `bindings/go/gethvm`, build tag `fastevm` | JNA direct mapping of the flat C API (`FastEvmNative`) |
| State reads | `vm.StateDB` (Exist, balance, nonce, code, `GetStateAndCommittedState`, access list) | frame `WorldUpdater` (`get`, `getStorageValue`, `getOriginalStorageValue`), frame warm sets |
| Precompiles not run in-lane | `vm.RunPrecompiledContract` | `PrecompiledContract.computePrecompile` |
| Diff application | `CreateAccount/CreateContract`, Add/SubBalance, SetNonce, SetCode, SetState, SelfDestruct, AddRefund, AddLog | `getOrCreate`, setBalance/Nonce/Code/StorageValue, `addCreate`, `addSelfDestruct`, `addLog`, `incrementGasRefund`, frame completion |
| Enable | `-tags fastevm` + `gethvm.Install(gethvm.FromEnv())`, `FASTEVM_BACKEND=cpu\|gpu` | `-Dbesu.fastevm=cpu\|gpu -Dbesu.fastevm.lib=…` or `BESU_FASTEVM`, `FASTEVM_LIB` |

### reth (reference client)

reth's EVM is **evm2** (not revm). evm2 lets an embedder install an `InterpreterRunner` that is
offered every frame before the built-in interpreter (reth uses it for its LLVM JIT). fastevm plugs in
there, so no change to reth's executor, payload or engine code is needed:

| | reth |
|---|---|
| Interface | `evm2::InterpreterRunner` — `fastevm::runner::FastEvmRunner` (`bindings/rust/fastevm`, feature `evm2`) |
| Hook | `RethEvmFactory::configure_evm` installs the runner when built with feature `fastevm` and `FASTEVM_BACKEND=cpu\|gpu` is set (`integrations/reth.patch`, 9 files, +40 lines) |
| What runs on fastevm | depth-0 frames (CALL body, CREATE body, EIP-7702 delegated code) on Cancun/Prague/Osaka; evm2 never calls runners while an inspector is attached |
| Engine mode | **frame mode** (`fevm_message.frame_mode`): evm2 already transferred value / bumped the nonce / created the account before the frame, and deposits create code after it, so fastevm runs only the supplied code and returns output + diff |
| State reads | evm2 journaled `State` (`account`, `load_code`, `storage_slot` current/original/warm), `Host::block_hash` |
| Precompiles not run in-lane | `evm2::Precompiles::base(spec)` |
| Diff application | `AccountHandle` `mark_created`/`set_balance`/`set_nonce`/`set_code`/`mark_destructed`/`touch`, `StorageSlotHandle::set`, `State::logs_mut`, `GasTracker::set_remaining`/`record_refund`; all journaled, so evm2's frame checkpoint still rolls back |
| Threads | one CPU engine per thread (reth runs EVMs on several threads), one mutex-guarded GPU engine per process |
| Enable | `cargo build -p reth --features fastevm` (or `-p ef-tests --features ef-tests,fastevm`), `FASTEVM_BACKEND=cpu\|gpu`, `FASTEVM_STATS=<file>` appends executed/fallback counters at exit |

A frame fastevm cannot run (`FALLBACK`, host error, engine unavailable) returns `None` before any
state is touched and evm2 interprets it.

Client-specific semantics handled by the engine: Besu increments the sender
nonce before a contract-creation frame (`sender_nonce_preincremented`); geth's
stateless witness must record headers read by BLOCKHASH (done in the geth
host callback); warmness of addresses/slots comes from the client's access
list (`use_host_warm_flags`).

The per-message hook proves compliance (both clients' suites pass through it)
but it is **not** where the GPU pays off: one message per kernel launch is
latency-bound. The production integration batches.

## Proposed production integration

### 1. Batched calls (RPC and simulation) — first target

Where many independent messages share one pre-state:

* geth: `eth_simulateV1` calls within a block (`internal/ethapi/simulate.go`)
  when they are independent, a new `eth_callMany`/`eth_callBundle`-style
  endpoint, `debug_traceCall` sweeps without tracers, gas estimation binary
  searches (all probes share the pre-state: run them as one batch).
* Besu: `TransactionSimulator` batch entry point (`eth_simulateV1`,
  `eth_estimateGas` probes).

Flow: build one `fevm_batch` per (block, pre-state); add every message with its
access list (`use_host_warm_flags = 0`); optionally preload the touched set
(senders, targets, access lists); execute; map each lane result to the RPC
response. No diff is applied to client state. Fallback lanes run on the
client EVM.

Config: `--vm.engine=fastevm --vm.engine.backend=gpu --vm.engine.min-batch=64`
(below the threshold the client's interpreter is faster).

### 2. Block import (BLOCK mode) — second target

reth is the first target (it is the reference client and already executes Amsterdam blocks in
parallel from the block access list: `crates/engine/tree/src/tree/payload_processor/bal/`, with
in-order commit in `ordered_outputs.rs`). A `FastEvmBlockExecutor` behind `BlockExecutorFactory`
would submit the whole block as one batch and commit through the same ordered path.
Measured today with the per-message runner (bench workload C): reth 5.7 Ggas/s on ERC20 blocks,
fastevm CPU 2.4 Ggas/s, fastevm GPU 0.03 Ggas/s — per-message offload only adds overhead, which is
why BLOCK mode is the prerequisite for any block-import gain.

geth and Besu have the same seam: geth `StateProcessor.processParallel`
(`core/state_processor_parallel.go`), Besu `ParallelBlockTransactionProcessor`
(`OptimisticConcurrentTransactionProcessor`, `BalConcurrentTransactionProcessor`).

Engine work required (not implemented yet):

1. **Transaction mode** (`fevm_tx`): intrinsic gas, nonce/balance checks, gas
   purchase, EIP-7702 authorisations, refund cap, fee/blob-fee accounting —
   so balance conflicts (sender, coinbase) are visible to the scheduler.
   Coinbase fee credits are commutative and merged at commit.
2. **Read/write sets per lane** with the version of each base value read.
3. **Scheduler**: run all transactions of the block against the pre-state;
   validate in order on the host; commit a transaction if nothing it read was
   written by an earlier one; re-run the conflicting suffix against the updated
   state (next GPU round, then CPU once few remain). With an Amsterdam
   block-level access list (EIP-7928) the touched set is known up front:
   perfect prefetch and conflict prediction.
4. **Equivalence guard**: the client compares receipts root / state root with
   the header as today; on mismatch it re-executes the block sequentially and
   disables the engine (consensus safety first).

Client side: a `processFastEVM` path next to `processParallel` (geth) and a
`FastEvmConcurrentTransactionProcessor` (Besu), gated on no tracer, no witness
collection and engine availability; diffs are applied in transaction order.

### 3. Operational rules

* Opt-in, off by default; consensus-critical paths keep the CPU fallback and the
  root check permanently enabled.
* The library is loaded once; missing library/GPU logs one warning and uses the
  client EVM (`FastEvmExecutor.get()` returns null, `gethvm` not installed).
* Expose counters (executed / fallback by reason / CPU-retried lanes / rounds /
  transfer time) through the client's metrics system.
* Keep a persistent device-side hot-state cache across blocks (accounts and
  slots touched in the last N blocks) to cut host↔device traffic, which
  dominates on PCIe-limited hosts.
