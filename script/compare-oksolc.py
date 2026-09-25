#!/usr/bin/env python3
"""Compare Foundry artifacts produced by two compilers, byte for byte.

Build the project twice, once with upstream solc and once with oksolc, then
run this script on the two output directories:

    FOUNDRY_PROFILE=viair forge build --force
    FOUNDRY_PROFILE=viair forge build --force --use /path/to/oksolc --out out-oksolc
    script/compare-oksolc.py out-viair out-oksolc

Every contract in every artifact is compared on creation bytecode, runtime
bytecode, ABI and metadata. Bytecode is also compared with the trailing CBOR
metadata stripped, so a metadata-only difference is reported as such.
"""
import json, os, sys

def strip_cbor(hexcode):
    if len(hexcode) < 4:
        return hexcode
    n = int(hexcode[-4:], 16)
    return hexcode[:-(n + 2) * 2]

def artifacts(out_dir):
    found = {}
    for root, _, files in os.walk(out_dir):
        if os.path.basename(root) == "build-info":
            continue
        for f in files:
            if not f.endswith(".json"):
                continue
            path = os.path.join(root, f)
            with open(path) as fh:
                try:
                    j = json.load(fh)
                except json.JSONDecodeError:
                    continue
            if "bytecode" not in j or "deployedBytecode" not in j:
                continue
            found[os.path.relpath(path, out_dir)] = j
    return found

def main(a_dir, b_dir):
    a, b = artifacts(a_dir), artifacts(b_dir)
    keys = sorted(set(a) | set(b))
    same = diff = missing = 0
    for k in keys:
        if k not in a or k not in b:
            print(f"MISSING  {k} (only in {'first' if k in a else 'second'})")
            missing += 1
            continue
        x, y = a[k], b[k]
        problems = []
        for kind in ("bytecode", "deployedBytecode"):
            ox, oy = x[kind]["object"], y[kind]["object"]
            if ox != oy:
                tag = "metadata-only" if strip_cbor(ox) == strip_cbor(oy) else "CODE"
                problems.append(f"{kind}:{tag} {len(ox)//2}B vs {len(oy)//2}B")
        if x.get("abi") != y.get("abi"):
            problems.append("abi")
        if x.get("metadata") != y.get("metadata"):
            problems.append("metadata")
        if problems:
            print(f"DIFF     {k}: " + ", ".join(problems))
            diff += 1
        else:
            same += 1
    print(f"\n{same} identical, {diff} different, {missing} missing, {len(keys)} artifacts compared")
    return 0 if diff == 0 and missing == 0 else 1

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__); sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))
