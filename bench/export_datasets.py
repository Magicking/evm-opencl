#!/usr/bin/env python3
"""Turns bench/results/<file>.json into flat row files for the report dashboard.

Writes <outdir>/{latency,throughput,block_import,suite_runtime,compliance,machine,reference}.json.
Usage: bench/export_datasets.py results.json outdir
"""
import json
import os
import sys


def num(d, k):
    # Harness failures carry an "error" string; fastevm-run's numeric "error" is the EVM error code.
    if isinstance(d, dict) and not isinstance(d.get("error"), str) and "skipped" not in d:
        v = d.get(k)
        return float(v) if v is not None else None
    return None


def main():
    res = json.load(open(sys.argv[1]))
    out = sys.argv[2]
    os.makedirs(out, exist_ok=True)

    lat = []
    for row in res.get("A", []):
        gas = row["geth"].get("gas_used") or row["fastevm_cpu"].get("gas_used")
        sec = lambda k: round(num(row.get(k, {}), "seconds") * 1e6, 2) if num(row.get(k, {}), "seconds") else None
        lat.append({
            "program": row["name"],
            "category": row["category"],
            "gas": gas,
            "reth_us": sec("reth"),
            "reth_jit_us": sec("reth_jit"),
            "geth_us": round(num(row["geth"], "seconds") * 1e6, 2) if num(row["geth"], "seconds") else None,
            "besu_us": round(num(row["besu"], "seconds") * 1e6, 2) if num(row["besu"], "seconds") else None,
            "fastevm_cpu_us": round(num(row["fastevm_cpu"], "seconds") * 1e6, 2)
            if num(row["fastevm_cpu"], "seconds") else None,
            "fastevm_gpu_us": round(num(row["fastevm_gpu"], "seconds") * 1e6, 2)
            if num(row["fastevm_gpu"], "seconds") else None,
            "gpu_cpu_retry": bool(row["fastevm_gpu"].get("cpu_retried")),
        })
    json.dump(lat, open(os.path.join(out, "latency.json"), "w"), indent=0)

    thr = []
    labels = {"reth": "reth", "reth_jit": "reth+JIT", "geth": "geth", "besu": "besu", "fastevm_cpu": "fastevm CPU", "fastevm_gpu": "fastevm GPU",
              "fastevm_cpu_go": "fastevm CPU via Go", "fastevm_gpu_go": "fastevm GPU via Go"}
    for row in res.get("B", []):
        gas = row.get("gas_per_msg")
        for k, label in labels.items():
            m = num(row.get(k, {}), "msgs_per_s")
            if m is None:
                continue
            thr.append({
                "program": row["name"],
                "n": row["n"],
                "engine": label,
                "msgs_per_s": round(m, 1),
                "mgas_per_s": round(m * gas / 1e6, 1) if gas else None,
                "cpu_retried": int(row.get(k, {}).get("cpu_retried", 0) or 0),
            })
    json.dump(thr, open(os.path.join(out, "throughput.json"), "w"), indent=0)

    blk = []
    for row in res.get("C", []):
        for k, label in (("reth", "reth"), ("reth_jit", "reth+JIT"), ("fastevm_cpu", "fastevm CPU"),
                         ("fastevm_gpu", "fastevm GPU")):
            v = num(row.get(k, {}), "gas_per_s")
            if v:
                blk.append({"chain": row["name"], "engine": label, "mgas_per_s": round(v / 1e6, 1),
                            "txs": row.get("txs"), "blocks": row.get(k, {}).get("blocks_executed")})
    json.dump(blk, open(os.path.join(out, "block_import.json"), "w"), indent=0)

    ref = res.get("reference")
    if ref:
        json.dump([{"client": {"reth": "reth", "reth_jit": "reth+JIT"}.get(c, c), "geomean_vs_geth": round(v, 3),
                    "reference": c == ref["reference"]} for c, v in ref["geomean_vs_geth"].items()],
                  open(os.path.join(out, "reference.json"), "w"), indent=0)

    suite = []
    for k, v in res.get("D_reth", {}).items():
        suite.append({"suite": "reth ef-tests", "engine": {"reth_native": "reth (evm2)", "fastevm_cpu": "fastevm CPU",
                                                          "fastevm_gpu": "fastevm GPU"}.get(k, k),
                      "seconds": round(v["seconds"], 1), "pass": v["pass"], "fail": v["fail"]})
    for k, v in res.get("D", {}).items():
        suite.append({"suite": "geth state tests", "engine": {"geth_native": "geth interpreter", "fastevm_cpu": "fastevm CPU",
                                 "fastevm_gpu": "fastevm GPU"}.get(k, k),
                      "seconds": round(v["seconds"], 1), "pass": v["pass"], "fail": v["fail"]})
    json.dump(suite, open(os.path.join(out, "suite_runtime.json"), "w"), indent=0)

    m = res.get("machine", {})
    json.dump([{"key": k, "value": str(v)} for k, v in m.items()], open(os.path.join(out, "machine.json"), "w"),
              indent=0)

    # Compliance runs (from docs/compliance.md; produced by the client test suites, not by run.py).
    comp = [
        {"suite": "reth ef-tests (ethereum/tests v17 + EEST v4.5.0, 60 groups)", "client": "reth", "backend": "CPU",
         "tests": 60, "failures": 0, "on_engine": 102225, "fallbacks": 74},
        {"suite": "reth ef-tests (ethereum/tests v17 + EEST v4.5.0, 60 groups)", "client": "reth", "backend": "GPU",
         "tests": 60, "failures": 0, "on_engine": 102225, "fallbacks": 74},
        {"suite": "reth blockchain tests, tests@v21.0.1 Cancun-Osaka (ef-test-runner)", "client": "reth",
         "backend": "CPU", "tests": 7290, "failures": 2, "baseline_failures": 2, "on_engine": 209629, "fallbacks": 67},
        {"suite": "reth blockchain tests, tests@v21.0.1 Cancun-Osaka (ef-test-runner)", "client": "reth",
         "backend": "GPU", "tests": 7290, "failures": 2, "baseline_failures": 2, "on_engine": 209629, "fallbacks": 67},
        {"suite": "geth TestExecutionSpecState (all forks, 4 permutations)", "client": "geth", "backend": "CPU",
         "tests": 421173, "failures": 0, "on_engine": 152836, "fallbacks": 264},
        {"suite": "geth TestExecutionSpecState (Cancun-Osaka)", "client": "geth", "backend": "CPU",
         "tests": 83149, "failures": 0, "on_engine": 38209, "fallbacks": 66},
        {"suite": "geth TestExecutionSpecState (Cancun-Osaka)", "client": "geth", "backend": "GPU",
         "tests": 83149, "failures": 0, "on_engine": 38209, "fallbacks": 66},
        {"suite": "geth TestExecutionSpecBlocktests (Cancun-Osaka + transitions)", "client": "geth",
         "backend": "CPU", "tests": 50067, "failures": 0, "on_engine": 582575, "fallbacks": 706},
        {"suite": "besu ExecutionSpecStateTest (all forks)", "client": "besu", "backend": "CPU",
         "tests": 83367, "failures": 0, "on_engine": 38209, "fallbacks": 66},
        {"suite": "besu ExecutionSpecStateTest (all forks)", "client": "besu", "backend": "GPU",
         "tests": 83367, "failures": 0, "on_engine": 38209, "fallbacks": 66},
    ]
    for i, c in enumerate(comp):
        # Failures the client also has without fastevm (reth: two Cancun->Prague system-contract
        # deployment tests fail natively).
        c.setdefault("baseline_failures", 0)
        c["run"] = "%s %s %d" % (c["client"], c["backend"], i)
    json.dump(comp, open(os.path.join(out, "compliance.json"), "w"), indent=0)
    print("wrote datasets to", out)


if __name__ == "__main__":
    main()
