# Benchmarks: reference client vs fastevm

All tables compare fastevm against the **reference client**: the globally fastest of reth, geth and
besu on this machine, picked by `bench/run.py` (`pick_reference`: geometric mean, over every
workload A and B row, of each client's speed relative to geth) and stored in
`bench/results/reference.json`. Current pick: **reth with the evm2 JIT** (9.7× geth; reth
interpreter 2.3×, besu 0.25×). geth and besu stay as secondary columns.

```sh
python3 bench/make_corpus.py                   # corpus: evm-benchmarks + synthetic programs
(cd bench/rethbench && cp ../../../reth/Cargo.lock . && cargo build --release)
(cd bench/gethbench && go build -o ../../build/gethbench .)
(cd bench/makechain && go build -o ../../build/makechain .)
(cd ../reth && cargo build --release -p reth --features fastevm)       # after scripts/apply-reth.sh
javac -cp "../besu/ethereum/evmtool/build/install/evmtool/lib/*" -d bench/besu bench/besu/BesuBatch.java
python3 bench/run.py --workloads A,B,C,R,D     # -> bench/results/<ts>.json (+ reference.json)
python3 bench/run.py --workloads A,B,C --engines fastevm_cpu,fastevm_gpu,fastevm_gpu_warm \
    --merge bench/results/full_v3.json --out bench/results/full_v3.json   # re-run some engines onto a file
python3 bench/report.py bench/results/full_v3.json > bench/report.md
```

`fastevm_gpu_warm` runs the GPU engine with one state id for every repeat (`fastevm-run --warm`),
so repeats after the first find accounts and slots in the engine's state cache; `fastevm_gpu`
starts each batch without an id (only code is reused). `fastevm-run --chain` instead commits each
repeat's results and runs the next repeat on the new state.

Prerequisites: `build/fastevm-run`, `build/geth-evm` (`go build -o ../fastevm/build/geth-evm ./cmd/evm`
in go-ethereum), besu `evmtool` (`./gradlew :ethereum:evmtool:installDist`), JDK 25, LLVM 23 (evm2 JIT).

## Corpus (`bench/corpus/*.json`)

| program | source | character |
|---|---|---|
| snailtracer, weierstrudel, blake2b_*, sha1_*, swap_math, structarray_alloc | ipsilon/evm-benchmarks `main` | real compute contracts |
| jump_around, JUMPDEST_n0, memory_grow_*, signextend, loop_with_many_jumpdests | evm-benchmarks `micro` | interpreter micro-paths |
| arith_loop | synthetic | 20k iterations of 256-bit MUL/ADD/XOR |
| keccak_loop | synthetic | 5k chained KECCAK256 |
| storage_rw | synthetic | 100 cold SSTORE + 100 SLOAD |
| erc20_transfer | synthetic | `transfer(to, amount)`: 2 mapping slots, faucet on low balance, Transfer log |

All programs run as a CALL to contract `0x…c0de` with Osaka rules on every engine. Gas used is
cross-checked: reth, geth and fastevm report identical execution gas on every program.

## Workloads

**A — single-message latency.** One message, warm.
* reth: `rethbench --n 1 --threads 1` — evm2 at the revision reth pins, through
  `Evm::call_tx` (a full transaction; reported gas excludes intrinsic gas). `reth-jit` compiles the
  contract with evm2's LLVM JIT before timing (a warm node with hot code; reth's own `--jit` compiles
  in the background after a hotness threshold).
* geth: `evm run --bench`; besu: `evmtool --repeat` (stateless) / batch harness `n=1` (stateful).
* fastevm: `fastevm-run --batch 1`, best of N, including batch creation and host state rounds.

**B — batch throughput.** N ∈ {1, 64, 1000, 10000} independent messages (distinct senders, same
contract, same pre-state, state discarded per message):
* reth: `rethbench`, one `evm2::Evm` per worker thread (16), `call_tx` per message.
* geth: `gethbench -engine geth`, one `StateDB` + `EVM` per goroutine; besu: `BesuBatch`.
* fastevm: `fastevm-run --batch N` (C++ driver, in-memory host) and `gethbench -engine fastevm-*`.

Programs above 50M gas only run up to N = 1000. snailtracer GPU lanes get 16 MB arenas.

**C — block import.** `bench/makechain` builds Osaka chains with go-ethereum's `GenerateChain`
(valid roots; 41 blocks of 60M gas): `erc20` (transfers, distinct senders and recipients),
`erc20_hot50` (half of the transfers to one recipient: shared slot) and `mixed` (transfers plus
arithmetic and keccak loops). reth imports each chain (`reth import`, which validates every root),
then `reth re-execute --num-tasks 1` executes the blocks in order against their parent state and
validates receipts; the reported Ggas/s is the best of three runs. Engines: reth (interpreter),
reth `--jit --jit.hot-threshold 1`, and fastevm CPU/GPU through reth's `InterpreterRunner` hook
(`FASTEVM_BACKEND`). This is the **per-message** integration (one message per batch); the
block-parallel BLOCK mode that would batch a whole block is not implemented yet.

**R — reth ef-tests runtime.** `cargo test --release -p ef-tests --features ef-tests,fastevm`
(ethereum/tests v17 + EEST v4.5.0), same binary, native vs `FASTEVM_BACKEND=cpu|gpu`.

**D — geth compliance-suite runtime.** geth's execution-spec state tests (Cancun..Osaka, `-short`).

## Reading the numbers

* The GPU in the test machine sits behind a PCIe Gen3 ×4 link (≈3.5 GB/s): host↔device copies are a
  large share of GPU batch time. `fastevm-run --json` reports `exec_s` and `transfer_s` separately.
* A lane that exceeds its GPU arena re-runs on the CPU backend; reports flag it (`cpu_retried`).
* Per-message offload (A, C, R, D) is latency-bound by construction: the GPU only competes when one
  launch carries thousands of lanes (B).
