# Security Policy

## ⚠️ Security Status

**YulSafe is an UNAUDITED educational project and technical showcase.**

This contract has NOT been reviewed by security professionals and should NOT be used in production environments without a comprehensive professional audit.

## 🔒 Security Features Implemented

### 1. Donation and Inflation Attack Resistance

**Attack Vector**: In a vault that prices shares from `asset.balanceOf(vault)`, an attacker deposits a minimal amount (1 wei), then transfers a large amount of tokens directly to the vault. The share price jumps, and the next depositor's shares round down to 0 while the attacker redeems their deposit plus the victim's.

**Mitigation, first layer**: YulSafe never reads its own token balance. The share price is derived from the packed `totalAssets` field, which only changes inside `deposit`, `mint`, `withdraw` and `redeem`, by exactly the amount transferred in or out. A direct transfer to the contract leaves both `totalAssets` and `totalSupply` untouched, so the price does not move and the victim loses nothing. The invariant `invariant_donationsDoNotMovePrice` checks this after every donation in the handler, and `testFuzz_attackCostExceedsPotentialGain` checks the victim's loss is exactly zero.

**Mitigation, second layer**: On the first deposit, `MINIMUM_LIQUIDITY` (1000) shares are permanently minted to `address(0)`. This closes the remaining rounding edge case on a tiny first deposit and makes any attempt cost the attacker those shares for good.

```solidity
// First deposit
shares = assets - MINIMUM_LIQUIDITY;
_mint(address(0), MINIMUM_LIQUIDITY);  // Locked forever
_mint(receiver, shares);
```

**Trade-off**: Tokens sent directly to the vault are stranded. There is deliberately no sweep function, because an owner-callable sweep would turn "no stranded value" into a trust assumption.

**Status**: ✅ Implemented and invariant-tested

### 2. Reentrancy Protection

**Attack Vector**: Malicious tokens or callbacks could attempt to reenter vault functions during external calls.

**Mitigation**: Uses Solady's gas-optimized `ReentrancyGuard` modifier on all state-changing functions.

**Status**: ✅ Implemented via `nonReentrant` modifier

### 3. Rounding Protection

**Attack Vector**: Repeated small deposits/withdrawals could accumulate rounding errors in attacker's favor.

**Mitigation**: All rounding favors the vault:
- **Deposits**: Shares minted are rounded DOWN
- **Withdrawals**: Shares burned are rounded UP

**Status**: ✅ Implemented in assembly math

### 4. Input Validation

All functions validate:
- Zero amounts (reverts with `ZeroAmount()`)
- Zero addresses (reverts with `ZeroAddress()`)
- Sufficient balances (reverts with `InsufficientShares()` / `InsufficientAssets()`)
- Capacity limits (reverts with `ExceedsMaxCapacity()`)

**Status**: ✅ Implemented in Yul assembly

### 5. Pausability

Owner can pause deposits/withdrawals in emergency situations.

**Status**: ✅ Implemented with `onlyOwner` protection

## ❌ Known Limitations

### 1. Standard ERC20 Tokens Only

**Limitation**: The vault does NOT support:
- Fee-on-transfer tokens (e.g., some DeFi tokens that take fees on transfer)
- Rebasing tokens (e.g., stETH, aTokens that change balance automatically)
- Tokens with callbacks (e.g., ERC777)

**Risk**: Using incompatible tokens will lead to accounting errors and potential loss of funds.

**Recommendation**: Only use standard ERC20 tokens (e.g., USDC, DAI, WETH).

### 2. No Yield Generation

**Limitation**: This is a pure savings vault with no integrated yield strategies.

**Risk**: Assets sit idle and do not generate returns.

**Recommendation**: For yield-generating vaults, consider Yearn, Aave, or Compound protocols.

### 3. 96-bit Capacity Limit

**Limitation**: Both `totalAssets` and `totalSupply` are limited to 96 bits (~79 billion tokens or 10^28).

**Risk**: Vaults with extremely high decimal tokens could theoretically overflow.

**Mitigation**: Overflow checks are implemented and will revert with `ExceedsMaxCapacity()`.

**Recommendation**: Suitable for all realistic token amounts. Even USDC with 6 decimals supports ~79 trillion tokens.

