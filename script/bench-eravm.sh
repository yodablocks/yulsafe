#!/usr/bin/env zsh
# Measures YulSafe against Solady's ERC4626 on EraVM using real transaction
# receipts, because forge's gas report cannot attribute gas per call on zkSync.
#
# Requires foundry-zksync (forge, cast, anvil-zksync on PATH).
#
#   anvil-zksync --port 8011 &
#   script/bench-eravm.sh
#
# Optional: RPC and PK environment variables override the local node and the
# first anvil-zksync rich account.
set -e
cd "$(dirname "$0")/.."
RPC=${RPC:-http://127.0.0.1:8011}
PK=${PK:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
export FOUNDRY_PROFILE=zksync
ME=$(cast wallet address --private-key $PK)

deploy() { forge create --zksync --rpc-url $RPC --private-key $PK --broadcast "$@" 2>&1 | grep "Deployed to" | awk '{print $NF}'; }
gas_used() { cast send --rpc-url $RPC --private-key $PK --json "$@" 2>/dev/null | python3 -c 'import sys,json; print(int(json.load(sys.stdin)["gasUsed"],16))'; }
estimate() { cast estimate --rpc-url $RPC --from $ME "$@" 2>/dev/null; }
row() { printf "%-20s %10s %10s %10s %10s %10s\n" "$1" "$2" "$3" "$4" "$5" "$6"; }

ASSET=$(deploy test/mocks/MockERC20.sol:MockERC20 --constructor-args "Test Token" "TEST" 18)
YS=$(deploy src/YulSafeERC20.sol:YulSafeERC20 --constructor-args $ASSET "YulSafe Vault" "ysVAULT")
SO=$(deploy test/mocks/SoladyVault.sol:SoladyVault --constructor-args $ASSET "Solady Vault" "sVAULT")
PL=$(deploy test/mocks/PlainPackedVault.sol:PlainPackedVault --constructor-args $ASSET "Plain Vault" "pVAULT")
LN=$(deploy test/mocks/LeanVault.sol:LeanVault --constructor-args $ASSET "Lean Vault" "lVAULT")
L2=$(deploy test/mocks/LeanVault2.sol:LeanVault2 --constructor-args $ASSET "Lean Vault 2" "lVAULT2")
MAX=0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
gas_used $ASSET "mint(address,uint256)" $ME 1000000000000000000000000 >/dev/null
gas_used $ASSET "approve(address,uint256)" $YS $MAX >/dev/null
gas_used $ASSET "approve(address,uint256)" $SO $MAX >/dev/null
gas_used $ASSET "approve(address,uint256)" $PL $MAX >/dev/null
gas_used $ASSET "approve(address,uint256)" $LN $MAX >/dev/null
gas_used $ASSET "approve(address,uint256)" $L2 $MAX >/dev/null

D1=10000000000000000000000   # 10,000 tokens
D2=1000000000000000000000    #  1,000 tokens
row "function" "YulSafe" "Solady" "Plain" "Lean" "Lean2"
row "first_deposit"      "$(gas_used $YS 'deposit(uint256,address)' $D1 $ME)" "$(gas_used $SO 'deposit(uint256,address)' $D1 $ME)" "$(gas_used $PL 'deposit(uint256,address)' $D1 $ME)" "$(gas_used $LN 'deposit(uint256,address)' $D1 $ME)" "$(gas_used $L2 'deposit(uint256,address)' $D1 $ME)"
gas_used $YS 'deposit(uint256,address)' $D2 $ME >/dev/null; gas_used $SO 'deposit(uint256,address)' $D2 $ME >/dev/null; gas_used $PL 'deposit(uint256,address)' $D2 $ME >/dev/null; gas_used $LN 'deposit(uint256,address)' $D2 $ME >/dev/null; gas_used $L2 'deposit(uint256,address)' $D2 $ME >/dev/null
row "subsequent_deposit" "$(gas_used $YS 'deposit(uint256,address)' $D2 $ME)" "$(gas_used $SO 'deposit(uint256,address)' $D2 $ME)" "$(gas_used $PL 'deposit(uint256,address)' $D2 $ME)" "$(gas_used $LN 'deposit(uint256,address)' $D2 $ME)" "$(gas_used $L2 'deposit(uint256,address)' $D2 $ME)"
row "mint"               "$(gas_used $YS 'mint(uint256,address)' $D2 $ME)" "$(gas_used $SO 'mint(uint256,address)' $D2 $ME)" "$(gas_used $PL 'mint(uint256,address)' $D2 $ME)" "$(gas_used $LN 'mint(uint256,address)' $D2 $ME)" "$(gas_used $L2 'mint(uint256,address)' $D2 $ME)"
row "withdraw"           "$(gas_used $YS 'withdraw(uint256,address,address)' $D2 $ME $ME)" "$(gas_used $SO 'withdraw(uint256,address,address)' $D2 $ME $ME)" "$(gas_used $PL 'withdraw(uint256,address,address)' $D2 $ME $ME)" "$(gas_used $LN 'withdraw(uint256,address,address)' $D2 $ME $ME)" "$(gas_used $L2 'withdraw(uint256,address,address)' $D2 $ME $ME)"
row "redeem"             "$(gas_used $YS 'redeem(uint256,address,address)' $D2 $ME $ME)" "$(gas_used $SO 'redeem(uint256,address,address)' $D2 $ME $ME)" "$(gas_used $PL 'redeem(uint256,address,address)' $D2 $ME $ME)" "$(gas_used $LN 'redeem(uint256,address,address)' $D2 $ME $ME)" "$(gas_used $L2 'redeem(uint256,address,address)' $D2 $ME $ME)"
echo "eth_estimateGas for views (includes zkSync's fixed per-transaction overhead):"
row "totalAssets"        "$(estimate $YS 'totalAssets()')" "$(estimate $SO 'totalAssets()')" "$(estimate $PL 'totalAssets()')" "$(estimate $LN 'totalAssets()')" "$(estimate $L2 'totalAssets()')"
row "convertToShares"    "$(estimate $YS 'convertToShares(uint256)' $D2)" "$(estimate $SO 'convertToShares(uint256)' $D2)" "$(estimate $PL 'convertToShares(uint256)' $D2)" "$(estimate $LN 'convertToShares(uint256)' $D2)" "$(estimate $L2 'convertToShares(uint256)' $D2)"
row "convertToAssets"    "$(estimate $YS 'convertToAssets(uint256)' $D2)" "$(estimate $SO 'convertToAssets(uint256)' $D2)" "$(estimate $PL 'convertToAssets(uint256)' $D2)" "$(estimate $LN 'convertToAssets(uint256)' $D2)" "$(estimate $L2 'convertToAssets(uint256)' $D2)"
