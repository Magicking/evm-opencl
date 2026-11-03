# fastevm on an FPGA (1–10 EVM cores): requirements and board proposal

Status: **proposal**. No hardware bought, no RTL written. Board figures cite vendor or distributor
pages; engine and benchmark figures cite files in this repo. Scope: a design with **1 to 10 EVM
cores**. Performance and resource figures for the FPGA are estimates from the model below, not
measurements. Formatted version with charts and diagram:
[fastevm FPGA proposal: 1–10 EVM cores](https://claude.ai/artifact/G2SapkqaKJJiaVcHXpygvg).

**Answer.** Recommended board: **ALINX AXKU15** (Kintex UltraScale+ KU15P, PCIe Gen3 ×16,
£4,918). It fits all 10 cores with 4-round Keccak units. Budget board: **ALINX AXKU5** (KU5P,
£1,026, free Vivado). It fits about 5 cores. At this size the FPGA is a correctness and measurement
prototype. It is expected to beat reth+JIT only on keccak-heavy work (about 2× with 10 cores) and
to roughly match it on MULMOD-heavy work. It loses 10–80× on general compute.

## Why an FPGA

The CUDA backend is compliant on geth, besu and reth, but against the reference client
(reth + evm2 JIT, `bench/results/reference.json`) it wins only where the work is hashing:

| workload B (largest N, msgs/s, `bench/results/full_v2.json`) | N | reth+JIT | fastevm GPU | GPU vs reference |
|---|---:|---:|---:|---:|
| keccak_loop | 10k | 7.0k | 28.0k | **4.0×** |
| weierstrudel | 1k | 108.0k | 61.7k | 0.57× |
| blake2b_shifts | 1k | 4.9k | 778 | 0.16× |
| snailtracer | 1k | 822 | 104 | 0.13× |
| arith_loop | 10k | 209.3k | 21.7k | 0.10× |
| erc20_transfer | 10k | 4.50M | 435k | 0.10× |
| storage_rw | 10k | 1.09M | 58.4k | 0.05× |

Block import through reth (workload C) is slower with the GPU (0.01–0.03 Ggas/s vs 2.2–6.1).
The GPU loses for three reasons, and an FPGA can address each of them:

1. **SIMT divergence.** Lanes run different opcodes and branches, so a warp serialises. An FPGA
   design can give each lane, or each small group of lanes, its own core.
2. **Latency.** Each opcode costs a dispatch through a large switch with global-memory traffic. An
   FPGA core executes a typical opcode in 1–3 cycles out of on-chip RAM.
3. **Host link.** The current GPU sits behind PCIe Gen3 ×4 (about 3.5 GB/s), and state fetches are
   host rounds. Even a mid-range FPGA card has Gen3 ×8 or ×16, and the latency of a doorbell write is under the designer's control.

Hashing already wins on the GPU. On an FPGA, each core can own a Keccak-f[1600] unit.

## What 1–10 cores can do (estimate)

Model: one core at 300 MHz averaging 2 cycles per opcode, which is 150M opcodes/s, or about
0.5 Ggas/s on compute code (about 3.3 gas per opcode). A Keccak unit doing 4 rounds per cycle
needs 6 cycles per permutation. keccak_loop then takes about 0.69 ms per message: 5,000 × (6 cycles
of Keccak + about 17 loop opcodes). Ten cores run ten messages at once. The reth+JIT figures are
measured: workload A on 1 thread, workload B on 16 threads (`bench/results/full_v2.json`).

| program | gas | reth+JIT, 1 msg | FPGA core, 1 msg (est.) | 1 core vs reth+JIT | reth+JIT, msgs/s (16 threads) | 10 cores, msgs/s (est.) | 10 cores vs reth+JIT |
|---|---:|---:|---:|---:|---:|---:|---:|
| keccak_loop | 470,038 | 1,039.3 µs | 690 µs | 1.51× | 7,025 | 14,493 | 2.06× |
| weierstrudel_0 | 47,561 | 76.9 µs | 95 µs | 0.81× | 108,018 | 105,128 | 0.97× |
| blake2b_shifts | 12,043,105 | 498.8 µs | 24,086 µs | 0.02× | 4,895 | 415 | 0.08× |
| snailtracer | 165,962,868 | 11,325.6 µs | 331,926 µs | 0.03× | 822 | 30 | 0.04× |
| arith_loop | 1,440,044 | 37.5 µs | 2,880 µs | 0.01× | 209,332 | 3,472 | 0.02× |

* **Keccak** is the one clear win. One core is about 1.5× per message and ten cores about 2× in
  throughput. With single-round Keccak units (the AXKU5 budget) a message takes about 0.98 ms, so
  one core is only about 1.06×. The GPU does 4.0× on this program, so ten cores do not beat the GPU here.
* **MULMOD-heavy code** (weierstrudel) is at about parity, and a hardware modular multiplier
  would push it above 1×. The GPU gets 0.57× here.
* **General compute** (arith, blake2b, snailtracer) loses 10–80×. A 300 MHz core does about
  4× fewer opcodes per second than reth's *interpreter* on one CPU thread (arith_loop: 0.74 ms), and
  the JIT is another 20× faster than that.
* **ERC20 and storage** are bound by host state fetches, not compute. A PCIe round trip (about
  1–2 µs) alone is as long as reth+JIT's whole ERC20 transfer (1.16 µs).

So with 1–10 cores the FPGA is useful to (1) validate a hardware EVM core bit-for-bit against the
existing suites, (2) measure real per-core speed and PCIe round-trip latency, and (3) prove the
Keccak and MULMOD units. Beating reth+JIT broadly needs on the order of 100+ cores (see the earlier
V80 analysis below) together with BLOCK mode.

## Requirements (1–10 cores)

| # | Requirement | 1 core | 10 cores | Derived from |
|---|---|---|---|---|
| R1 | Host link | PCIe Gen3 ×4 | PCIe Gen3 ×8 or ×16 | Ten cores move little data: lane input and output plus state answers. What matters is doorbell round-trip latency (target ≤ 2 µs), not bandwidth |
| R2 | Card memory | 512 MB DDR4 | ≥ 1 GB DDR4 | 4–8 lanes per core × 4 MiB arena (`lane_arena_bytes` default); 10 cores × 8 lanes = 320 MB. HBM is not needed |
| R3 | On-chip RAM | ≥ 0.5 MB | ≥ 4 MB | Per core: 4–8 resident lane stacks × 32 KB (`STACK_LIMIT` 1024 × 32 B) plus about 128 KB of code, jumpdest and state caches |
| R4 | DSP | ≥ 100 | ≥ 300 (≥ 1,000 for one multiplier per core) | One pipelined 256×256 multiplier for MUL/MULMOD/EXP is about 64–100 DSP; shared by up to 4 cores |
| R5 | Logic | ≥ 90k LUT | ≥ 330k LUT (single-round Keccak) or ≥ 490k (4-round Keccak) | LUT = (N × (core + Keccak) + ⌈N/4⌉ × 10k + 40k shell) / 0.8; see Rough sizing |
| R6 | Clock | 250 MHz | 300 MHz | Sets per-core speed in the model above |
| R7 | Toolchain | Free vendor tools preferred | | Vivado ML Standard (free) covers KU3P/KU5P only; KU15P needs Vivado Enterprise |
| R8 | Host | Any desktop with a free ×8/×16 slot | | Mid-range cards draw tens of watts (AXKU5 is about 12 W); no server chassis needed |
| R9 | Budget | about £1k | about £5k | |

The precompile split is unchanged. sha256, ripemd160, identity and blake2f run in-lane as small
units. ecrecover, modexp, bn254, KZG, BLS12-381 and P-256 stay on the host callback.

## Candidate boards

| | **ALINX AXKU15** (recommended) | **ALINX AXKU5** (budget) | AMD KCU116 | Altera Agilex 5 E-Series 065B modular kit |
|---|---|---|---|---|
| Device | XCKU15P-2FFVE1517I | XCKU5P-2FFVB676I | XCKU5P-2FFVB676E | A5E065B |
| Logic | 522,720 LUT | 216,960 LUT | 216,960 LUT | 656,080 LE (222,400 ALM) |
| DSP | 1,968 | 1,824 | 1,824 | not verified |
| On-chip RAM | 984 × 36 Kb BRAM + 128 URAM (about 9 MB) | 480 × 36 Kb BRAM + 64 URAM (about 4.5 MB) | same as AXKU5 | 1,611 M20K, 31.46 Mb (about 3.9 MB) |
| Card memory | DDR4, 10,240 Mb, 80-bit | DDR4, 32-bit (2 GB per one listing, 2 Gb per another) | 1 GB DDR4 component, 32-bit | 3 × 8 GB DDR4 (one for the Arm HPS) |
| Host link | PCIe Gen3 ×16 | PCIe Gen3 ×8 | PCIe Gen3 ×8 (Gen4 with custom IP) | PCIe Gen4 ×4 (×16 edge) |
| Cores that fit (est.) | 10, with 4-round Keccak | about 5 (single-round Keccak) | about 5 | about 10 (ALM-to-LUT ratio unverified) |
| Tools | Vivado Enterprise (paid) | Vivado ML Standard (free) | Vivado ML Standard (free) | Quartus Prime Pro (check licence) |
| Price | £4,917.99 | £1,025.99 | $6,495 list (AMD) | €2,257.55 ex VAT (DigiKey) |
| Availability | quote | quote | about 8 weeks (AMD) | DigiKey 11 weeks; Altera page says product preview |

## Recommendation

* **10 cores: ALINX AXKU15.** It is the only candidate with room for all 10 cores plus 4-round
  Keccak units (about 490k of 523k LUT at 80% utilization is tight but inside), about 9 MB on-chip
  RAM and a Gen3 ×16 slot card. Budget a Vivado Enterprise licence on top.
* **1–5 cores, or as a first step: ALINX AXKU5.** About £1k with the free Vivado edition. It is
  enough for phases 1–3 (one core, round-trip latency, Keccak unit). Move to the AXKU15 only if the
  measured per-core speed matches the model.
* **KCU116** has the same chip as the AXKU5 at about 6× the price. Choose it only for AMD's
  reference designs and support.
* **Agilex 5 modular kit** is the cheapest route to 10 cores on paper, with Gen4 ×4 and 24 GB of
  DDR4. Its DSP count is unverified and its availability is unclear (Altera lists it as a preview),
  so it is a fallback.

Beyond 10 cores the earlier analysis still holds: AMD Alveo V80 (2.57M LUT, 32 GB HBM2e, about
110–120 cores, $9,495).

## Architecture sketch

```
 host (geth / besu / reth) ── C ABI (include/fastevm.h) ── src/runtime fpga backend
                                                              │  PCIe Gen3 ×16 / ×8 (DMA + MMIO doorbell)
 ┌──────────────────────────── FPGA (KU15P / KU5P) ───────────┴────────────────────────┐
 │ batch DMA engine ── lane scheduler (ready / parked-on-fetch / done queues)           │
 │ EVM core × 1–10: fetch/decode, 256-bit ALU, 4–8 lane stacks in URAM/BRAM,           │
 │                  own Keccak-f[1600] unit, code / account / slot caches              │
 │ shared: MUL/MULMOD/EXP (1 per 4 cores), DIV/MOD, sha256/ripemd160/blake2f           │
 │ DDR4: lane arenas (LaneLayout from src/evm/types.cuh), memory, journals, logs        │
 └──────────────────────────────────────────────────────────────────────────────────────┘
```

* The host protocol is unchanged. A lane that needs state parks; the host answers the round
  (`src/runtime/batch.hpp`); the lane resumes.
* The CPU backend stays the oracle. Unsupported cases return `FEVM_ERR_RESOURCES` and re-run on
  the CPU, as the GPU's `cpu_retried_lanes` do.

## Rough sizing (estimates; phase 2 synthesizes one core to replace them)

| Block | LUT each | Basis |
|---|---:|---|
| 256-bit add/sub/compare (ADD, SUB, LT/GT/SLT/EQ, ISZERO) | about 1k | about 1 LUT per bit per carry chain |
| AND/OR/XOR/NOT, BYTE, SIGNEXTEND | about 1k | 256-bit logic plus byte select |
| 256-bit barrel shifter (SHL/SHR/SAR) | about 2–3k | 4 stages of 4:1 mux per LUT6 × 256 bits |
| Operand muxes, stack-top registers, writeback | about 1–2k | 256-bit buses with 3–4 sources |
| Decode, PC, 64-bit gas and memory-expansion cost, control | about 2–3k | |
| Memory port (unaligned 32-byte rotate) | about 1k | |
| **One EVM core** | **about 8–12k** | |
| Keccak-f[1600], 1 round/cycle | about 5–8k | 24 cycles per permutation |
| Keccak-f[1600], 4 rounds/cycle | about 15–20k | 6 cycles per permutation |
| 256×256 multiplier | about 5–10k | plus 64–100 DSP |
| Shell: PCIe DMA (XDMA) and DDR4 controller | about 30–50k | no HBM |

LUT = (N × (12k core + Keccak) + ⌈N/4⌉ × 10k + 40k) / 0.8, keeping utilization ≤ 80%:

| cores | single-round Keccak (7k) | 4-round Keccak (20k) |
|---:|---:|---:|
| 1 | about 86k | about 103k |
| 5 | about 194k | about 275k |
| 10 | about 325k | about 488k |

On-chip RAM for 10 cores: 10 × 8 lanes × 32 KB = 2.5 MB of stacks plus about 1.3 MB of caches,
about 3.8 MB. DDR4: 10 × 8 × 4 MiB = 320 MB.

## Prototype phases

1. **Model.** Cycle-level C++ model of one core, sharing opcode semantics with
   `src/evm/interpreter.cuh`, checked against `tests/test_interpreter.cpp` and the 2,000-program fuzz.
2. **RTL in simulation.** Verilator, same tests, bit-exact on `bench/corpus`. Synthesize one core to
   replace the LUT estimates.
3. **One core on the AXKU5.** XDMA, doorbell, measure the round trip; then keccak_loop and
   arith_loop to measure real per-core speed against the model.
4. **1–10 cores plus the round protocol.** `fpga` backend in `src/runtime/engine.cpp`; geth, besu
   and reth suites with `FASTEVM_BACKEND=fpga`, gate 0 failures.
5. **Benchmarks.** Workloads A, B, C and R against reth+JIT.

## Open questions

* Does one synthesized core land inside 8–12k LUT, and does it close timing at 300 MHz?
* What is the measured PCIe doorbell round trip on Gen3 ×8?
* Is a hardware MULMOD unit enough to take weierstrudel-style code above reth+JIT?
* Does the KU15P project justify a Vivado Enterprise licence, or is the Agilex 5 kit available in time?

## Sources

* ALINX AXKU15: [fpgadeveloper board page](https://boards.fpgadeveloper.com/boards/AXKU15)
* ALINX AXKU5: [fpgadeveloper board page](https://boards.fpgadeveloper.com/boards/AXKU5),
  [retailer listing (Gen3 ×8, 2 GB DDR4, 12 W)](https://serverflow.ru/catalog/komplektuyushchie/uskoriteli-vychisleniy-fpga-asic/karta-uskoritelya-dlya-setevykh-prilozheniy-alinx-axku5-v1-1/)
* AMD KCU116: [product page](https://www.amd.com/en/products/adaptive-socs-and-fpgas/evaluation-boards/ek-u1-kcu116-g.html),
  [DigiKey](https://www.digikey.com/en/products/detail/amd/EK-U1-KCU116-G/7035246)
* XCKU5P resources: [ALINX ACKU5 (fpgadeveloper)](https://boards.fpgadeveloper.com/soms/ACKU5)
* Altera Agilex 5 E-Series 065B modular kit: [product page](https://www.altera.com/products/devkit/po-3274/agilex-5-fpga-and-soc-e-series-065b-modular-development-kit),
  [Mouser](https://www.mouser.in/en/new/altera/altera-mk-a5e065bb32aea-dev-kit/),
  [DigiKey](https://www.digikey.be/en/products/detail/altera/MK-A5E065AB32AEA/29190478),
  [E-Series table (Macnica)](https://stg-publish.macnica.com/americas/mai/en/products/semiconductors/altera/agilex/altera-agilex-5-fpga-and-soc-overview.html)
* Vivado edition device support: [UG973 Supported Devices](https://docs.amd.com/r/en-US/ug973-vivado-release-notes-install-license/Supported-Devices)
* Larger-scale option: [AMD Alveo V80](https://www.amd.com/en/products/accelerators/alveo/v80/a-v80-p64g-pq-g.html),
  [DS1013](https://docs.amd.com/r/en-US/ds1013-v80/Product-Details)
* fastevm benchmarks: `bench/results/full_v2.json`, `bench/report.md`, and the
  [benchmark dashboard](https://claude.ai/artifact/KW1MiCVBVH6AYJSp6Ktt5s)
