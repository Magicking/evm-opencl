# fastevm benchmark report

Source: `bench/results/full_v3.json`. Interactive version: [benchmark dashboard](https://claude.ai/artifact/KW1MiCVBVH6AYJSp6Ktt5s).

Every benchmark is measured against the fastest client on this machine, **reth+JIT**, at 9.7× geth's speed across the single-message and batch workloads. Against it, fastevm's GPU backend wins only on keccak-bound code; the reference's JIT compiles 256-bit arithmetic to native code and outruns the GPU elsewhere. Block import through the per-message hook is slower than reth, because each message is its own batch: a gain needs the block-parallel mode (whole block per batch), which is designed but not built.

| | |
|---|---|
| cpu | AMD Ryzen 9 7940HS w/ Radeon 780M Graphics |
| cpu_threads | 16 |
| gpu | NVIDIA GeForce RTX 4060 Ti, 16380 MiB, 3, 4, 615.78.08 |
| platform | Linux-7.2.11-arch1-1-x86_64-with-glibc2.44 |
| reth_commit | 459b5a17c9 |
| geth_commit | b60c47dce |
| besu_commit | 9f835b4d4e |
| time | 2026-11-03T23:58:43.894536 |

## Reference client

**reth+JIT** — geomean over workloads A (1/latency) and B (msgs/s), relative to geth, over 62 rows.

| client | geomean speed vs geth |
|---|---:|
| reth+JIT | 9.69× |
| reth | 2.35× |
| geth | 1.00× |
| besu | 0.25× |

## A. Single-message latency (warm, one message)

reth: `rethbench --n 1` (evm2 at reth's pinned rev; JIT = contract compiled before timing); geth: `evm run --bench`; besu: `evmtool --repeat` / batch harness n=1; fastevm: `fastevm-run --batch 1`. GPU warm: every repeat names the same state id, so accounts and slots come from the engine's state cache in device memory instead of host rounds (code is cached in both GPU columns).

| program | gas | reth+JIT | reth | geth | besu | fastevm CPU | fastevm GPU | GPU warm | CPU vs reth+JIT | GPU warm vs reth+JIT |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| JUMPDEST_n0 | 527598 | 0.6 µs | 606.7 µs | 820.1 µs | 1.47 ms | 622.4 µs | 62.38 ms | 60.84 ms | 0.00× | 0.00× |
| arith_loop | 1440044 | 37.5 µs | 739.9 µs | 1.47 ms | 5.31 ms | 1.74 ms | 83.36 ms | 83.28 ms | 0.02× | 0.00× |
| blake2b_huff_0 | 13984 | 1.1 µs | 9.8 µs | 42.5 µs | 514.0 µs | 68.7 µs | 1.32 ms | 1.20 ms | 0.02× | 0.00× |
| blake2b_huff_1 | 879923 | 31.7 µs | 626.3 µs | 1.35 ms | 4.14 ms | 1.02 ms | 68.00 ms | 67.87 ms | 0.03× | 0.00× |
| blake2b_shifts | 12043105 | 498.8 µs | 5.86 ms | 14.20 ms | 36.91 ms | 9.93 ms | 403.92 ms (CPU retry) | 403.86 ms | 0.05× | 0.00× |
| erc20_transfer | 46231 | 1.2 µs | 1.2 µs | 11.9 µs | 14.1 µs | 3.9 µs | 228.7 µs | 143.0 µs | 0.29× | 0.01× |
| jump_around | 49153 | 1.4 µs | 20.2 µs | 64.4 µs | 729.9 µs | 179.2 µs | 2.66 ms | 2.52 ms | 0.01× | 0.00× |
| keccak_loop | 470038 | 1.04 ms | 1.17 ms | 624.0 µs | 2.59 ms | 1.68 ms | 45.01 ms | 44.92 ms | 0.62× | 0.02× |
| loop_with_many_jumpdests | 7987882 | 0.8 µs | 9.34 ms | 11.41 ms | 19.55 ms | 9.44 ms | 925.36 ms | 925.21 ms | 0.00× | 0.00× |
| memory_grow_mload_0 | 57356 | 3.8 µs | 39.9 µs | 106.0 µs | 851.0 µs | 127.9 µs | 4.88 ms | 4.75 ms | 0.03× | 0.00× |
| memory_grow_mload_1 | 57772 | 4.7 µs | 41.2 µs | 108.7 µs | 1.00 ms | 129.5 µs | 4.93 ms | 4.79 ms | 0.04× | 0.00× |
| memory_grow_mload_2 | 71700 | 16.1 µs | 56.6 µs | 162.7 µs | 1.69 ms | 143.5 µs | 5.44 ms | 5.30 ms | 0.11× | 0.00× |
| memory_grow_mload_3 | 102409 | 28.4 µs | 74.6 µs | 184.6 µs | 5.28 ms | 159.7 µs | 6.60 ms | 6.47 ms | 0.18× | 0.00× |
| memory_grow_mstore_0 | 61452 | 8.3 µs | 47.1 µs | 106.5 µs | 312.5 µs | 112.9 µs | 5.25 ms | 5.12 ms | 0.07× | 0.00× |
| memory_grow_mstore_1 | 61868 | 9.8 µs | 48.9 µs | 107.3 µs | 382.3 µs | 144.4 µs | 5.28 ms | 5.14 ms | 0.07× | 0.00× |
| memory_grow_mstore_2 | 75796 | 21.4 µs | 56.4 µs | 164.5 µs | 384.0 µs | 93.5 µs | 5.70 ms | 5.58 ms | 0.23× | 0.00× |
| memory_grow_mstore_3 | 106505 | 34.6 µs | 66.8 µs | 189.5 µs | 1.01 ms | 146.6 µs | 6.17 ms | 6.03 ms | 0.24× | 0.01× |
| sha1_divs_0 | 36454 | 2.8 µs | 28.9 µs | 74.0 µs | 1.10 ms | 90.6 µs | 4.24 ms | 4.14 ms | 0.03× | 0.00× |
| sha1_divs_1 | 3000286 | 174.4 µs | 2.33 ms | 4.34 ms | 20.31 ms | 4.34 ms | 293.86 ms | 293.77 ms | 0.04× | 0.00× |
| sha1_shifts_0 | 35234 | 2.7 µs | 20.6 µs | 58.5 µs | 1.00 ms | 38.6 µs | 2.40 ms | 2.30 ms | 0.07× | 0.00× |
| sha1_shifts_1 | 2898473 | 173.9 µs | 1.67 ms | 3.19 ms | 18.39 ms | 2.91 ms | 181.04 ms | 180.92 ms | 0.06× | 0.00× |
| signextend_0 | 96066 | 0.5 µs | 54.9 µs | 104.8 µs | 363.1 µs | 299.4 µs | 5.32 ms | 5.17 ms | 0.00× | 0.00× |
| signextend_1 | 96066 | 0.6 µs | 54.1 µs | 107.3 µs | 362.4 µs | 262.7 µs | 5.34 ms | 5.19 ms | 0.00× | 0.00× |
| snailtracer | 165962868 | 11.33 ms | 21.92 ms | 52.03 ms | 259.95 ms | 26.35 ms | 28.52 ms (CPU retry) | 31.87 ms | 0.43× | 0.36× |
| storage_rw | 2229870 | 8.4 µs | 12.5 µs | 120.4 µs | 119.8 µs | 28.4 µs | 1.12 ms | 1.03 ms | 0.29× | 0.01× |
| structarray_alloc | 1737676 | 141.7 µs | 457.8 µs | 1.92 ms | 3.31 ms | 644.2 µs | 51.10 ms | 46.64 ms | 0.22× | 0.00× |
| swap_math_0 | 3179 | 1.0 µs | 2.5 µs | 15.3 µs | 463.8 µs | 8.6 µs | 387.1 µs | 288.8 µs | 0.11× | 0.00× |
| swap_math_1 | 3505 | 1.1 µs | 2.7 µs | 15.4 µs | 469.6 µs | 14.3 µs | 412.6 µs | 320.3 µs | 0.08× | 0.00× |
| swap_math_2 | 2232 | 0.9 µs | 1.8 µs | 13.8 µs | 271.8 µs | 11.8 µs | 323.3 µs | 229.2 µs | 0.07× | 0.00× |
| weierstrudel_0 | 47561 | 76.9 µs | 90.8 µs | 178.2 µs | 6.27 ms | 178.0 µs | 8.69 ms | 9.42 ms | 0.43× | 0.01× |
| weierstrudel_1 | 598273 | 740.4 µs | 862.0 µs | 1.50 ms | 8.06 ms | 1.50 ms | 82.21 ms | 82.08 ms | 0.49× | 0.01× |

## B. Batch throughput (N independent messages, 16 threads for CPU engines)

Messages/second (median of runs). Ratios are fastevm against reth+JIT.

| program | N | reth+JIT | reth | geth | besu | fastevm CPU | fastevm GPU | GPU warm | GPU vs reth+JIT | GPU warm vs reth+JIT |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| erc20_transfer | 1 | 9.3k | 9.0k | 39.6k | 21.1k | 217.9k | 4.0k | 6.7k | 0.43× | 0.72× |
| erc20_transfer | 64 | 635.7k | 589.4k | 251.0k | 162.5k | 77.0k | 128.5k | 179.1k | 0.20× | 0.28× |
| erc20_transfer | 1000 | 3.20M | 3.39M | 536.7k | 189.2k | 535.8k | 577.2k | 894.2k | 0.18× | 0.28× |
| erc20_transfer | 10000 | 4.50M | 4.22M | 1.00M | 472.7k | 841.8k | 973.0k | 1.21M | 0.22× | 0.27× |
| arith_loop | 1 | 9.7k | 863 | 696 | 151 | 555 | 12 | 12 | 0.00× | 0.00× |
| arith_loop | 64 | 107.7k | 7.9k | 4.9k | 759 | 6.0k | 686 | 694 | 0.01× | 0.01× |
| arith_loop | 1000 | 159.3k | 9.0k | 4.7k | 776 | 6.3k | 9.5k | 9.5k | 0.06× | 0.06× |
| arith_loop | 10000 | 209.3k | 11.7k | 5.0k | 777 | 6.9k | 23.4k | 26.5k | 0.11× | 0.13× |
| keccak_loop | 1 | 646 | 828 | 1.8k | 306 | 586 | 22 | 22 | 0.03× | 0.03× |
| keccak_loop | 64 | 7.0k | 6.5k | 6.9k | 2.5k | 4.0k | 1.0k | 1.0k | 0.15× | 0.15× |
| keccak_loop | 1000 | 7.0k | 6.0k | 7.8k | 2.8k | 4.2k | 12.8k | 13.1k | 1.83× | 1.87× |
| keccak_loop | 10000 | 7.0k | 6.4k | 8.8k | 3.0k | 4.9k | 28.0k | 34.1k | 3.99× | 4.85× |
| storage_rw | 1 | 12.1k | 13.9k | 7.3k | 7.2k | 53.3k | 969 | 1.1k | 0.08× | 0.09× |
| storage_rw | 64 | 417.7k | 293.8k | 69.4k | 64.9k | 51.1k | 15.8k | 16.4k | 0.04× | 0.04× |
| storage_rw | 1000 | 682.4k | 528.1k | 75.6k | 55.4k | 94.7k | 55.3k | 57.3k | 0.08× | 0.08× |
| storage_rw | 10000 | 1.09M | 740.2k | 87.0k | 60.7k | 91.2k | 85.6k | 90.1k | 0.08× | 0.08× |
| swap_math_0 | 1 | 9.0k | 15.7k | 44.0k | 30.2k | 53.7k | 2.6k | 3.4k | 0.28× | 0.37× |
| swap_math_0 | 64 | 771.3k | 624.4k | 196.9k | 205.1k | 65.2k | 108.1k | 139.2k | 0.14× | 0.18× |
| swap_math_0 | 1000 | 3.33M | 3.01M | 637.7k | 302.4k | 590.5k | 610.7k | 935.2k | 0.18× | 0.28× |
| sha1_divs_0 | 1 | 19.0k | 8.8k | 10.4k | 5.5k | 10.4k | 236 | 241 | 0.01× | 0.01× |
| sha1_divs_0 | 64 | 451.9k | 142.0k | 69.0k | 26.1k | 49.7k | 12.9k | 13.3k | 0.03× | 0.03× |
| sha1_divs_0 | 1000 | 2.30M | 192.3k | 107.5k | 25.6k | 144.8k | 154.5k | 172.2k | 0.07× | 0.07× |
| blake2b_shifts | 1 | 1.1k | 164 | 74 | 26 | 99 | 2 | 2 | 0.00× | 0.00× |
| blake2b_shifts | 64 | 4.8k | 1.5k | 186 | 119 | 855 | 68 | 68 | 0.01× | 0.01× |
| blake2b_shifts | 1000 | 4.9k | 1.5k | 218 | 119 | 978 | 780 | 779 | 0.16× | 0.16× |
| weierstrudel_0 | 1 | 3.7k | 6.7k | 3.9k | 929 | 3.2k | 116 | 117 | 0.03× | 0.03× |
| weierstrudel_0 | 64 | 127.9k | 69.1k | 38.9k | 7.5k | 33.1k | 6.2k | 6.3k | 0.05× | 0.05× |
| weierstrudel_0 | 1000 | 108.0k | 79.9k | 50.0k | 7.7k | 58.8k | 74.1k | 77.8k | 0.69× | 0.72× |
| snailtracer | 1 | 87 | 44 | 19 | 4 | 37 | 0 | 0 | 0.01× | 0.01× |
| snailtracer | 64 | 832 | 372 | 112 | 28 | 326 | 19 | 19 | 0.02× | 0.02× |
| snailtracer | 1000 | 822 | 378 | 104 | 30 | 318 | 104 | 104 | 0.13× | 0.13× |

## C. Block import (reth `re-execute --num-tasks 1`, synthetic Osaka chains)

Chains from `bench/makechain` (go-ethereum `GenerateChain`, 60M-gas blocks), imported into reth, then re-executed in order against parent state with receipt validation. fastevm runs every top-level frame through reth's evm2 `InterpreterRunner` hook, **one message per batch**.

| chain | txs | reth | reth+JIT | fastevm CPU | fastevm GPU | CPU vs reth+JIT | frames on fastevm |
|---|---:|---:|---:|---:|---:|---:|---|
| erc20 | 41872 | 5.74 Ggas/s | 5.40 Ggas/s | 4.34 Ggas/s | 0.17 Ggas/s | 0.80× | fastevm: executed=40845 fallbacks=0 skipped=0 |
| erc20_hot50 | 50411 | 5.88 Ggas/s | 5.67 Ggas/s | 4.21 Ggas/s | 0.15 Ggas/s | 0.74× | fastevm: executed=49143 fallbacks=0 skipped=0 |
| mixed | 9717 | 2.17 Ggas/s | 6.14 Ggas/s | 0.61 Ggas/s | 0.02 Ggas/s | 0.10× | fastevm: executed=9640 fallbacks=0 skipped=0 |

## D. Compliance-suite runtime

| suite | engine | wall time | pass | fail | engine counters |
|---|---|---:|---:|---:|---|
| reth ef-tests | reth_native | 46.4 s | 60 | 0 |  |
| reth ef-tests | fastevm_cpu | 47.5 s | 60 | 0 | fastevm: executed=102225 fallbacks=74 skipped=10919 |
| reth ef-tests | fastevm_gpu | 133.3 s | 60 | 0 | fastevm: executed=102225 fallbacks=74 skipped=10919 |
| geth state tests Cancun..Osaka | geth_native | 9.0 s | 83149 | 0 |  |
| geth state tests Cancun..Osaka | fastevm_cpu | 10.0 s | 83149 | 0 | fastevm: executed=38209 fallbacks=66 skipped(fork)=0 fallback-errors=map[17:66] |
| geth state tests Cancun..Osaka | fastevm_gpu | 39.0 s | 83149 | 0 | fastevm: executed=38209 fallbacks=66 skipped(fork)=0 fallback-errors=map[17:66] |

## Compliance runs

"Client's own" counts failures the client also has without fastevm (two Cancun→Prague system-contract deployment tests fail on reth natively). "On fastevm" counts top-level messages the engine ran; fallbacks went back to the client's EVM.

| suite | backend | tests | failures | client's own | on fastevm | fallbacks |
|---|---|---:|---:|---:|---:|---:|
| reth ef-tests (ethereum/tests v17 + EEST v4.5.0, 60 groups) | CPU | 60 | 0 | 0 | 102,225 | 74 |
| reth ef-tests (ethereum/tests v17 + EEST v4.5.0, 60 groups) | GPU | 60 | 0 | 0 | 102,225 | 74 |
| reth blockchain tests, tests@v21.0.1 Cancun-Osaka (ef-test-runner) | CPU | 7,290 | 2 | 2 | 209,629 | 67 |
| reth blockchain tests, tests@v21.0.1 Cancun-Osaka (ef-test-runner) | GPU | 7,290 | 2 | 2 | 209,629 | 67 |
| geth TestExecutionSpecState (all forks, 4 permutations) | CPU | 421,173 | 0 | 0 | 152,836 | 264 |
| geth TestExecutionSpecState (Cancun-Osaka) | CPU | 83,149 | 0 | 0 | 38,209 | 66 |
| geth TestExecutionSpecState (Cancun-Osaka) | GPU | 83,149 | 0 | 0 | 38,209 | 66 |
| geth TestExecutionSpecBlocktests (Cancun-Osaka + transitions) | CPU | 50,067 | 0 | 0 | 582,575 | 706 |
| besu ExecutionSpecStateTest (all forks) | CPU | 83,367 | 0 | 0 | 38,209 | 66 |
| besu ExecutionSpecStateTest (all forks) | GPU | 83,367 | 0 | 0 | 38,209 | 66 |

Total: 818,972 tests, 0 failures caused by fastevm.

