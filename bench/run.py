#!/usr/bin/env python3
"""Benchmark driver: reth vs geth vs besu vs fastevm (CPU and CUDA backends).

The reference client is the globally fastest one (best geometric-mean speed over workloads A and B,
see pick_reference); every report ratio is taken against it. It is recorded in
bench/results/reference.json.

Workloads (see bench/README.md):
  A  single-message latency   - every corpus item, one message, warm
  B  batch throughput         - N independent messages (distinct senders, same contract)
  C  block import             - synthetic Osaka chains (bench/makechain) re-executed by reth
  R  reth ef-tests runtime     - reth's own suites (ethereum/tests v17 + EEST v4.5.0), native vs fastevm
  D  compliance-suite runtime - geth execution-spec state tests (Cancun..Osaka), native vs fastevm

Results go to bench/results/<timestamp>.json; bench/report.py renders them.

Usage: bench/run.py [--quick] [--workloads A,B,D] [--items a,b] [--batches 1,64,1000,10000]
                    [--engines reth,reth_jit,...] [--merge results/full.json]
"""
import argparse
import datetime
import glob
import json
import math
import os
import platform
import re
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
WS = os.path.dirname(ROOT)
BUILD = os.path.join(ROOT, "build")
GETH = os.path.join(WS, "go-ethereum")
BESU = os.path.join(WS, "besu")
JAVA = os.environ.get("FASTEVM_JAVA", os.path.join(ROOT, ".cache", "jdk25", "bin", "java"))
EVMTOOL_LIB = os.path.join(BESU, "ethereum", "evmtool", "build", "install", "evmtool", "lib")
EVMTOOL = os.path.join(BESU, "ethereum", "evmtool", "build", "install", "evmtool", "bin", "evmtool")
RETHBENCH = os.path.join(HERE, "rethbench", "target", "release", "rethbench")
RETH = os.path.join(WS, "reth")
GENESIS = os.path.join(HERE, "config", "genesis_osaka.json")
SCRATCH = os.environ.get("FASTEVM_BENCH_TMP", os.path.join(BUILD, "bench-tmp"))

# fastevm_gpu_warm: same GPU engine, every repeat declares one state id so repeats after the first
# find accounts and slots in the engine's state cache (a node serving calls against one block).
ENGINES = ["reth", "reth_jit", "geth", "besu", "fastevm_cpu", "fastevm_gpu", "fastevm_gpu_warm", "fastevm_go"]
CLIENTS = ["reth", "reth_jit", "geth", "besu"]  # reference candidates
GPU_ARENA = {"snailtracer": 16 << 20, "blake2b_shifts": 2 << 20}
BATCH_ITEMS = ["erc20_transfer", "arith_loop", "keccak_loop", "storage_rw", "swap_math_0", "sha1_divs_0",
               "blake2b_shifts", "weierstrudel_0", "snailtracer"]


def sh(cmd, timeout=900, env=None, cwd=None):
    e = dict(os.environ)
    if env:
        e.update(env)
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=e, cwd=cwd)
    return p.returncode, p.stdout, p.stderr


def load_corpus():
    items = {}
    for f in sorted(glob.glob(os.path.join(HERE, "corpus", "*.json"))):
        d = json.load(open(f))
        items[d["name"]] = d
    return items


def machine_info():
    info = {"platform": platform.platform(), "python": platform.python_version(), "time": datetime.datetime.now().isoformat()}
    try:
        info["cpu"] = re.search(r"Model name:\s*(.*)", sh(["lscpu"])[1]).group(1).strip()
        info["cpu_threads"] = os.cpu_count()
    except Exception:
        pass
    rc, out, _ = sh(["nvidia-smi", "--query-gpu=name,memory.total,pcie.link.gen.max,pcie.link.width.current,driver_version",
                     "--format=csv,noheader"])
    if rc == 0:
        info["gpu"] = out.strip()
    for name, d in (("geth_commit", GETH), ("besu_commit", BESU), ("reth_commit", RETH)):
        rc, out, _ = sh(["git", "-C", d, "rev-parse", "--short", "HEAD"])
        info[name] = out.strip()
    return info


# ------------------------------------------------------------------ single message (A)

