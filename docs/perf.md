# GPU state cache and round-loop performance

Status: **implemented** (state cache, delta uploads, compact round download, equal loads, two
overlapping lane groups). The remaining bottlenecks at the end are **proposals**.

Machine: RTX 4060 Ti behind PCIe Gen3 ×4 (about 3.5 GB/s), Ryzen 9 7940HS. Every number below was
measured with `fastevm-run` (and `FASTEVM_TRACE=1` for the per-step breakdowns) or `bench/run.py`.
Full tables: `bench/report.md`, data `bench/results/full_v3.json` (before: `full_v2.json`).

## What was slow (erc20_transfer, before)

| | 1 message | 10,000 messages |
|---|---:|---:|
| total | 1.32 ms | 23.5 ms (424k msg/s) |
| kernel time | 0.11 ms | 3.2 ms |
| rounds | 3 (accounts, storage, done) | 3, then 2 more for a 183-lane tail |
| per-round table upload | 0.37 ms | 1.5–1.8 ms |
| per-round `LaneCtl` download | 0.01 ms | 1.3 ms (all 9,817 lanes × 216 B) |

1. **Whole-table uploads every round.** `sync_tables` re-sent all account, slot and block-hash
   tables (≈ 670 KB at their minimum size) whenever the host added one entry, and every batch
   started by re-sending them. That was 85% of a single message's time.
2. **Every batch started cold.** The tables lived in `fevm_batch`; reth, geth and Besu create a
   batch per message, so contract code and accounts were fetched and uploaded again each time.
3. **Full control-block download** of every lane, every round.
4. **Tail sub-batch.** With 1 MB arenas only 9,817 lanes fit, so 10,000 messages ran as
   9,817 + 183, and the 183 repeated every round on their own.
5. **No overlap.** The GPU idled while the host answered requests, and the host idled while the
   kernel ran.

## What changed

* **Engine-level state cache** (`src/runtime/state_cache.{hpp,cpp}`). The account, slot and
  block-hash tables and a code region (code plus jumpdest bitmaps, addressed by `LOC_CODE`) belong
  to the engine and stay resident in device memory across batches.
  * Code is keyed by code hash and is always reused.
  * Accounts, slots and block hashes are reused while batches declare the same state id
    (`fevm_batch_set_state_id`). A batch without an id, or with another one, bumps the cache epoch:
    every entry of the old epoch reads as empty on host and device, with nothing to clear or upload.
  * `fevm_batch_commit(new_id)` applies the batch's diffs to the cache (when the client committed
    them in lane order), so chained batches stay warm. It drops accounts and slots instead when it
    cannot follow the diffs (fallback lanes, created or destroyed accounts, cleared storage).
  * Host warm flags (`use_host_warm_flags`) are per batch: an entry cached by an earlier batch is
    re-requested for such lanes, so access-list status never leaks between batches.
  * LRU: lanes stamp each base-table hit with the batch number; when the cache exceeds
    `fevm_config.state_cache_bytes` (default 512 MiB) the engine pulls the stamps from the device
    and keeps the most recently used entries and the code they run.
* **Delta uploads.** The host records which entries changed; the GPU backend copies just those
  (one staged copy plus a scatter kernel). A full upload happens only after a rehash or eviction.
* **Compact round download.** Each lane writes a 104-byte `CtlEvent` (its request, or its
  outcome) next to the kernel's active list; the host downloads those instead of `LaneCtl`.
* **Equal loads and two overlapping lane groups.** Lanes are split into equal loads (no tail).
  From 4,096 lanes, two groups on two streams alternate, so one group's host fetches and result
  download overlap the other group's kernel. Loads hold about 2,560 lanes per group
  (`FASTEVM_LOAD_LANES` overrides), which measured best for erc20 at N = 10,000. Device tables are
  only written while no kernel runs, so a lane never reads a half-written entry.
* Smaller host-side costs: fixed-size request dedupe keys instead of `std::string`, result vectors
  reused across lanes, per-batch blob separate from the persistent cache.

## Results

erc20_transfer on the GPU (cold = no state id, so accounts are fetched every batch but code is
cached; warm = same state id, accounts and slots come from device memory):

| | before | cold | warm | reth+JIT |
|---|---:|---:|---:|---:|
| 1 message | 1.32 ms | 0.23 ms | 0.14 ms (1 round) | 1.2 µs |
| N = 64, msg/s | 40.8k | 128.5k | 179.1k | 635.7k |
| N = 1,000, msg/s | 329k | 577k | 894k | 3.20M |
| N = 10,000, msg/s | 435k | 973k | 1.21M | 4.50M |

Every batch row of workload B is now at least as fast as before on the GPU (cold); keccak_loop at
N = 10,000 is 4.0× reth+JIT cold and 4.9× warm. Other effects:

| | before | after |
|---|---:|---:|
| geth state tests Cancun–Osaka, GPU | 148.6 s | 39.0 s |
| reth ef-tests, GPU | 436.3 s | 133.3 s |
| reth block import, erc20 chain, fastevm CPU | 2.45 Ggas/s | 4.34 Ggas/s |
| reth block import, erc20 chain, fastevm GPU | 0.03 Ggas/s | 0.17 Ggas/s |

The CPU block-import gain comes from no longer allocating and clearing ≈ 650 KB of tables per
transaction. Compliance is unchanged: reth ef-tests 60/60, geth Cancun–Osaka 83,149/83,149 and
Besu 83,367/83,367 on the GPU backend, with the same fastevm and fallback counters as before.

**erc20 still loses to reth+JIT** (0.22× cold, 0.27× warm at N = 10,000). The next section is why.

