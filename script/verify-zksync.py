#!/usr/bin/env python3
"""Verify a zksolc-compiled contract on the zkSync Era block explorer.

foundry-zksync's `forge verify-contract --verifier zksync` sends settings keys
the explorer rejects, and the explorer forbids `remappings`. This script takes
the Standard JSON that forge would send, re-keys the vendored Solady sources
under the `solady/` import prefix, strips the unsupported keys, submits, and
polls until the explorer answers.

    FOUNDRY_PROFILE=zksync forge verify-contract --zksync --verifier zksync \
      --verifier-url https://explorer.sepolia.era.zksync.dev/contract_verification \
      <address> src/YulSafeERC20.sol:YulSafeERC20 --show-standard-json-input > input.json
    script/verify-zksync.py input.json <address> src/YulSafeERC20.sol:YulSafeERC20 <abi-encoded ctor args>

Compiler versions are pinned to what the `zksync` profile uses with
foundry-zksync v0.1.4: zksolc v1.5.15 and the patched solc zkVM-0.8.30-1.0.1.
"""
import json, sys, time, urllib.request
U="https://explorer.sepolia.era.zksync.dev/contract_verification"
inp, addr, name, ctor = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
j=json.load(open(inp)); st=j["settings"]
# the explorer forbids remappings: re-key vendored sources under the import prefix they are imported by
srcs={}
for k,v in j["sources"].items():
    nk=k.replace("lib/solady/src/","solady/").replace("lib/forge-std/src/","forge-std/")
    srcs[nk]=v
j["sources"]=srcs
clean={"language":"Solidity","sources":j["sources"],"settings":{
    "optimizer":{"enabled":True,"mode":st["optimizer"].get("mode","3")},
    "evmVersion":st.get("evmVersion"),
    "viaIR":st.get("viaIR",False),
    "outputSelection":{"*":{"*":["abi","evm.bytecode","evm.deployedBytecode","metadata"]}},
    "metadata":st.get("metadata",{}),
    "libraries":st.get("libraries",{}),
}}
if st.get("codegen"): clean["settings"]["codegen"]=st["codegen"]
body={"codeFormat":"solidity-standard-json-input","contractAddress":addr,"contractName":name,
      "sourceCode":clean,"compilerZksolcVersion":"v1.5.15","compilerSolcVersion":"zkVM-0.8.30-1.0.1",
      "optimizationUsed":True,"constructorArguments":ctor}
req=urllib.request.Request(U,data=json.dumps(body).encode(),headers={"Content-Type":"application/json"})
try:
    vid=urllib.request.urlopen(req).read().decode().strip()
except urllib.error.HTTPError as e:
    print("submit failed:", e.code, e.read().decode()[:400]); sys.exit(1)
print("verification id:", vid)
for _ in range(30):
    time.sleep(5)
    s=json.loads(urllib.request.urlopen(f"{U}/{vid}").read().decode())
    if s.get("status") in ("successful","failed"):
        print("status:", s["status"], "|", (s.get("error") or s.get("compilationErrors") or "")[:300] if s["status"]=="failed" else "")
        sys.exit(0 if s["status"]=="successful" else 1)
print("timed out"); sys.exit(1)
