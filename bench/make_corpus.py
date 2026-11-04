#!/usr/bin/env python3
"""Builds bench/corpus/*.json: EVM programs used by the geth/besu/fastevm benchmarks.

Sources:
  * ipsilon/evm-benchmarks (go-ethereum/tests/evm-benchmarks submodule): main + micro
  * synthetic workloads assembled below (arith loop, keccak loop, storage, ERC20 transfer)

Each corpus item: {"name", "category", "code", "input", "gas", "source"}.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "corpus")
EVMB = os.path.join(HERE, "..", "..", "go-ethereum", "tests", "evm-benchmarks", "benchmarks")

OPS = {
    "STOP": 0x00, "ADD": 0x01, "MUL": 0x02, "SUB": 0x03, "DIV": 0x04, "MOD": 0x06, "EXP": 0x0a,
    "LT": 0x10, "GT": 0x11, "EQ": 0x14, "ISZERO": 0x15, "AND": 0x16, "OR": 0x17, "XOR": 0x18, "NOT": 0x19,
    "SHL": 0x1b, "SHR": 0x1c, "KECCAK256": 0x20, "ADDRESS": 0x30, "CALLER": 0x33, "CALLVALUE": 0x34,
    "CALLDATALOAD": 0x35, "CALLDATASIZE": 0x36, "POP": 0x50, "MLOAD": 0x51, "MSTORE": 0x52, "SLOAD": 0x54,
    "SSTORE": 0x55, "JUMP": 0x56, "JUMPI": 0x57, "GAS": 0x5a, "JUMPDEST": 0x5b, "PUSH0": 0x5f,
    "LOG3": 0xa3, "RETURN": 0xf3, "REVERT": 0xfd,
}
for i in range(1, 17):
    OPS["DUP%d" % i] = 0x7f + i
    OPS["SWAP%d" % i] = 0x8f + i


def assemble(src):
    """Tiny assembler: opcodes, integers (auto PUSHn), @label refs (PUSH2), label: defs."""
    toks = src.split()
    # Pass 1: label offsets.
    labels, pc = {}, 0
    for t in toks:
        if t.endswith(":"):
            labels[t[:-1]] = pc
            pc += 1  # JUMPDEST
        elif t.startswith("@"):
            pc += 3
        elif t.upper() in OPS:
            pc += 1
        else:
            v = int(t, 0)
            n = max(1, (v.bit_length() + 7) // 8)
            pc += 1 + n
    out = bytearray()
    for t in toks:
        if t.endswith(":"):
            out.append(0x5b)
        elif t.startswith("@"):
            out += bytes([0x61]) + labels[t[1:]].to_bytes(2, "big")
        elif t.upper() in OPS:
            out.append(OPS[t.upper()])
        else:
            v = int(t, 0)
            n = max(1, (v.bit_length() + 7) // 8)
            out += bytes([0x5f + n]) + v.to_bytes(n, "big")
    return out.hex()


SYNTHETIC = {
    # 20k iterations of mixed 256-bit arithmetic.
    "arith_loop": ("compute", """
        0 20000
        loop: DUP1 ISZERO @end JUMPI
          SWAP1 0x1f2e3d4c5b6a7988 MUL 0x0123456789abcdef ADD 0xdeadbeef XOR DUP2 ADD SWAP1
          1 SWAP1 SUB @loop JUMP
        end: POP 0 MSTORE 32 0 RETURN
    """, ""),
    # 5k keccak256 over a 64-byte buffer, chaining the digest.
    "keccak_loop": ("compute", """
        5000
        loop: DUP1 ISZERO @end JUMPI
          64 0 KECCAK256 0 MSTORE
          1 SWAP1 SUB @loop JUMP
        end: POP 32 0 RETURN
    """, ""),
    # 100 cold SSTOREs to fresh slots then 100 SLOADs (state-heavy, many host fetches).
    "storage_rw": ("state", """
        100
        w: DUP1 ISZERO @r0 JUMPI
          DUP1 DUP1 SSTORE
          1 SWAP1 SUB @w JUMP
        r0: POP 100 0
        r: DUP2 ISZERO @end JUMPI
          DUP2 SLOAD ADD SWAP1 1 SWAP1 SUB SWAP1 @r JUMP
        end: 0 MSTORE POP 32 0 RETURN
    """, ""),
    # ERC20-style transfer(to, amount): balances[keccak(addr . 0)], faucet on low balance, Transfer log.
    "erc20_transfer": ("token", """
        0 CALLDATALOAD 224 SHR 0xa9059cbb EQ @transfer JUMPI 0 0 REVERT
        transfer:
          CALLER 0 MSTORE 0 32 MSTORE 64 0 KECCAK256
          DUP1 SLOAD
          36 CALLDATALOAD DUP2 LT ISZERO @funded JUMPI
            0x0c9f2c9cd04674edea40000000 ADD
          funded:
          36 CALLDATALOAD SWAP1 SUB SWAP1 SSTORE
          4 CALLDATALOAD 0 MSTORE 64 0 KECCAK256
          DUP1 SLOAD 36 CALLDATALOAD ADD SWAP1 SSTORE
          36 CALLDATALOAD 0 MSTORE
          4 CALLDATALOAD CALLER 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef 32 0 LOG3
          1 0 MSTORE 32 0 RETURN
    """, "a9059cbb" + "00" * 12 + "00000000000000000000000000000000000beef0" + "%064x" % 1000),
}


def write(item):
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, item["name"] + ".json"), "w") as f:
        json.dump(item, f, indent=1)


def main():
    n = 0
    for name, (cat, src, inp) in SYNTHETIC.items():
        write({"name": name, "category": cat, "code": assemble(src), "input": inp, "gas": 30_000_000,
               "source": "synthetic"})
        n += 1
    if os.path.isdir(EVMB):
        for sub in ("main", "micro"):
            d = os.path.join(EVMB, sub)
            for fn in sorted(os.listdir(d)):
                if not fn.endswith(".json"):
                    continue
                t = json.load(open(os.path.join(d, fn)))
                for tname, v in t.items():
                    to = v["transaction"]["to"].lower()
                    code = v["pre"][to]["code"]
                    datas = v["transaction"]["data"]
                    gas = int(v["transaction"]["gasLimit"][0], 16)
                    for i, data in enumerate(datas):
                        nm = tname if len(datas) == 1 else "%s_%d" % (tname, i)
                        write({"name": nm, "category": sub, "code": code[2:] if code.startswith("0x") else code,
                               "input": data[2:] if data.startswith("0x") else data, "gas": min(gas, 1_000_000_000),
                               "source": "evm-benchmarks/" + sub})
                        n += 1
    else:
        print("warning: evm-benchmarks submodule missing (git submodule update --init tests/evm-benchmarks)",
              file=sys.stderr)
    print("wrote %d corpus items to %s" % (n, OUT))


if __name__ == "__main__":
    main()
