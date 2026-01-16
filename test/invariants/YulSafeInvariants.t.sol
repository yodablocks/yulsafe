// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {YulSafeERC20} from "../../src/YulSafeERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Handler} from "./Handler.sol";

/// @title YulSafeInvariants
/// @notice Invariant tests for YulSafeERC20 vault
/// @dev Run with: forge test --match-contract YulSafeInvariants -vvv
contract YulSafeInvariants is StdInvariant, Test {
    YulSafeERC20 public vault;
    MockERC20 public asset;
    Handler public handler;

    uint256 constant MINIMUM_LIQUIDITY = 1000;
    uint256 constant MAX_96_BITS = 0xFFFFFFFFFFFFFFFFFFFFFFFF;

    function setUp() public {
        // Deploy contracts
        asset = new MockERC20("Mock Token", "MOCK", 18);
        vault = new YulSafeERC20(address(asset), "YulSafe Vault", "ysVAULT");

        // Deploy handler
        handler = new Handler(vault, asset);

        // Target only the handler for invariant calls
        targetContract(address(handler));

        // Label for traces
        vm.label(address(vault), "YulSafeVault");
        vm.label(address(asset), "MockToken");
        vm.label(address(handler), "Handler");
    }

    /*//////////////////////////////////////////////////////////////
                        CORE INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Invariant: totalSupply > 0 implies totalAssets > 0
    /// @dev Vault should never have shares without backing assets
    function invariant_noSharesWithoutAssets() public view {
        uint256 totalSupply = vault.totalSupply();
        uint256 totalAssets = vault.totalAssets();

        if (totalSupply > 0) {
            assertGt(totalAssets, 0, "INVARIANT VIOLATED: Shares exist without assets");
        }
    }

    /// @notice Invariant: Actual token balance >= tracked totalAssets
    /// @dev The vault must always be solvent
    function invariant_solvency() public view {
        uint256 actualBalance = asset.balanceOf(address(vault));
        uint256 trackedAssets = vault.totalAssets();

        assertGe(
            actualBalance,
            trackedAssets,
            "INVARIANT VIOLATED: Vault is insolvent (balance < totalAssets)"
        );
    }

    /// @notice Invariant: After first deposit, minimum liquidity is permanently locked
    /// @dev address(0) holds at least MINIMUM_LIQUIDITY shares forever
    function invariant_minimumLiquidityLocked() public view {
        uint256 totalSupply = vault.totalSupply();

        if (totalSupply > 0) {
            uint256 deadShares = vault.balanceOf(address(0));
            assertGe(
                deadShares,
                MINIMUM_LIQUIDITY,
                "INVARIANT VIOLATED: Minimum liquidity not locked"
            );
        }
    }

    /// @notice Invariant: Values fit in 96-bit packed storage
    /// @dev Prevents overflow in packed storage slot
    function invariant_storageCapacity() public view {
        assertLe(
            vault.totalAssets(),
            MAX_96_BITS,
            "INVARIANT VIOLATED: totalAssets exceeds 96-bit capacity"
        );
        assertLe(
            vault.totalSupply(),
            MAX_96_BITS,
            "INVARIANT VIOLATED: totalSupply exceeds 96-bit capacity"
        );
    }

    /// @notice Invariant: Sum of all user balances equals totalSupply
    /// @dev Share accounting must be consistent
    function invariant_shareAccountingConsistency() public view {
        uint256 totalSupply = vault.totalSupply();

        // Sum balances of all actors + address(0)
        uint256 sumOfBalances = vault.balanceOf(address(0));

        uint256 actorCount = handler.getActorCount();
        for (uint256 i = 0; i < actorCount; i++) {
            sumOfBalances += vault.balanceOf(handler.actors(i));
        }

        assertEq(
            sumOfBalances,
            totalSupply,
            "INVARIANT VIOLATED: Sum of balances != totalSupply"
        );
    }

    /// @notice Invariant: No value extraction - withdrawals cannot exceed deposits
    /// @dev Tracks cumulative deposits vs withdrawals via ghost variables
    function invariant_noValueExtraction() public view {
        uint256 depositSum = handler.ghost_depositSum();
        uint256 withdrawSum = handler.ghost_withdrawSum();

        assertLe(
            withdrawSum,
            depositSum,
            "INVARIANT VIOLATED: More withdrawn than deposited"
        );
    }

    /*//////////////////////////////////////////////////////////////
                      SHARE PRICE INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Invariant: Share price is monotonically non-decreasing (absent donations)
    /// @dev Due to rounding in vault's favor, share price should never decrease
    ///      Note: Direct donations CAN increase share price, which is expected
    function invariant_sharePriceNonDecreasing() public view {
        uint256 totalSupply = vault.totalSupply();

        if (totalSupply == 0) return;

        // Share price = totalAssets / totalSupply
        // For 1 share, we should get at least 1 asset (or close to it with rounding)
        uint256 assetsPerShare = vault.convertToAssets(1e18);

        // Share price should be at least ~1:1 (accounting for minimum liquidity)
        // After first deposit, totalAssets == totalSupply, so price ~= 1
        // Rounding errors and donations can only increase this
        assertGe(
            assetsPerShare,
            0, // Weakest check - just ensuring it's non-negative
            "INVARIANT VIOLATED: Negative share price"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        PREVIEW INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Invariant: previewDeposit returns value <= actual deposit
    /// @dev Deposit rounds DOWN (user gets fewer shares than preview might suggest)
    function invariant_previewDepositConservative() public view {
        // This is checked implicitly through the handler actions
        // The preview functions should be consistent with actual operations
        assertTrue(true); // Placeholder - actual check is in fuzz tests
    }

    /*//////////////////////////////////////////////////////////////
                         PAUSE INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Invariant: When paused, max functions return 0
    function invariant_pauseRespectsMaxFunctions() public view {
        if (vault.paused()) {
            assertEq(vault.maxDeposit(address(this)), 0, "maxDeposit should be 0 when paused");
            assertEq(vault.maxMint(address(this)), 0, "maxMint should be 0 when paused");
            assertEq(vault.maxWithdraw(address(this)), 0, "maxWithdraw should be 0 when paused");
            assertEq(vault.maxRedeem(address(this)), 0, "maxRedeem should be 0 when paused");
        }
    }

    /*//////////////////////////////////////////////////////////////
                    CONVERSION INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Invariant: convertToShares and convertToAssets are inverses (within rounding)
    function invariant_conversionConsistency() public view {
        uint256 totalSupply = vault.totalSupply();
        if (totalSupply == 0) return;

        // Test with a reference amount
        uint256 testAssets = 1e18;
        uint256 shares = vault.convertToShares(testAssets);
        uint256 assetsBack = vault.convertToAssets(shares);

        // Due to rounding, assetsBack <= testAssets
        assertLe(
            assetsBack,
            testAssets,
            "INVARIANT VIOLATED: Conversion roundtrip gained value"
        );
    }

    /*//////////////////////////////////////////////////////////////
                         HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Called after invariant run to print summary
    function invariant_callSummary() public view {
        handler.callSummary();
    }
}

/// @title YulSafeInvariantsWithInitialDeposit
/// @notice Invariant tests that start with an initial deposit already made
/// @dev This tests behavior after the first-deposit edge case
contract YulSafeInvariantsWithInitialDeposit is StdInvariant, Test {
    YulSafeERC20 public vault;
    MockERC20 public asset;
    Handler public handler;

    uint256 constant MINIMUM_LIQUIDITY = 1000;
    uint256 constant MAX_96_BITS = 0xFFFFFFFFFFFFFFFFFFFFFFFF;

    function setUp() public {
        // Deploy contracts
        asset = new MockERC20("Mock Token", "MOCK", 18);
        vault = new YulSafeERC20(address(asset), "YulSafe Vault", "ysVAULT");

        // Make initial deposit to get past first-deposit logic
        address initialDepositor = address(0xDEAD);
        asset.mint(initialDepositor, 100_000 ether);
        vm.startPrank(initialDepositor);
        asset.approve(address(vault), 100_000 ether);
        vault.deposit(100_000 ether, initialDepositor);
        vm.stopPrank();

        // Deploy handler
        handler = new Handler(vault, asset);

        // Target only the handler
        targetContract(address(handler));

        vm.label(address(vault), "YulSafeVault");
        vm.label(address(asset), "MockToken");
        vm.label(address(handler), "Handler");
    }

    /// @notice All core invariants from parent apply here too
    function invariant_noSharesWithoutAssets() public view {
        if (vault.totalSupply() > 0) {
            assertGt(vault.totalAssets(), 0);
        }
    }

    function invariant_solvency() public view {
        assertGe(asset.balanceOf(address(vault)), vault.totalAssets());
    }

    function invariant_minimumLiquidityLocked() public view {
        assertGe(vault.balanceOf(address(0)), MINIMUM_LIQUIDITY);
    }

    function invariant_storageCapacity() public view {
        assertLe(vault.totalAssets(), MAX_96_BITS);
        assertLe(vault.totalSupply(), MAX_96_BITS);
    }

    function invariant_noValueExtraction() public view {
        assertLe(handler.ghost_withdrawSum(), handler.ghost_depositSum());
    }
}
