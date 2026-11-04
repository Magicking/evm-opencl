#!/usr/bin/env python3
"""Renders bench/results/<file>.json (from bench/run.py) as Markdown.

Every table puts the reference client first (the globally fastest client, picked by run.py and
stored under "reference") and expresses fastevm against it.

Usage: bench/report.py [results.json] > bench/report.md
"""
import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LABEL = {"reth": "reth", "reth_jit": "reth+JIT", "geth": "geth", "besu": "besu",
         "fastevm_cpu": "fastevm CPU", "fastevm_gpu": "fastevm GPU"}
DASHBOARD = "https://claude.ai/artifact/KW1MiCVBVH6AYJSp6Ktt5s"


def us(x):
    if x is None:
        return "–"
    if x >= 1:
        return "%.2f s" % x
    if x >= 1e-3:
        return "%.2f ms" % (x * 1e3)
    return "%.1f µs" % (x * 1e6)


def rate(x):
    if not x:
        return "–"
    if x >= 1e6:
        return "%.2fM" % (x / 1e6)
    if x >= 1e3:
        return "%.1fk" % (x / 1e3)
    return "%.0f" % x


def ratio(a, b):
    return ("%.2f×" % (a / b)) if a and b else "–"


def failed(d):
    # Harness failures carry an "error" string; fastevm-run's numeric "error" is the EVM error code.
    return not isinstance(d, dict) or isinstance(d.get("error"), str) or "skipped" in d