def geth_single(item):
    os.makedirs(SCRATCH, exist_ok=True)
    cf = os.path.join(SCRATCH, "code.hex")
    open(cf, "w").write(item["code"])
    rc, out, err = sh([os.path.join(BUILD, "geth-evm"), "run", "--prestate", GENESIS, "--gas", str(item["gas"]),
                       "--codefile", cf, "--input", "0x" + item["input"], "--bench"])
    txt = out + err
    m = re.search(r"execution time:\s*([\d.]+)(ns|µs|us|ms|s)\b", txt)
    g = re.search(r"EVM gas used:\s*(\d+)", txt)
    if not m:
        return {"error": txt[-300:]}
    scale = {"ns": 1e-9, "µs": 1e-6, "us": 1e-6, "ms": 1e-3, "s": 1.0}[m.group(2)]
    return {"seconds": float(m.group(1)) * scale, "gas_used": int(g.group(1)) if g else None}


def besu_single_batch(item, repeat):
    """Besu single-message latency through the batch harness (n=1, 1 thread, state reset per run)."""
    d = besubatch(item, 1, repeat, 1)
    if "median_s" in d:
        return {"seconds": d["best_s"], "median_s": d["median_s"], "harness": "BesuBatch n=1"}
    return d


def besu_single(item, repeat):
    if not os.path.exists(EVMTOOL):
        return {"error": "evmtool not built"}
    env = {"JAVA_HOME": os.path.dirname(os.path.dirname(JAVA))}
    rc, out, err = sh([EVMTOOL, "--fork=osaka", "--code=" + item["code"], "--input=0x" + item["input"],
                       "--gas=%d" % item["gas"], "--repeat=%d" % repeat], env=env, timeout=1800)
    for line in reversed(out.splitlines()):
        if line.startswith("{") and "timens" in line:
            d = json.loads(line)
            return {"seconds": d["timens"] / 1e9, "gas_used": int(d["gasUsed"], 16)}
    return {"error": (out + err)[-300:]}


def fastevm_single(item, backend, repeat, arena=0, warm=False):
    cmd = [os.path.join(BUILD, "fastevm-run"), "--code", item["code"], "--input", item["input"] or "00",
           "--gas", str(item["gas"]), "--batch", "1", "--repeat", str(repeat), "--backend", backend, "--json"]
    if arena:
        cmd += ["--arena", str(arena)]
    if warm:
        cmd += ["--warm"]
    rc, out, err = sh(cmd, timeout=1800)
    try:
        d = json.loads(out.strip().splitlines()[-1])
    except Exception:
        return {"error": (out + err)[-300:]}
    return {"seconds": d["best_s"], "median_s": d["median_s"], "gas_used": d["gas_used"], "rounds": d["rounds"],
            "cpu_retried": d.get("cpu_retried", 0), "status": d["status"]}


def rethbench(item_path, engine, n, repeat, threads):
    rc, out, err = sh([RETHBENCH, "--corpus", item_path, "--engine", engine, "--n", str(n), "--repeat", str(repeat),
                       "--threads", str(threads)], timeout=3600)
    try:
        return json.loads(out.strip().splitlines()[-1])
    except Exception:
        return {"error": (out + err)[-300:]}


def reth_single(item, engine, repeat):
    """reth (evm2) single-message latency: one tx on a warm EVM, best of `repeat`."""
    d = rethbench(os.path.join(HERE, "corpus", item["name"] + ".json"), engine, 1, repeat, 1)
    if "best_s" in d:
        return {"seconds": d["best_s"], "median_s": d["median_s"], "gas_used": d["gas_used"]}
    return d


def workload_a(items, quick, engines):
    res = []
    names = list(items) if not quick else ["arith_loop", "keccak_loop", "erc20_transfer", "snailtracer", "sha1_divs_0"]
    for n in names:
        it = items[n]
        row = {"name": n, "category": it["category"], "source": it["source"]}
        print("[A] %s" % n, file=sys.stderr, flush=True)
        heavy = it["gas"] > 50_000_000 and "snailtracer" in n
        if "reth" in engines:
            row["reth"] = reth_single(it, "reth", 5 if heavy else 50)
        if "reth_jit" in engines:
            row["reth_jit"] = reth_single(it, "reth-jit", 5 if heavy else 50)
        if "geth" in engines:
            row["geth"] = geth_single(it)
        # evmtool --repeat keeps state between iterations, so stateful programs take a different
        # path after the first run; use it only for stateless ones.
        stateful = it["category"] in ("state", "token")
        if "besu" in engines:
            row["besu"] = besu_single_batch(it, 20) if stateful else besu_single(it, 10 if quick else 30)
        if "fastevm_cpu" in engines:
            row["fastevm_cpu"] = fastevm_single(it, "cpu", 5 if quick else 15)
        if "fastevm_gpu" in engines:
            row["fastevm_gpu"] = fastevm_single(it, "gpu", 3 if quick else 5)
        if "fastevm_gpu_warm" in engines:
            row["fastevm_gpu_warm"] = fastevm_single(it, "gpu", 3 if quick else 5, warm=True)
        res.append(row)
    return res


