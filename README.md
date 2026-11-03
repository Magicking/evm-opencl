# fastevm

A batch EVM execution engine with a CUDA backend and a CPU reference backend,
pluggable into **reth**, **go-ethereum** and **Hyperledger Besu**.

Benchmarks and the primary compliance gate use the **globally fastest client** as reference,
picked by measurement (`bench/run.py`, `bench/results/reference.json`): currently **reth with its
evm2 JIT** (geomean 9.7× geth over workloads A+B; reth interpreter 2.3×, besu 0.25×).

One CUDA thread runs one EVM message. The GPU wins on *throughput*: many
independent messages at once (`eth_call` / `eth_simulateV1` bundles, test
suites, MEV simulation, and — once the block scheduler lands — optimistic
parallel block execution). A single message on a GPU is latency-bound and
slower than a CPU interpreter; the engine says so in its benchmarks.

Forks: **Cancun, Prague, Osaka**. Older forks and Amsterdam fall back to the
client's own EVM.

```
 reth (Rust, --features fastevm)   geth (cgo, -tags fastevm)   besu (JNA, -Dbesu.fastevm)
   evm2 InterpreterRunner           core/vm.ExternalEngine      MainnetTransactionProcessor
   (frame mode)                            |                    hook
            \______________________________|_______________________/
                                   fastevm.h C ABI
                            |
     libfastevm.so  host runtime (C++20)
       batch + base-state cache, round loop (suspend/resume on state misses),
       host callbacks, result packing, CPU backend (threads)
                            |
     CUDA backend (sm_89)   same interpreter source (__host__ __device__)
       1 thread = 1 message, interleaved (coalesced) operand stacks,
       per-lane arenas, device precompiles (sha256/ripemd/identity/blake2f)
```

## Status

| Area | State |
|---|---|
| Interpreter (all Cancun/Prague/Osaka opcodes, nested calls, CREATE/CREATE2, EIP-7702 delegation, transient storage, EIP-6780) | done, shared host/device source |
| CPU backend (thread pool) | done |
| CUDA backend | done; lanes that exceed GPU arena limits transparently re-run on CPU |
| Precompiles | sha256, ripemd160, identity, blake2f in-lane; ecrecover, modexp, bn254, KZG, BLS12-381, P256 via host callback (bit-exact with the client) |
| reth integration (Rust binding `bindings/rust/fastevm`, evm2 `InterpreterRunner`, frame mode, `integrations/reth.patch`) | done |
| geth integration (`vm.ExternalEngine`, cgo binding, geth test hook) | done |
| besu integration (JNA adapter, tx-processor hook, ref-test property passthrough) | done |
| Block-parallel scheduler (Block-STM-style BLOCK mode) | **not implemented yet** (design below) |
| FPGA backend | **proposal only** (1–10 cores): requirements and board pick (ALINX AXKU15; AXKU5 budget) in [`docs/fpga.md`](docs/fpga.md) |

### Compliance

reth pins ethereum/tests v17.0 + EEST v4.5.0; geth and besu pin execution-spec-tests `tests@v21.0.1`.