## Remaining bottlenecks (proposals)

Warm erc20 at N = 10,000 (8.5 ms): kernels 4.6 ms in total (≈ 1.0 ms per 2,500-lane load),
result download 3.0 ms (four 1.34 MB pools at ≈ 1.8 GB/s), calldata upload 0.66 ms (720 KB).

1. **Result traffic.** An erc20 result is 536 bytes (pack header, two slot diffs, a 3-topic log,
   account diffs, output). Proposal: a compact encoding (omit unchanged code hashes and zero
   words, varint lengths, log topics by reference to calldata), and a "diff-only" mode for clients
   that do not need logs. Expected: about 2× less download.
2. **PCIe Gen3 ×4 ceiling.** About 600 bytes cross the link per transfer (72 in, 536 out), so the
   link alone caps erc20 at roughly 5–6M msg/s, the same order as reth+JIT's 4.5M. Even with an
   ideal kernel the GPU cannot clearly win erc20 on this link. Proposal: measure on a ×16 slot
   (Gen4 ×16 is about 9× this link) before investing further in erc20 on GPU.
3. **Kernel time per message** (≈ 0.4 µs of GPU time per erc20 lane). Each lane runs the full
   message prologue (warming sender, recipient, coinbase and precompiles; nonce and balance
   checks) through the generic interpreter. Proposal: profile with Nsight Compute (not installed
   here) and specialise the prologue; keep hot dispatch state in registers.
4. **reth per-transaction import** stays far from reth (0.17 vs 5.4 Ggas/s), because each
   transaction is still its own batch with at least one launch and sync, and reth writes gas fees
   outside the frame, so the cache cannot be committed through. Proposal: the BLOCK-mode scheduler
   (`docs/integration.md`), where the engine owns the block's state overlay and can commit through
   the cache by itself.
5. **Launch and sync overhead for tiny batches** (one message: ≈ 25 µs per round of waits).
   Proposal: a CUDA graph per round, or a persistent kernel that polls a doorbell in mapped memory.
6. **Compute-heavy programs** (arith, blake2b, snailtracer, weierstrudel) are unchanged by the
   cache, as expected: they are bound by divergence and 256-bit arithmetic in the interpreter, where
   evm2's JIT is 10–80× faster. Proposal: unchanged from `bench/report.md`; the GPU only wins on
   keccak-bound code.
7. **Two groups below 4,096 lanes** serialise on state uploads (a group's upload waits for the
   other group's kernel), which halved compute-heavy batches of 1,000 in a first version; hence the
   threshold. Proposal: double-buffered device tables, so uploads never wait for a running kernel.

## Kernel occupancy (lane blocks of 32)

Measured on the same machine; `fastevm-run --backend gpu --warm`, best of 5.

**Where the time goes.** One lane costs about 600 cycles per EVM step at 2.8 GHz (arith_loop at
N = 1: 400k steps in 87 ms). Even a JUMPDEST costs about 350: the 256-way opcode `switch` compiles
to an eight-level compare-and-branch tree, not a jump table, and one warp cannot hide that latency.
The GPU only pays off with many warps per SM. `lane_kernel` uses 168 registers, so an SM holds
3 blocks of 128 lanes (12 warps). But a load of 1,000 lanes in blocks of 128 is 8 blocks, so
26 of the 34 SMs sit idle, and a 2,500-lane overlap load fills only 20 SMs.

**Change.** `lane_kernel` now runs in blocks of 32 (`kLaneBlock`). Registers still bound occupancy
to 12 warps per SM, so nothing is lost, and every load spreads over every SM.

| program | N | before (msg/s) | after (msg/s) | change |
|---|---:|---:|---:|---:|
| snailtracer | 1k | 104 | 171 | +64% |
| arith_loop | 10k | 27.0k | 34.0k | +26% |
| blake2b_shifts | 1k | 542 | 629 | +16% |
| keccak_loop | 10k | 34.1k | 37.8k | +11% |
| erc20_transfer | 64 | 330 µs | 264 µs | −20% latency |
| erc20_transfer | 1k | 1081 µs | 959 µs | −11% latency |
| erc20_transfer | 10k | 1.20M | 1.20M | link-bound, unchanged |

**Tried and dropped.**
* *Inlining `exec()` into the kernel* (255 registers, 1.3 KB frame instead of 2.3 KB): no change.
* *Top of the operand stack in shared memory* (a ring of K items per lane; below the window, items
  stay in the interleaved global stack). A microbenchmark of the push/pop pattern is 9× faster on
  shared memory than on global memory at full occupancy. In the interpreter it loses, though. The
  shared window takes L1 capacity: shared memory and L1 are one 128 KB array per SM. With K = 8,
  a trivial loop at 13k lanes dropped to 14.7 Gsteps/s, against 29 without the window and 43 with
  K = 4. The window also turns every stack access into a generic load or store with a range
  select. With blocks of 32, K = 4 helps only arith_loop (+11%) and loses 5–7% on snailtracer,
  blake2b and keccak.

**Next for compute-bound code.** The step cost is latency inside one warp: the branch-tree
dispatch, generic loads of the code byte and `mem_size`, and 168 registers capping warps per SM.
Candidates, in order:
* a two-level dispatch, so the tree is not eight levels deep;
* fewer registers, by moving rare opcodes (CREATE/CALL setup, precompiles) out of line, for more
  warps per SM;
* PTX carry chains for 256-bit add and multiply.

Nsight Compute is installed but needs counter access (`RmProfilingAdminOnly=1`), so the
attributions above come from SASS inspection and timing experiments.