### 4. No Flash Loan Protection

**Limitation**: No specific protection against flash loan attacks.

**Risk**: Potential manipulation of share price within a single transaction.

**Mitigation**: Share price cannot be moved by donations at all, and every rounding decision favors the vault, so the usual flash-loan path (borrow, donate, deposit, withdraw) has nothing to exploit. There is no explicit same-block guard.

**Status**: ⚠️ Not explicitly protected beyond existing mechanisms

### 5. Owner Centralization

**Limitation**: Owner has significant control:
- Can pause/unpause the vault
- Can transfer ownership

**Risk**: Compromised owner key could freeze user funds via pause.

**Recommendation**: Use multi-sig for owner address in production.

## 🐛 Reporting Vulnerabilities

If you discover a security vulnerability in YulSafe:

1. **DO NOT** open a public issue
2. Email: [your-security-email@example.com]
3. Include:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

We will respond within 48 hours and coordinate disclosure.

## 🎯 Audit Status

Nothing in this repository has been audited. The table records what evidence exists in the repo for each concern, so a reviewer can see which claims are backed by tests and which are still intentions. "Evidence" means automated checks that run in CI; it is not a substitute for an independent review.

| Concern | Evidence in the repository | Still needs |
|---|---|---|
| Arithmetic overflow and underflow | Explicit input bounds on every path, `YulSafeHardening.t.sol` covers wrapping inputs and the first-deposit edge | Line-by-line review of the Yul arithmetic |
| Reentrancy | Solady `ReentrancyGuard` on all state changes, shares minted before the token transfer, hooked-token test proves views stay consistent mid-call | Review against ERC777-style and callback tokens |
| Price manipulation | `invariant_donationsDoNotMovePrice` and `invariant_sharePriceNonDecreasing`, 25,600 handler calls per run | Independent review |
| First-depositor attack | `fuzz/InflationAttack.t.sol`, 14 tests, victim loss asserted to be exactly zero | None beyond audit |
| Rounding | `fuzz/RoundingProperties.t.sol`, 19 tests, plus the price-never-decreases invariant | None beyond audit |
| ERC4626 compliance | Preview functions equal the real call, `withdraw(maxWithdraw)` and `redeem(maxRedeem)` never revert, fuzzed | A third-party property suite such as [a16z/erc4626-tests](https://github.com/a16z/erc4626-tests) |
| Error selectors | Every hard-coded selector checked against the declared error in tests. A wrong `ExceedsMaxCapacity` selector was found and fixed this way | None |
| Access control | Unit tests for owner-only pause and unpause | Adversarial review, multisig deployment guidance |
| Pausability edge cases | Unit tests, `invariant_pauseRespectsMaxFunctions` | Review of funds locked under an indefinite pause |
| Packed storage correctness | `invariant_storageCapacity`, `invariant_shareAccountingConsistency`, solvency invariant | This is the core of any audit |
| Assembly correctness | Byte-identical output from two independent compilers (solc and oksolc) on the via-IR path, full suite on three CI pipelines | Manual review of every Yul block |
| Event emission accuracy | Events asserted in unit tests | Review of the raw `log3`/`log4` layouts against the ERC4626 signatures |
| Gas trade-offs | Gas measured on the EVM and on EraVM, both published in the README | None |

## 📚 Security Resources

### References
- [EIP-4626 Security Considerations](https://eips.ethereum.org/EIPS/eip-4626#security-considerations)
- [Inflation Attack Overview](https://mixbytes.io/blog/overview-of-the-inflation-attack)
- [ERC4626 Inflation Attack Mitigation](https://ethereum-magicians.org/t/address-eip-4626-inflation-attacks-with-virtual-shares-and-assets/12677)
- [Solady Security](https://github.com/Vectorized/solady#security)

### Alternative Audited Implementations
- [OpenZeppelin ERC4626](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/extensions/ERC4626.sol)
- [Solmate ERC4626](https://github.com/transmissions11/solmate/blob/main/src/mixins/ERC4626.sol)
- [Yearn V3 Vaults](https://github.com/yearn/yearn-vaults-v3)

## 📜 Disclaimer

THIS SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

---

**Last Updated**: January 2026
**Version**: 1.0.0
