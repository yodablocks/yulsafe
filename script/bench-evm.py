#!/usr/bin/env python3
"""Per-transaction gas of every benchmarked vault call, read from execution traces.

Runs each GasBenchmark test on its own with `forge test --isolate`, so every
call gets real transaction semantics (cold storage access), and takes the gas
of the last vault call in the trace. This is the number a user pays, minus the
21,000 intrinsic transaction cost, and it is the same for all three vaults.

`forge test --gas-report` produces the same values but aggregates calls from
different tests into one row, which is how the first and subsequent deposit
got their labels swapped in an earlier README.

    script/bench-evm.py                      # default profile
    FOUNDRY_PROFILE=viair script/bench-evm.py
"""
import subprocess, re
ops=["first_deposit","subsequent_deposit","mint","withdraw","redeem","totalAssets","convertToShares","convertToAssets"]
vaults=[("yulsafe","YulSafeERC20"),("plain","PlainPackedVault"),("lean","LeanVault"),("solady","SoladyVault")]
print(f"{'call':20s} {'YulSafe':>9s} {'Plain':>9s} {'Lean':>9s} {'Solady':>9s}")
for op in ops:
    row=f"{op:20s}"
    for v,c in vaults:
        out=subprocess.run(["forge","test","--isolate","--match-test",f"test_gas_{v}_{op}","-vvvv"],capture_output=True,text=True).stdout
        calls=[int(m.group(1)) for m in re.finditer(r"[├└]─ \[(\d+)\] %s::" % c, out)]
        row+=f" {calls[-1] if calls else '-':>9}"
    print(row)