| Suite | Engine | Result |
|---|---|---|
| **reth** `ef-tests` (legacy GeneralStateTests as blockchain tests, ValidBlocks, InvalidBlocks, EEST v4.5.0) | fastevm CPU, fastevm GPU | 60/60 test groups pass, **0 failures** (102,225 top-level frames on fastevm, 74 resource fallbacks, 10,919 pre-Cancun frames skipped) |
| **reth** `ef-test-runner` on tests@v21.0.1 blockchain tests (Cancun, Prague, Osaka, Cancun→Prague) | fastevm CPU, fastevm GPU | 7,290 tests, results identical to native reth: 2 failures that reth also has natively (Cancun→Prague system-contract deployment), **0 caused by fastevm** (209,629 frames on fastevm, 67 fallbacks) |
| geth `TestExecutionSpecState` (all fork dirs, 4 trie/snapshot permutations) | fastevm CPU | 421,173 subtests, **0 failures** (152,836 messages on fastevm, 264 resource fallbacks) |
| geth `TestExecutionSpecState` Cancun/Prague/Osaka | fastevm CPU, fastevm GPU | 83,149 subtests each, **0 failures** |
| geth `TestExecutionSpecBlocktests` Cancun/Prague/Osaka + transitions | fastevm CPU | 50,067 subtests, **0 failures** (582,575 messages on fastevm) |
| besu `ExecutionSpecStateTest*` (all forks, 2,309 classes) | fastevm CPU, fastevm GPU | 83,367 tests each, **0 failures, 0 errors** (38,209 messages on fastevm, 66 resource fallbacks) |
| CPU vs GPU differential fuzz (2,000 random programs) | both | identical status/gas/output/diffs |
| Corpus differential vs geth `evm run` | CPU | identical gas used and output on every program |

"Resource fallback" = a message exceeded the lane arena (tables, journal,
memory); it is executed by the client's own EVM, so results are unaffected.

## Build

Requirements: CMake ≥ 3.24, a C++20 compiler, CUDA ≥ 12 (optional), GoogleTest (tests).

```sh
cmake -B build -G Ninja -DFASTEVM_GPU=ON      # -DFASTEVM_GPU=OFF for CPU only
cmake --build build
./build/fastevm-tests                          # unit + interpreter + CPU/GPU differential tests
./build/fastevm-run --code 6002600301600052602060 00f3 --backend gpu --batch 10000 --repeat 5
```

## C ABI

`include/fastevm.h`. A *batch* holds messages that share a block context and a
pre-state. `fevm_batch_execute` runs them; state is pulled through one batched
host callback per round (`fevm_host.fetch`, answered via `fevm_sink_*`).
Results are per-lane state diffs (balances, nonces, code, storage, created /
self-destructed / touched accounts), logs, output, gas left and refund delta.
A flat, primitive-argument variant (`*_flat`) exists for JNA/FFM/ctypes.

## Client integration

### go-ethereum

`integrations/geth.patch` adds `vm.ExternalEngine` (`core/vm/engine.go`), a
`Config.Engine` field, a two-line hook in `EVM.Call`/`EVM.Create` for depth-0
messages (no tracer, not a system call), and `tests/fastevm_test.go`.
The adapter lives in `bindings/go/gethvm` (StateDB ⇄ engine host callbacks,
diff application, witness recording for `BLOCKHASH`).

```sh
scripts/apply-geth.sh                       # patch ../go-ethereum
cd ../go-ethereum
go test -tags fastevm ./tests -run 'TestExecutionSpecState|TestExecutionSpecBlocktests'
FASTEVM_BACKEND=gpu go test -tags fastevm ./tests -run TestExecutionSpecState
```

### Besu

`integrations/besu.patch` adds `org.hyperledger.besu.evm.fastevm`
(`FastEvmNative` JNA mapping, `FastEvmExecutor` adapter) and a hook around the
initial-frame loop of `MainnetTransactionProcessor`. Enable with
`-Dbesu.fastevm=cpu|gpu -Dbesu.fastevm.lib=/path/libfastevm.so`
(or `BESU_FASTEVM` / `FASTEVM_LIB`). Missing library or GPU → Java EVM.

```sh
scripts/apply-besu.sh
cd ../besu
./gradlew :ethereum:referencetests:referenceTests --tests '*ExecutionSpecStateTest*' \
  -Dbesu.fastevm=cpu -Dbesu.fastevm.lib=$PWD/../fastevm/build/libfastevm.so
```

## Benchmarks