# ------------------------------------------------------------------ batch throughput (B)

def gethbench(item_path, engine, n, repeat, threads, arena=0):
    rc, out, err = sh([os.path.join(BUILD, "gethbench"), "-corpus", item_path, "-engine", engine, "-n", str(n),
                       "-repeat", str(repeat), "-threads", str(threads), "-arena", str(arena)], timeout=3600)
    try:
        return json.loads(out.strip().splitlines()[-1])
    except Exception:
        return {"error": (out + err)[-300:]}


def besubatch(item, n, repeat, threads):
    cp = "%s/*:%s" % (EVMTOOL_LIB, os.path.join(HERE, "besu"))
    rc, out, err = sh([JAVA, "-cp", cp, "BesuBatch", item["code"], "0x" + item["input"], str(item["gas"]), str(n),
                       str(threads), str(repeat)], timeout=3600)
    for line in reversed(out.splitlines()):
        if line.startswith("{"):
            return json.loads(line)
    return {"error": (out + err)[-300:]}


def fastevm_batch(item, backend, n, repeat, arena=0, warm=False):
    cmd = [os.path.join(BUILD, "fastevm-run"), "--code", item["code"], "--input", item["input"] or "00",
           "--gas", str(item["gas"]), "--batch", str(n), "--repeat", str(repeat), "--backend", backend, "--json"]
    if arena:
        cmd += ["--arena", str(arena)]
    if warm:
        cmd += ["--warm"]
    rc, out, err = sh(cmd, timeout=3600)
    try:
        return json.loads(out.strip().splitlines()[-1])
    except Exception:
        return {"error": (out + err)[-300:]}


def workload_b(items, batches, quick, engines, names=None):
    threads = os.cpu_count()
    res = []
    for name in names or BATCH_ITEMS:
        it = items[name]
        path = os.path.join(HERE, "corpus", name + ".json")
        heavy = it["gas"] > 50_000_000
        for n in batches:
            if heavy and n > 1000:
                continue
            reps = 3 if (quick or heavy) else 5
            print("[B] %s N=%d" % (name, n), file=sys.stderr, flush=True)
            # GPU lane arenas sized to the program's footprint (default 1 MB): snailtracer uses ~9 MB
            # of EVM memory, blake2b_shifts overflows 1 MB. Larger arenas mean fewer resident lanes.
            arena = GPU_ARENA.get(name, 0)
            row = {"name": name, "n": n, "threads": threads, "gas_per_msg": None}
            if "reth" in engines:
                row["reth"] = rethbench(path, "reth", n, reps, threads)
            if "reth_jit" in engines:
                row["reth_jit"] = rethbench(path, "reth-jit", n, reps, threads)
            if "geth" in engines:
                row["geth"] = gethbench(path, "geth", n, reps, threads)
            if "besu" in engines:
                row["besu"] = besubatch(it, n, reps, threads)
            if "fastevm_cpu" in engines:
                row["fastevm_cpu"] = fastevm_batch(it, "cpu", n, reps)
            if "fastevm_gpu" in engines:
                row["fastevm_gpu"] = fastevm_batch(it, "gpu", n, reps, arena)
            if "fastevm_gpu_warm" in engines:
                row["fastevm_gpu_warm"] = fastevm_batch(it, "gpu", n, reps, arena, warm=True)
            if "fastevm_go" in engines:
                row["fastevm_cpu_go"] = gethbench(path, "fastevm-cpu", n, reps, threads)
                row["fastevm_gpu_go"] = gethbench(path, "fastevm-gpu", n, reps, threads, arena)
            row["gpu_arena"] = arena
            g = next((row[k].get("gas_used") for k in ("geth", "reth") if isinstance(row.get(k), dict)
                      and row[k].get("gas_used")), None)
            if g:
                row["gas_per_msg"] = g // n
            res.append(row)
    return res


# ------------------------------------------------------------------ block import (C)

CHAINS = {  # name -> makechain args
    "erc20": ["-workload", "erc20", "-conflict", "0"],
    "erc20_hot50": ["-workload", "erc20", "-conflict", "0.5"],
    "mixed": ["-workload", "mixed", "-conflict", "0"],
}
RETH_BIN = os.path.join(RETH, "target", "release", "reth")


