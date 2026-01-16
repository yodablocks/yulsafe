// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {YulSafeERC20} from "../../src/YulSafeERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title RoundingProperties
/// @notice Fuzz tests verifying rounding always favors the vault
/// @dev These properties are critical for preventing value extraction attacks
///
/// Rounding Rules (ERC4626 security best practice):
/// - deposit:  rounds DOWN shares (user gets fewer shares)
/// - mint:     rounds UP assets (user pays more assets)
/// - withdraw: rounds UP shares burned (user burns more shares)
/// - redeem:   rounds DOWN assets (user gets fewer assets)
///
/// Run with: forge test --match-contract RoundingProperties -vvv
contract RoundingProperties is Test {
    YulSafeERC20 public vault;
    MockERC20 public asset;

    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);

    uint256 constant MINIMUM_LIQUIDITY = 1000;
    uint256 constant MAX_96_BITS = 0xFFFFFFFFFFFFFFFFFFFFFFFF;

    function setUp() public {
        asset = new MockERC20("Mock Token", "MOCK", 18);
        vault = new YulSafeERC20(address(asset), "YulSafe Vault", "ysVAULT");

        // Fund test users
        asset.mint(alice, type(uint96).max);
        asset.mint(bob, type(uint96).max);

        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        asset.approve(address(vault), type(uint256).max);

        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(address(vault), "Vault");
        vm.label(address(asset), "Asset");
    }

    /*//////////////////////////////////////////////////////////////
                        SETUP HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Make an initial deposit to get past first-deposit edge case
    function _setupVault() internal {
        vm.prank(alice);
        vault.deposit(100_000 ether, alice);
    }

    /// @notice Setup vault with specific share price ratio
    function _setupVaultWithRatio(uint256 assets, uint256 shares) internal {
        // First deposit establishes 1:1 ratio
        vm.prank(alice);
        vault.deposit(assets + MINIMUM_LIQUIDITY, alice);

        // Donate to vault to change the ratio (assets > shares = higher share price)
        if (assets > shares) {
            uint256 donation = assets - shares;
            asset.mint(address(vault), donation);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    DEPOSIT ROUNDING PROPERTIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Property: deposit returns shares <= previewDeposit
    /// @dev Deposit rounds DOWN - user receives at most the previewed amount
    function testFuzz_depositRoundsDown(uint96 assets) public {
        _setupVault();

        // Bound to valid range
        uint256 maxDeposit = vault.maxDeposit(bob);
        vm.assume(assets > 0 && assets <= maxDeposit);

        uint256 preview = vault.previewDeposit(assets);

        vm.prank(bob);
        uint256 actual = vault.deposit(assets, bob);

        assertLe(actual, preview, "VIOLATED: deposit() > previewDeposit()");
    }

    /// @notice Property: depositing assets gives shares that convert back to <= assets
    /// @dev User should never be able to deposit X and immediately redeem for > X
    function testFuzz_depositValueConservation(uint96 assets) public {
        _setupVault();

        uint256 maxDeposit = vault.maxDeposit(bob);
        vm.assume(assets > 0 && assets <= maxDeposit);

        vm.prank(bob);
        uint256 shares = vault.deposit(assets, bob);

        // The shares received should convert to at most the assets deposited
        uint256 assetsBack = vault.convertToAssets(shares);

        assertLe(assetsBack, assets, "VIOLATED: deposit created value");
    }

    /// @notice Property: deposit with varying share prices still rounds down
    function testFuzz_depositRoundsDownWithDonation(
        uint96 initialDeposit,
        uint96 donation,
        uint96 testDeposit
    ) public {
        // Setup with minimum viable amounts
        initialDeposit = uint96(bound(initialDeposit, MINIMUM_LIQUIDITY + 1, 1000 ether));
        donation = uint96(bound(donation, 0, 1000 ether));
        testDeposit = uint96(bound(testDeposit, 1, 1000 ether));

        // Initial deposit
        vm.prank(alice);
        vault.deposit(initialDeposit, alice);

        // Donate to change share price
        if (donation > 0) {
            asset.mint(address(vault), donation);
        }

        // Check preview vs actual
        uint256 preview = vault.previewDeposit(testDeposit);

        vm.prank(bob);
        uint256 actual = vault.deposit(testDeposit, bob);

        assertLe(actual, preview, "VIOLATED: deposit rounds up after donation");
    }

    /*//////////////////////////////////////////////////////////////
                      MINT ROUNDING PROPERTIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Property: mint requires assets >= previewMint
    /// @dev Mint rounds UP - user pays at least the previewed amount
    function testFuzz_mintRoundsUp(uint96 shares) public {
        _setupVault();

        uint256 maxMint = vault.maxMint(bob);
        vm.assume(shares > 0 && shares <= maxMint);

        uint256 preview = vault.previewMint(shares);

        vm.prank(bob);
        uint256 actual = vault.mint(shares, bob);

        assertGe(actual, preview, "VIOLATED: mint() < previewMint()");
    }

    /// @notice Property: minting shares costs assets that convert to <= shares
    /// @dev User pays assets worth at least the shares they receive
    function testFuzz_mintValueConservation(uint96 shares) public {
        _setupVault();

        uint256 maxMint = vault.maxMint(bob);
        vm.assume(shares > 0 && shares <= maxMint);

        vm.prank(bob);
        uint256 assets = vault.mint(shares, bob);

        // The assets paid should convert to at most the shares received
        uint256 sharesEquivalent = vault.convertToShares(assets);

        assertGe(sharesEquivalent, shares, "VIOLATED: mint undercharged");
    }

    /// @notice Property: mint rounds up even with skewed ratios
    function testFuzz_mintRoundsUpWithDonation(
        uint96 initialDeposit,
        uint96 donation,
        uint96 testShares
    ) public {
        initialDeposit = uint96(bound(initialDeposit, MINIMUM_LIQUIDITY + 1, 1000 ether));
        donation = uint96(bound(donation, 0, 1000 ether));
        testShares = uint96(bound(testShares, 1, 1000 ether));

        vm.prank(alice);
        vault.deposit(initialDeposit, alice);

        if (donation > 0) {
            asset.mint(address(vault), donation);
        }

        uint256 preview = vault.previewMint(testShares);

        vm.prank(bob);
        uint256 actual = vault.mint(testShares, bob);

        assertGe(actual, preview, "VIOLATED: mint rounds down after donation");
    }

    /*//////////////////////////////////////////////////////////////
                    WITHDRAW ROUNDING PROPERTIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Property: withdraw burns shares >= previewWithdraw
    /// @dev Withdraw rounds UP shares - user burns at least the previewed amount
    function testFuzz_withdrawRoundsUp(uint96 depositAmount, uint96 withdrawAmount) public {
        _setupVault();

        // Bob deposits first
        depositAmount = uint96(bound(depositAmount, 1 ether, 1000 ether));
        vm.prank(bob);
        vault.deposit(depositAmount, bob);

        // Withdraw bounded amount
        uint256 maxWithdraw = vault.maxWithdraw(bob);
        vm.assume(maxWithdraw > 0);
        withdrawAmount = uint96(bound(withdrawAmount, 1, maxWithdraw));

        uint256 preview = vault.previewWithdraw(withdrawAmount);

        vm.prank(bob);
        uint256 actual = vault.withdraw(withdrawAmount, bob, bob);

        assertGe(actual, preview, "VIOLATED: withdraw() < previewWithdraw()");
    }

    /// @notice Property: withdrawing assets burns shares worth >= assets
    /// @dev User burns shares that are worth at least the assets withdrawn
    function testFuzz_withdrawValueConservation(uint96 depositAmount, uint96 withdrawAmount) public {
        _setupVault();

        depositAmount = uint96(bound(depositAmount, 1 ether, 1000 ether));
        vm.prank(bob);
        vault.deposit(depositAmount, bob);

        uint256 maxWithdraw = vault.maxWithdraw(bob);
        vm.assume(maxWithdraw > 0);
        withdrawAmount = uint96(bound(withdrawAmount, 1, maxWithdraw));

        vm.prank(bob);
        uint256 sharesBurned = vault.withdraw(withdrawAmount, bob, bob);

        // Shares burned should be worth at least the assets withdrawn
        uint256 sharesValue = vault.convertToAssets(sharesBurned);

        assertGe(sharesValue, withdrawAmount, "VIOLATED: withdraw gave free assets");
    }

    /// @notice Property: withdraw rounds up shares even with donations
    function testFuzz_withdrawRoundsUpWithDonation(
        uint96 initialDeposit,
        uint96 bobDeposit,
        uint96 donation,
        uint96 withdrawAmount
    ) public {
        initialDeposit = uint96(bound(initialDeposit, MINIMUM_LIQUIDITY + 1, 1000 ether));
        bobDeposit = uint96(bound(bobDeposit, 1 ether, 1000 ether));
        donation = uint96(bound(donation, 0, 1000 ether));

        vm.prank(alice);
        vault.deposit(initialDeposit, alice);

        vm.prank(bob);
        vault.deposit(bobDeposit, bob);

        if (donation > 0) {
            asset.mint(address(vault), donation);
        }

        uint256 maxWithdraw = vault.maxWithdraw(bob);
        vm.assume(maxWithdraw > 0);
        withdrawAmount = uint96(bound(withdrawAmount, 1, maxWithdraw));

        uint256 preview = vault.previewWithdraw(withdrawAmount);

        vm.prank(bob);
        uint256 actual = vault.withdraw(withdrawAmount, bob, bob);

        assertGe(actual, preview, "VIOLATED: withdraw rounds down after donation");
    }

    /*//////////////////////////////////////////////////////////////
                      REDEEM ROUNDING PROPERTIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Property: redeem returns assets <= previewRedeem
    /// @dev Redeem rounds DOWN - user receives at most the previewed amount
    function testFuzz_redeemRoundsDown(uint96 depositAmount, uint96 redeemAmount) public {
        _setupVault();

        depositAmount = uint96(bound(depositAmount, 1 ether, 1000 ether));
        vm.prank(bob);
        vault.deposit(depositAmount, bob);

        uint256 maxRedeem = vault.maxRedeem(bob);
        vm.assume(maxRedeem > 0);
        redeemAmount = uint96(bound(redeemAmount, 1, maxRedeem));

        uint256 preview = vault.previewRedeem(redeemAmount);

        vm.prank(bob);
        uint256 actual = vault.redeem(redeemAmount, bob, bob);

        assertLe(actual, preview, "VIOLATED: redeem() > previewRedeem()");
    }

    /// @notice Property: redeeming shares gives assets <= share value
    /// @dev User receives assets worth at most the shares burned
    function testFuzz_redeemValueConservation(uint96 depositAmount, uint96 redeemAmount) public {
        _setupVault();

        depositAmount = uint96(bound(depositAmount, 1 ether, 1000 ether));
        vm.prank(bob);
        vault.deposit(depositAmount, bob);

        uint256 maxRedeem = vault.maxRedeem(bob);
        vm.assume(maxRedeem > 0);
        redeemAmount = uint96(bound(redeemAmount, 1, maxRedeem));

        vm.prank(bob);
        uint256 assets = vault.redeem(redeemAmount, bob, bob);

        // Assets received should be worth at most the shares burned
        uint256 assetsWorth = vault.convertToAssets(redeemAmount);

        assertLe(assets, assetsWorth, "VIOLATED: redeem gave extra assets");
    }

    /// @notice Property: redeem rounds down even with skewed ratios
    function testFuzz_redeemRoundsDownWithDonation(
        uint96 initialDeposit,
        uint96 bobDeposit,
        uint96 donation,
        uint96 redeemAmount
    ) public {
        initialDeposit = uint96(bound(initialDeposit, MINIMUM_LIQUIDITY + 1, 1000 ether));
        bobDeposit = uint96(bound(bobDeposit, 1 ether, 1000 ether));
        donation = uint96(bound(donation, 0, 1000 ether));

        vm.prank(alice);
        vault.deposit(initialDeposit, alice);

        vm.prank(bob);
        vault.deposit(bobDeposit, bob);

        if (donation > 0) {
            asset.mint(address(vault), donation);
        }

        uint256 maxRedeem = vault.maxRedeem(bob);
        vm.assume(maxRedeem > 0);
        redeemAmount = uint96(bound(redeemAmount, 1, maxRedeem));

        uint256 preview = vault.previewRedeem(redeemAmount);

        vm.prank(bob);
        uint256 actual = vault.redeem(redeemAmount, bob, bob);

        assertLe(actual, preview, "VIOLATED: redeem rounds up after donation");
    }

    /*//////////////////////////////////////////////////////////////
                      ROUNDTRIP PROPERTIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Property: deposit → redeem roundtrip loses at most minimal rounding
    /// @dev User should get back approximately what they deposited (minus small rounding)
    function testFuzz_depositRedeemRoundtrip(uint96 assets) public {
        _setupVault();

        uint256 maxDeposit = vault.maxDeposit(bob);
        assets = uint96(bound(assets, 1 ether, maxDeposit > 1000 ether ? 1000 ether : maxDeposit));

        uint256 balanceBefore = asset.balanceOf(bob);

        vm.startPrank(bob);
        uint256 shares = vault.deposit(assets, bob);
        uint256 assetsBack = vault.redeem(shares, bob, bob);
        vm.stopPrank();

        uint256 balanceAfter = asset.balanceOf(bob);
        uint256 loss = balanceBefore - balanceAfter;

        // Loss should be minimal - at most 2 wei per rounding operation
        assertLe(loss, 2, "VIOLATED: Roundtrip loss exceeds rounding tolerance");

        // User should never profit
        assertLe(assetsBack, assets, "VIOLATED: User profited from roundtrip");
    }

    /// @notice Property: mint → withdraw roundtrip loses at most minimal rounding
    function testFuzz_mintWithdrawRoundtrip(uint96 shares) public {
        _setupVault();

        uint256 maxMint = vault.maxMint(bob);
        shares = uint96(bound(shares, 1 ether, maxMint > 1000 ether ? 1000 ether : maxMint));

        vm.startPrank(bob);
        uint256 assetsIn = vault.mint(shares, bob);

        // Withdraw at most what we can (may be less than assetsIn due to rounding)
        uint256 maxWithdraw = vault.maxWithdraw(bob);
        uint256 withdrawAmount = assetsIn > maxWithdraw ? maxWithdraw : assetsIn;

        uint256 assetsOut = vault.withdraw(withdrawAmount, bob, bob);
        vm.stopPrank();

        // User should get back at most what they put in
        assertLe(assetsOut, assetsIn, "VIOLATED: User profited from mint-withdraw");
    }

    /// @notice Property: Multiple roundtrips don't accumulate profitable rounding
    function testFuzz_multipleRoundtripsNoProfit(uint96 amount, uint8 iterations) public {
        _setupVault();

        iterations = uint8(bound(iterations, 1, 10));
        amount = uint96(bound(amount, 1 ether, 100 ether));

        uint256 totalDeposited;
        uint256 totalWithdrawn;

        vm.startPrank(bob);

        for (uint256 i = 0; i < iterations; i++) {
            uint256 maxDeposit = vault.maxDeposit(bob);
            if (amount > maxDeposit) break;

            uint256 shares = vault.deposit(amount, bob);
            totalDeposited += amount;

            uint256 assetsBack = vault.redeem(shares, bob, bob);
            totalWithdrawn += assetsBack;
        }

        vm.stopPrank();

        assertLe(
            totalWithdrawn,
            totalDeposited,
            "VIOLATED: Multiple roundtrips extracted value"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    CONVERSION CONSISTENCY
    //////////////////////////////////////////////////////////////*/

    /// @notice Property: convertToShares then convertToAssets loses value
    /// @dev Round-trip conversion should never gain value
    function testFuzz_conversionRoundtripLosesValue(uint96 assets) public {
        _setupVault();

        vm.assume(assets > 0);

        uint256 shares = vault.convertToShares(assets);
        uint256 assetsBack = vault.convertToAssets(shares);

        assertLe(assetsBack, assets, "VIOLATED: Conversion roundtrip gained value");
    }

    /// @notice Property: convertToAssets then convertToShares loses value
    function testFuzz_reverseConversionRoundtripLosesValue(uint96 shares) public {
        _setupVault();

        vm.assume(shares > 0);

        uint256 assets = vault.convertToAssets(shares);
        uint256 sharesBack = vault.convertToShares(assets);

        assertLe(sharesBack, shares, "VIOLATED: Reverse conversion gained shares");
    }

    /*//////////////////////////////////////////////////////////////
                    FIRST DEPOSIT EDGE CASES
    //////////////////////////////////////////////////////////////*/

    /// @notice Property: First deposit costs MINIMUM_LIQUIDITY shares
    function testFuzz_firstDepositMinimumLiquidityCost(uint96 assets) public {
        assets = uint96(bound(assets, MINIMUM_LIQUIDITY + 1, 10000 ether));

        vm.prank(alice);
        uint256 shares = vault.deposit(assets, alice);

        // First depositor gets assets - MINIMUM_LIQUIDITY shares
        assertEq(shares, assets - MINIMUM_LIQUIDITY, "First deposit share calculation wrong");

        // MINIMUM_LIQUIDITY burned to address(0)
        assertEq(vault.balanceOf(address(0)), MINIMUM_LIQUIDITY, "Minimum liquidity not burned");
    }

    /// @notice Property: First deposit too small should revert
    function testFuzz_firstDepositTooSmallReverts(uint96 assets) public {
        assets = uint96(bound(assets, 1, MINIMUM_LIQUIDITY));

        vm.prank(alice);
        // Can revert with either InsufficientShares (assets == MINIMUM_LIQUIDITY)
        // or TotalSupplyOverflow from Solady's _mint (assets < MINIMUM_LIQUIDITY causes underflow)
        vm.expectRevert();
        vault.deposit(assets, alice);
    }
}
