# Security Policy

## ⚠️ Security Status

**YulSafe is an UNAUDITED educational project and technical showcase.**

This contract has NOT been reviewed by security professionals and should NOT be used in production environments without a comprehensive professional audit.

## 🔒 Security Features Implemented

### 1. First Depositor Inflation Attack Protection

**Attack Vector**: An attacker could deposit a minimal amount (1 wei), then directly transfer a large amount of tokens to the vault to inflate the share price, causing subsequent depositors to receive 0 shares due to rounding.

**Mitigation**: On first deposit, `MINIMUM_LIQUIDITY` (1000) shares are permanently minted to `address(0)`, making this attack economically infeasible.

```solidity
// First deposit
shares = assets - MINIMUM_LIQUIDITY;
_mint(address(0), MINIMUM_LIQUIDITY);  // Locked forever
_mint(receiver, shares);
```

**Status**: ✅ Implemented and tested

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

**Mitigation**: First depositor protection + rounding protection make most attacks unprofitable.

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

## 🎯 Audit Checklist

Before production use, a professional audit should verify:

- [ ] Arithmetic overflow/underflow scenarios
- [ ] Reentrancy attack vectors
- [ ] Price manipulation attacks
- [ ] First depositor attack protection effectiveness
- [ ] Rounding error accumulation
- [ ] Access control mechanisms
- [ ] Pausability edge cases
- [ ] ERC4626 standard compliance
- [ ] Gas optimization safety trade-offs
- [ ] Packed storage correctness
- [ ] Assembly code correctness
- [ ] Event emission accuracy
- [ ] Error selector correctness

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