def parse_gas_rate(txt):
    m = re.search(r'throughput="?([\d.]+)\s*([KMGT]?)gas/second', txt)
    if not m:
        return None
    return float(m.group(1)) * {"": 1, "K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12}[m.group(2)]


def workload_c(engines, blocks=41, repeat=3):
    """Imports each chain into a fresh reth datadir, then times `reth re-execute --num-tasks 1`
    (blocks executed in order against their parent state, receipts validated) per engine."""
    res = []
    env_lib = {"LD_LIBRARY_PATH": BUILD}
    for name, args in CHAINS.items():
        out = os.path.join(BUILD, "chains", name)
        rc, so, se = sh([os.path.join(BUILD, "makechain"), "-corpus", os.path.join(HERE, "corpus"), "-out", out,
                         "-blocks", str(blocks)] + args, timeout=3600)
        if rc:
            res.append({"name": name, "error": (so + se)[-300:]})
            continue
        meta = json.loads(so.strip().splitlines()[-1])
        gen = os.path.join(out, "genesis.json")
        db = os.path.join(BUILD, "rethdb", name)
        subprocess.run(["rm", "-rf", db])
        sh([RETH_BIN, "init", "--datadir", db, "--chain", gen], env=env_lib)
        rc, so, se = sh([RETH_BIN, "import", "--datadir", db, "--chain", gen, os.path.join(out, "chain.rlp")],
                        env=env_lib, timeout=3600)
        row = {"name": name, **meta, "import_ok": rc == 0}
        for eng in ("reth", "reth_jit", "fastevm_cpu", "fastevm_gpu"):
            if eng not in engines:
                continue
            print("[C] %s %s" % (name, eng), file=sys.stderr, flush=True)
            cmd = [RETH_BIN, "re-execute", "--datadir", db, "--chain", gen, "--num-tasks", "1"]
            env = dict(env_lib)
            if eng == "reth_jit":
                cmd += ["--jit", "--jit.hot-threshold", "1"]
            if eng.startswith("fastevm"):
                env["FASTEVM_BACKEND"] = eng.split("_")[1]
            stats = os.path.join(SCRATCH, "c_stats.txt")
            os.makedirs(SCRATCH, exist_ok=True)
            env["FASTEVM_STATS"] = stats
            rates, last = [], ""
            for _ in range(repeat):
                if os.path.exists(stats):
                    os.remove(stats)
                rc, so, se = sh(cmd, env=env, timeout=3600)
                last = re.sub(r"\x1b\[[0-9;]*m", "", so + se)
                r = parse_gas_rate(last) if "Re-executed successfully" in last else None
                if r:
                    rates.append(r)
            if not rates:
                row[eng] = {"error": last[-400:]}
                continue
            d = {"gas_per_s": max(rates), "runs": rates, "blocks_executed": blocks - 1}
            if os.path.exists(stats):
                d["engine"] = open(stats).read().strip()
            row[eng] = d
        res.append(row)
    return res


# ------------------------------------------------------------------ compliance runtime (D)

def workload_d():
    res = {}
    pattern = "TestExecutionSpecState/for_(cancun|prague|osaka)"
    for label, tags, env in (("geth_native", [], {}), ("fastevm_cpu", ["-tags", "fastevm"], {"FASTEVM_BACKEND": "cpu"}),
                             ("fastevm_gpu", ["-tags", "fastevm"], {"FASTEVM_BACKEND": "gpu"})):
        print("[D] %s" % label, file=sys.stderr, flush=True)
        t0 = time.time()
        rc, out, err = sh(["go", "test"] + tags + ["./tests", "-run", pattern, "-short", "-count=1", "-v"], cwd=GETH,
                          env=env, timeout=7200)
        txt = out + err
        res[label] = {
            "seconds": time.time() - t0,
            "ok": rc == 0,
            "pass": len(re.findall(r"^\s+--- PASS", txt, re.M)),
            "fail": len(re.findall(r"^\s+--- FAIL", txt, re.M)),
            "engine": (re.search(r"fastevm: .*", txt).group(0) if re.search(r"fastevm: .*", txt) else ""),
        }
    return res


def ok(d):
    return isinstance(d, dict) and not isinstance(d.get("error"), str) and "skipped" not in d


def pick_reference(res, candidates=CLIENTS):
    """Globally fastest client: geometric mean, over every A and B row all candidates completed, of each
    client's speed relative to geth (A: 1/seconds, B: msgs/s). Highest wins."""
    logs = {c: [] for c in candidates}
    for row in res.get("A", []):
        if all(ok(row.get(c)) and row[c].get("seconds") for c in candidates):
            base = row["geth"]["seconds"]
            for c in candidates:
                logs[c].append(math.log(base / row[c]["seconds"]))
    for row in res.get("B", []):
        if all(ok(row.get(c)) and row[c].get("msgs_per_s") for c in candidates):
            base = row["geth"]["msgs_per_s"]
            for c in candidates:
                logs[c].append(math.log(row[c]["msgs_per_s"] / base))
    score = {c: math.exp(sum(v) / len(v)) for c, v in logs.items() if v}
    if not score:
        return None
    best = max(score, key=score.get)
    return {"reference": best, "client": best.split("_")[0], "geomean_vs_geth": score,
            "rows": len(logs[best]), "rule": "geomean over workloads A (1/latency) and B (msgs/s), relative to geth"}


def merge(base, new):
    """Overlay engine columns of `new` onto the matching A (name) / B (name, n) / C (name) rows of `base`."""
    for wl, key in (("A", lambda r: r["name"]), ("B", lambda r: (r["name"], r["n"])), ("C", lambda r: r["name"])):
        if wl not in new:
            continue
        idx = {key(r): r for r in base.get(wl, [])}
        for r in new[wl]:
            if key(r) in idx:
                idx[key(r)].update({k: v for k, v in r.items() if k != "gas_per_msg" or v})
            else:
                base.setdefault(wl, []).append(r)
    for k, v in new.items():
        if k not in ("A", "B", "C", "machine", "args", "reference"):  # D, D_reth: replaced
            base[k] = v
    base["machine"] = {**base.get("machine", {}), **new["machine"]}
    return base


def workload_r():
    """reth ef-tests (cargo test -p ef-tests), same binary; FASTEVM_BACKEND selects the engine."""
    res = {}
    for label in ("reth_native", "fastevm_cpu", "fastevm_gpu"):
        print("[R] %s" % label, file=sys.stderr, flush=True)
        stats = os.path.join(SCRATCH, "r_stats.txt")
        os.makedirs(SCRATCH, exist_ok=True)
        if os.path.exists(stats):
            os.remove(stats)
        env = {"FASTEVM_STATS": stats}
        if label != "reth_native":
            env["FASTEVM_BACKEND"] = label.split("_")[1]
        t0 = time.time()
        rc, out, err = sh(["cargo", "test", "--release", "-p", "ef-tests", "--features", "ef-tests,fastevm",
                           "--test", "tests"], cwd=RETH, env=env, timeout=7200)
        txt = out + err
        m = re.search(r"test result: \w+\. (\d+) passed; (\d+) failed", txt)
        res[label] = {"seconds": time.time() - t0, "ok": rc == 0,
                      "pass": int(m.group(1)) if m else 0, "fail": int(m.group(2)) if m else -1,
                      "engine": open(stats).read().strip() if os.path.exists(stats) else ""}
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--workloads", default="A,B,D")
    ap.add_argument("--items", default="")
    ap.add_argument("--batches", default="1,64,1000,10000")
    ap.add_argument("--out", default="")
    ap.add_argument("--engines", default=",".join(ENGINES))
    ap.add_argument("--merge", default="", help="overlay new columns onto this results file")
    args = ap.parse_args()
    items = load_corpus()
    out = {"machine": machine_info(), "args": vars(args)}
    wl = args.workloads.split(",")
    names = [x for x in args.items.split(",") if x] or None
    engines = set(args.engines.split(","))
    if "A" in wl:
        out["A"] = workload_a(items, args.quick, engines)
    if "B" in wl:
        out["B"] = workload_b(items, [int(x) for x in args.batches.split(",")], args.quick, engines, names)
    if "C" in wl:
        out["C"] = workload_c(engines)
    if "R" in wl:
        out["D_reth"] = workload_r()
    if "D" in wl:
        out["D"] = workload_d()
    if args.merge:
        out = merge(json.load(open(args.merge)), out)
    ref = pick_reference(out)
    if ref:
        out["reference"] = ref
    os.makedirs(os.path.join(HERE, "results"), exist_ok=True)
    if ref:
        json.dump(ref, open(os.path.join(HERE, "results", "reference.json"), "w"), indent=1)
    path = args.out or os.path.join(HERE, "results", datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + ".json")
    json.dump(out, open(path, "w"), indent=1)
    print(path)


if __name__ == "__main__":
    main()