def get(d, k):
    return None if failed(d) else d.get(k)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "results", "full_v2.json")
    r = json.load(open(path))
    m = r["machine"]
    ref = r.get("reference", {}).get("reference", "geth")
    others = [c for c in ("reth", "reth_jit", "geth", "besu") if c != ref]
    print("# fastevm benchmark report\n")
    print("Source: `%s`. Interactive version: [benchmark dashboard](%s).\n" % (
        os.path.relpath(path, os.path.dirname(HERE)), DASHBOARD))
    if "reference" in r and "B" in r:
        print("Every benchmark is measured against the fastest client on this machine, **%s**, at %.1f× "
              "geth's speed across the single-message and batch workloads. Against it, fastevm's GPU "
              "backend wins only on keccak-bound code; the reference's JIT compiles 256-bit arithmetic "
              "to native code and outruns the GPU elsewhere. Block import through the per-message hook "
              "is slower than reth, because each message is its own batch: a gain needs the "
              "block-parallel mode (whole block per batch), which is designed but not built.\n" % (
                  LABEL[ref], r["reference"]["geomean_vs_geth"][ref]))
    print("| | |\n|---|---|")
    for k in ("cpu", "cpu_threads", "gpu", "platform", "reth_commit", "geth_commit", "besu_commit", "time"):
        if k in m:
            print("| %s | %s |" % (k, m[k]))
    print()
    if "reference" in r:
        sc = r["reference"]["geomean_vs_geth"]
        print("## Reference client\n")
        print("**%s** — %s, over %d rows.\n" % (LABEL[ref], r["reference"]["rule"], r["reference"]["rows"]))
        print("| client | geomean speed vs geth |\n|---|---:|")
        for c, v in sorted(sc.items(), key=lambda kv: -kv[1]):
            print("| %s | %.2f× |" % (LABEL[c], v))
        print()
    cols = [ref] + others
    if "A" in r:
        print("## A. Single-message latency (warm, one message)\n")
        print("reth: `rethbench --n 1` (evm2 at reth's pinned rev; JIT = contract compiled before timing); geth: "
              "`evm run --bench`; besu: `evmtool --repeat` / batch harness n=1; fastevm: `fastevm-run --batch 1`. "
              "GPU warm: every repeat names the same state id, so accounts and slots come from the engine's "
              "state cache in device memory instead of host rounds (code is cached in both GPU columns).\n")
        print("| program | gas | %s | fastevm CPU | fastevm GPU | GPU warm | CPU vs %s | GPU warm vs %s |" % (
            " | ".join(LABEL[c] for c in cols), LABEL[ref], LABEL[ref]))
        print("|---|---:|%s---:|---:|---:|---:|---:|" % ("---:|" * len(cols)))
        for row in r["A"]:
            vals = [get(row.get(c, {}), "seconds") for c in cols]
            c, gp = get(row["fastevm_cpu"], "seconds"), get(row["fastevm_gpu"], "seconds")
            gw = get(row.get("fastevm_gpu_warm", {}), "seconds")
            gas = row.get("reth", {}).get("gas_used") or row["geth"].get("gas_used")
            note = " (CPU retry)" if row["fastevm_gpu"].get("cpu_retried") else ""
            print("| %s | %s | %s | %s | %s%s | %s | %s | %s |" % (
                row["name"], gas, " | ".join(us(v) for v in vals), us(c), us(gp), note, us(gw),
                ratio(vals[0], c), ratio(vals[0], gw)))
        print()
    if "B" in r:
        print("## B. Batch throughput (N independent messages, %s threads for CPU engines)\n" % r["B"][0]["threads"])
        print("Messages/second (median of runs). Ratios are fastevm against %s.\n" % LABEL[ref])
        print("| program | N | %s | fastevm CPU | fastevm GPU | GPU warm | GPU vs %s | GPU warm vs %s |" % (
            " | ".join(LABEL[c] for c in cols), LABEL[ref], LABEL[ref]))
        print("|---|---:|%s---:|---:|---:|---:|---:|" % ("---:|" * len(cols)))
        for row in r["B"]:
            vals = [get(row.get(c, {}), "msgs_per_s") for c in cols]
            c, gp = get(row["fastevm_cpu"], "msgs_per_s"), get(row["fastevm_gpu"], "msgs_per_s")
            gw = get(row.get("fastevm_gpu_warm", {}), "msgs_per_s")
            retried = row["fastevm_gpu"].get("cpu_retried", 0) if isinstance(row["fastevm_gpu"], dict) else 0
            print("| %s | %d | %s | %s | %s%s | %s | %s | %s |" % (
                row["name"], row["n"], " | ".join(rate(v) for v in vals), rate(c), rate(gp),
                " ⚠retry" if retried else "", rate(gw), ratio(gp, vals[0]), ratio(gw, vals[0])))
        print()
    before_path = os.path.join(os.path.dirname(path), "full_v2.json")
    if "B" in r and os.path.exists(before_path) and os.path.abspath(before_path) != os.path.abspath(path):
        before = {(b["name"], b["n"]): b for b in json.load(open(before_path)).get("B", [])}
        rows = [b for b in r["B"] if b["name"] == "erc20_transfer" and "fastevm_gpu_warm" in b
                and ("erc20_transfer", b["n"]) in before]
        if rows:
            print("## GPU state cache: erc20_transfer before and after\n")
            print("Messages/second on the GPU. Before: the engine without the state cache (`%s`), which "
                  "re-uploaded the whole state tables every round and started every batch empty. Cold: contract "
                  "code stays in GPU memory across batches, only changed table entries are uploaded and rounds "
                  "download compact events. Warm: the batch repeats on the same state id, so accounts and storage "
                  "also come from GPU memory. Details and the remaining bottlenecks: `docs/perf.md`.\n" %
                  os.path.relpath(before_path, os.path.dirname(HERE)))
            print("| N | before | cold | warm | %s | warm vs before | %s vs warm |" % (LABEL[ref], LABEL[ref]))
            print("|---:|---:|---:|---:|---:|---:|---:|")
            for b in rows:
                pre = get(before[("erc20_transfer", b["n"])]["fastevm_gpu"], "msgs_per_s")
                cold, warm = get(b["fastevm_gpu"], "msgs_per_s"), get(b["fastevm_gpu_warm"], "msgs_per_s")
                rv = get(b.get(ref, {}), "msgs_per_s")
                print("| %d | %s | %s | %s | %s | %s | %s |" % (
                    b["n"], rate(pre), rate(cold), rate(warm), rate(rv), ratio(warm, pre), ratio(rv, warm)))
            print()
    if "C" in r:
        print("## C. Block import (reth `re-execute --num-tasks 1`, synthetic Osaka chains)\n")
        print("Chains from `bench/makechain` (go-ethereum `GenerateChain`, 60M-gas blocks), imported into reth, "
              "then re-executed in order against parent state with receipt validation. fastevm runs every "
              "top-level frame through reth's evm2 `InterpreterRunner` hook, **one message per batch**.\n")
        print("| chain | txs | reth | reth+JIT | fastevm CPU | fastevm GPU | CPU vs %s | frames on fastevm |" % LABEL[ref])
        print("|---|---:|---:|---:|---:|---:|---:|---|")
        for row in r["C"]:
            if "error" in row:
                continue
            v = {e: get(row.get(e, {}), "gas_per_s") for e in ("reth", "reth_jit", "fastevm_cpu", "fastevm_gpu")}
            g = lambda x: ("%.2f Ggas/s" % (x / 1e9)) if x else "–"
            best_ref = v.get(ref) or max(v["reth"] or 0, v["reth_jit"] or 0)
            print("| %s | %d | %s | %s | %s | %s | %s | %s |" % (
                row["name"], row["txs"], g(v["reth"]), g(v["reth_jit"]), g(v["fastevm_cpu"]), g(v["fastevm_gpu"]),
                ratio(v["fastevm_cpu"], best_ref), row.get("fastevm_cpu", {}).get("engine", "")))
        print()
    if "D" in r:
        print("## D. Compliance-suite runtime\n")
        print("| suite | engine | wall time | pass | fail | engine counters |")
        print("|---|---|---:|---:|---:|---|")
        for k, v in r.get("D_reth", {}).items():
            print("| reth ef-tests | %s | %.1f s | %d | %d | %s |" % (k, v["seconds"], v["pass"], v["fail"], v.get("engine", "")))
        for k, v in r["D"].items():
            print("| geth state tests Cancun..Osaka | %s | %.1f s | %d | %d | %s |" % (
                k, v["seconds"], v["pass"], v["fail"], v.get("engine", "")))
        print()
    comp = os.path.join(os.path.dirname(path), "compliance.json")
    if os.path.exists(comp):
        rows = json.load(open(comp))
        print("## Compliance runs\n")
        print("\"Client's own\" counts failures the client also has without fastevm (two Cancun→Prague "
              "system-contract deployment tests fail on reth natively). \"On fastevm\" counts top-level "
              "messages the engine ran; fallbacks went back to the client's EVM.\n")
        print("| suite | backend | tests | failures | client's own | on fastevm | fallbacks |")
        print("|---|---|---:|---:|---:|---:|---:|")
        for c in rows:
            print("| %s | %s | %s | %d | %d | %s | %d |" % (
                c["suite"], c["backend"], "{:,}".format(c["tests"]), c["failures"], c["baseline_failures"],
                "{:,}".format(c["on_engine"]), c["fallbacks"]))
        print("\nTotal: %s tests, %d failures caused by fastevm.\n" % (
            "{:,}".format(sum(c["tests"] for c in rows)),
            sum(c["failures"] - c["baseline_failures"] for c in rows)))


if __name__ == "__main__":
    main()