`bench/` — see `bench/README.md`. `bench/make_corpus.py` builds the corpus
(ipsilon/evm-benchmarks + synthetic ERC20/keccak/arith/storage programs);
`bench/run.py` runs workloads A (single-message latency), B (batch throughput,
N ∈ {1, 64, 1k, 10k}) and D (compliance-suite runtime) on geth, besu,
fastevm-CPU and fastevm-GPU; `bench/report.py` renders the results.

### Results (Ryzen 9 7940HS 16 threads, RTX 4060 Ti on PCIe Gen3 x4; full tables in `bench/report.md`)

Reference = reth+JIT. Batch of N independent messages, messages/s (CPU engines: 16 threads):

| program | N | reth+JIT | reth | geth | fastevm CPU | fastevm GPU | GPU vs reference |
|---|---:|---:|---:|---:|---:|---:|---:|
| keccak_loop | 10,000 | 7.0k | 6.4k | 8.8k | 4.8k | 28.0k | **4.0×** |
| arith_loop (256-bit math) | 10,000 | 209k | 11.7k | 5.0k | 6.6k | 21.7k | 0.10× |
| blake2b_shifts | 1,000 | 4.9k | 1.5k | 218 | 939 | 778 | 0.16× |
| weierstrudel | 1,000 | 108k | 80k | 50k | 56.8k | 61.7k | 0.57× |
| snailtracer | 1,000 | 822 | 378 | 104 | 310 | 104 | 0.13× |
| erc20_transfer | 10,000 | 4.50M | 4.22M | 1.00M | 854k | 435k | 0.10× |
| storage_rw | 10,000 | 1.09M | 740k | 87k | 107k | 58k | 0.05× |

Block import (workload C: reth `re-execute`, 40 blocks × 60M gas, receipts validated):

| chain | reth | reth+JIT | fastevm CPU | fastevm GPU |
|---|---:|---:|---:|---:|
| ERC20 transfers | 5.74 Ggas/s | 5.40 | 2.45 | 0.03 |
| ERC20, 50 % to one hot recipient | 5.88 | 5.67 | 2.25 | 0.02 |
| transfers + arith/keccak loops | 2.17 | 6.14 | 0.61 | 0.01 |

* Against the fastest client the GPU wins only where evm2's JIT cannot help: keccak-bound code
  (4× reth+JIT at N = 10k). evm2's JIT turns 256-bit arithmetic loops into native code
  (209k msgs/s), 10× the GPU.
* Block import through the per-message hook is overhead only (one message per GPU launch, a batch
  plus host callbacks per transaction on CPU). A gain needs the BLOCK-mode scheduler (whole block per
  batch), which is designed (`docs/integration.md`) but not implemented.
* Single messages: the GPU is 20-100× slower than a CPU interpreter; fastevm CPU is 1-3× slower
  than reth's interpreter and slower still than its JIT.
* reth ef-tests: native 46.4 s, fastevm CPU 47.3 s, fastevm GPU 436 s.

## Design notes

* **Restartable opcodes.** Every opcode performs its state lookups before any
  observable mutation. A miss records a request and suspends the lane; the
  dispatcher restores pc/gas/sp/memory size, so the opcode simply re-executes
  after the host answered. No coroutines, no host↔device synchronisation inside
  a kernel.
* **Lane arena.** Overlay account/storage/transient tables, journal, logs,
  frames, heap and EVM memory live in one per-lane arena addressed by offsets
  (`Loc`), so host and device share a layout. Lanes clear the table entries they
  used when they finish, so arenas are reused across batches without zeroing.
* **Coalesced stacks.** On the GPU, stack item *k* of lane *l* lives at
  `k·N + l`: a warp touching the same depth hits one contiguous segment
  (5.3× faster than per-lane stacks on arithmetic-heavy code).
* **Planned BLOCK mode.** Execute all transactions of a block optimistically
  against the pre-state, record read/write sets per lane, validate in order on
  the host, re-run conflicting transactions against the updated state (GPU
  rounds, then CPU), BAL-driven prefetch for Amsterdam. Result must equal
  sequential execution or the client falls back.
