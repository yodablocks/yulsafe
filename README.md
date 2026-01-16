# YulSafe: Gas-Optimized ERC4626 Vault for zkSync Era

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.24-blue)](https://soliditylang.org/)
[![Tests](https://img.shields.io/badge/Tests-127%2F127_passing-brightgreen)](https://github.com/yourusername/yulsafe)

> **⚡ Up to 59% gas savings on view functions** through packed storage and Yul optimization

YulSafe is a production-grade, gas-optimized ERC4626-compliant vault built with Solady and Yul for maximum efficiency on zkSync Era. It serves as both a technical showcase of low-level EVM optimization techniques and a ready-to-use savings vault primitive.

## 🎯 Key Features

- **Gas Optimized**: Up to 59% savings on view functions through packed storage
- **Packed Storage**: Single SLOAD reads both totalAssets and totalSupply (~2100 gas saved per operation)
- **Security First**: First depositor attack protection, reentrancy guards, rounding protection
- **ERC4626 Compliant**: Full compatibility with DeFi composability standards
- **zkSync Native**: Optimized for zkSync Era's unique gas model
- **Heavily Documented**: Every Yul block explained for reviewability
- **Production Ready**: 100% test pass rate (127/127 tests), comprehensive property-based testing

## 📊 Gas Benchmarks

**All tests passing: 127/127 ✅** (62 unit + 16 benchmark + 16 invariant + 19 rounding fuzz + 14 inflation attack fuzz)

### View Functions (YulSafe Wins)

| Function | YulSafe | Solady ERC4626 | Savings |
|----------|---------|----------------|---------|
| `totalAssets()` | 2,321 | 5,621 | **59%** |
| `convertToShares()` | 4,775 | 8,073 | **41%** |
| `convertToAssets()` | 4,794 | 8,108 | **41%** |

### State-Changing Functions (Security Trade-off)

| Function | YulSafe | Solady ERC4626 | Difference |
|----------|---------|----------------|------------|
| `deposit()` (first) | 63,152 | 54,708 | +15% |
| `deposit()` (subsequent) | 175,623 | 106,008 | +66% |
| `withdraw()` | 61,265 | 54,578 | +12% |
| `redeem()` | 61,281 | 53,286 | +15% |
| `mint()` | 63,162 | 54,734 | +15% |

> **Note**: YulSafe's state-changing functions include security features that Solady's base ERC4626 does not:
> - ReentrancyGuard on all operations
> - Pausable functionality with owner checks
> - First depositor attack protection (MINIMUM_LIQUIDITY burn)
> - Custom name/symbol storage

**Deployment Cost**: 1,685,923 gas | **Contract Size**: 8,328 bytes

### Recent Improvements ✨

All compiler warnings resolved and test suite at 100% pass rate:
- ✅ Fixed unused constructor parameters (name/symbol now configurable)
- ✅ Resolved unreachable code warnings (proper use of named return variables)
- ✅ Fixed all test assertion edge cases (rounding, allowances, first depositor logic)
- ✅ Zero compiler errors, only intentional linter notes (ERC4626 `asset` naming)

See [fix-issue1.md](./fix-issue1.md) for detailed changelog.

**Key Optimizations:**
- Packed storage layout (96-bit totalAssets + 96-bit totalSupply in 1 slot)
- Assembly-optimized share calculations
- Direct LOG opcodes for events
- Custom errors in Yul (50-100 gas saved per revert)
- Optimized token transfers

## 🏗️ Architecture

```
┌──────────────────────────────────────────────────────────┐
│                      YulSafeERC20                        │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │         Core Vault Logic (Yul Assembly)            │  │
│  │                                                    │  │
│  │  • Packed Storage (96-bit values)                  │  │
│  │  • Assembly Math (mulDiv, rounding)                │  │
│  │  • Custom Errors (gas efficient)                   │  │
│  │  • Direct LOG opcodes                              │  │
│  └────────────────────────────────────────────────────┘  │
│                          │                               │
│  ┌────────────────────────────────────────────────────┐  │
│  │           Solady Dependencies                      │  │
│  │                                                    │  │
│  │  • ERC20 (Yul-optimized base)                      │  │
│  │  • Ownable (Owner management)                      │  │
│  │  • ReentrancyGuard (Attack prevention)             │  │
│  │  • SafeTransferLib (Safe ERC20 transfers)          │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

## 🚀 Quick Start

### Installation

```bash
# Clone repository
git clone https://github.com/yourusername/yulsafe
cd yulsafe

# Install dependencies
forge install

# Build
forge build

# Run tests
forge test

# Run tests with gas report
forge test --gas-report
```

### Usage Example

```solidity
// Deploy vault
YulSafeERC20 vault = new YulSafeERC20(
    address(underlyingToken),  // ERC20 asset
    "YulSafe Vault",           // Vault name
    "ysVAULT"                  // Vault symbol
);

// Deposit assets
underlyingToken.approve(address(vault), 1000e18);
uint256 shares = vault.deposit(1000e18, msg.sender);

// Withdraw assets
uint256 assets = vault.redeem(shares, msg.sender, msg.sender);
```

## 🔒 Security Features

### 1. First Depositor Attack Protection

**Problem**: Attacker deposits 1 wei, then donates massive amount to manipulate share price.

**Solution**: First deposit mints `MINIMUM_LIQUIDITY` (1000) shares to address(0), making price manipulation economically infeasible.

```solidity
// First deposit calculation
shares = assets - MINIMUM_LIQUIDITY;
_mint(address(0), MINIMUM_LIQUIDITY);  // Permanently locked
_mint(receiver, shares);
```

### 2. Rounding Protection

**Strategy**: All rounding favors the vault to prevent exploit accumulation.

- **Deposit**: Round **DOWN** shares minted (user gets slightly fewer shares)
- **Withdraw**: Round **UP** shares burned (user burns slightly more shares)

### 3. Reentrancy Protection

Uses Solady's gas-optimized `ReentrancyGuard` on all state-changing functions.

### 4. Comprehensive Input Validation

- Zero amount checks
- Zero address checks
- Capacity overflow checks (96-bit limit)
- Sufficient balance checks

## 🔧 Optimization Techniques

### Technique A: Assembly for Critical Operations

```solidity
assembly {
    // Load packed storage (single SLOAD)
    let packed := sload(_packedVaultState.slot)
    let _totalAssets := and(packed, MASK_96)
    let _totalSupply := and(shr(96, packed), MASK_96)

    // Calculate shares in pure Yul
    shares := div(mul(assets, _totalSupply), _totalAssets)
}
```

### Technique D: Direct SLOAD/SSTORE Optimization

**Packed Storage Layout:**
```
┌─────────────┬──────────────┬─────────────┐
│ totalAssets │ totalSupply  │  RESERVED   │
│   (96 bits) │  (96 bits)   │  (64 bits)  │
└─────────────┴──────────────┴─────────────┘
```

**Savings**: ~2100 gas per operation vs separate slots

### Technique G: Gas-Optimized Storage Layout

96-bit values support up to ~79 billion tokens (10^28), sufficient for any realistic vault.

### Technique I: Inline Assembly Math

```solidity
// Standard Solidity (with overhead)
shares = (assets * totalSupply) / totalAssets;

// Yul optimized (direct opcodes)
assembly {
    let numerator := mul(assets, _totalSupply)
    shares := div(numerator, _totalAssets)
}
```

## 🧪 Testing

```bash
# Run full test suite (127 tests, 100% passing ✅)
forge test

# Run with verbosity
forge test -vvv

# Run invariant tests with more depth
forge test --match-contract YulSafeInvariants --invariant-runs 1000

# Run fuzz tests with more runs
forge test --match-path "test/fuzz/*" --fuzz-runs 1000

# Generate gas report
forge test --gas-report
```

**Test Coverage**: 127/127 tests passing covering:

| Category | Tests | Description |
|----------|-------|-------------|
| Unit Tests | 62 | Core functionality, edge cases, ERC4626 compliance |
| Gas Benchmarks | 16 | Performance comparison vs Solady ERC4626 |
| Invariant Tests | 16 | Properties that must always hold (solvency, accounting) |
| Rounding Fuzz | 19 | Verify rounding always favors vault |
| Inflation Attack | 14 | First depositor attack resistance |

### Property-Based Testing

The test suite includes comprehensive **invariant and fuzz tests** verifying:

**Core Invariants:**
- `invariant_solvency` - Vault always has sufficient assets to back shares
- `invariant_noSharesWithoutAssets` - No shares exist without backing
- `invariant_minimumLiquidityLocked` - Dead shares permanently locked
- `invariant_noValueExtraction` - Cannot withdraw more than deposited

**Rounding Properties:**
- `deposit()` rounds DOWN shares (user gets fewer)
- `mint()` rounds UP assets (user pays more)
- `withdraw()` rounds UP shares burned
- `redeem()` rounds DOWN assets returned

**Inflation Attack Resistance:**
- Victim never receives 0 shares after donation attack
- Attacker permanently loses MINIMUM_LIQUIDITY shares
- Multiple victims all protected

## 🌐 Deployed Contracts (zkSync Sepolia)

| Contract | Address | Verified |
|----------|---------|----------|
| **YulSafe Vault** | [`0xdbB4C8d522Ba83a43ADa63f8555B3b47b40cc5ee`](https://sepolia.explorer.zksync.io/address/0xdbB4C8d522Ba83a43ADa63f8555B3b47b40cc5ee) | ✅ |
| **MockERC20 (mUSDC)** | [`0x23ad2ad90EAfA262DC18f341c17aFeEc8C691908`](https://sepolia.explorer.zksync.io/address/0x23ad2ad90EAfA262DC18f341c17aFeEc8C691908) | ✅ |

### Example Transactions

| Action | Transaction | Gas Used |
|--------|-------------|----------|
| Mint mUSDC | [`0x3d850bd3...`](https://sepolia.explorer.zksync.io/tx/0x3d850bd37eb9aef7693261cb6fe16658073da6de9accb687b3ed1cbc93f53689) | 109,794 |
| Approve Vault | [`0xff01cb34...`](https://sepolia.explorer.zksync.io/tx/0xff01cb34783cb267cbb45c94307adeeacd2f6f2928a902e5814cce6e0055c02d) | 89,852 |
| Deposit 500 mUSDC | [`0x0d919f4a...`](https://sepolia.explorer.zksync.io/tx/0x0d919f4a04f601c190d767708d57df4773b4829d3787b157db602a5792760417) | 132,354 |
| Withdraw 100 mUSDC | [`0xa4fa2d19...`](https://sepolia.explorer.zksync.io/tx/0xa4fa2d1905385e09e1d95ee273359ef5999bb5aada905a536b34c6fedb295de3) | 90,909 |

## ⚠️ Security Disclaimer

**YulSafe is an UNAUDITED educational and technical showcase project.**

DO NOT use in production without:
- Professional security audit
- Extensive additional testing
- Comprehensive risk assessment

### Known Limitations

- ✅ Supports standard ERC20 tokens only
- ❌ No support for fee-on-transfer tokens
- ❌ No support for rebasing tokens
- ❌ No yield generation strategies
- ❌ 96-bit capacity limit (~79 billion tokens max)

## 📜 License

MIT License

---

**Built with ⚡ for zkSync Era** | Showcasing advanced Solidity optimization techniques
