// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {YulSafeERC20} from "../src/YulSafeERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {HookedERC20} from "./mocks/HookedERC20.sol";

/// @title YulSafeHardening
/// @notice Pins the input bounds, rounding agreement and view consistency
///         guarantees of the vault. Each test here failed, or was unreachable,
///         before the corresponding fix in the contract.
contract YulSafeHardening is Test {
    YulSafeERC20 public vault;
    MockERC20 public asset;

    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);

    uint256 constant MINIMUM_LIQUIDITY = 1000;
    uint256 constant MAX_96_BITS = 0xFFFFFFFFFFFFFFFFFFFFFFFF;

    function setUp() public {
        asset = new MockERC20("Mock Token", "MOCK", 18);
        vault = new YulSafeERC20(address(asset), "YulSafe Vault", "ysVAULT");

        asset.mint(alice, 1_000_000 ether);
        asset.mint(bob, 1_000_000 ether);
        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        asset.approve(address(vault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                         FIRST DEPOSIT BOUNDS
    //////////////////////////////////////////////////////////////*/

    /// @notice A first deposit at or below the locked liquidity must revert cleanly
    function testFuzz_firstDepositBelowMinimumReverts(uint256 assets) public {
        assets = bound(assets, 1, MINIMUM_LIQUIDITY);
        vm.prank(alice);
        vm.expectRevert(YulSafeERC20.InsufficientShares.selector);
        vault.deposit(assets, alice);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
    }

    /// @notice A first mint that would overflow the packed lanes must revert
    function test_firstMintAboveCapacityReverts() public {
        vm.prank(alice);
        vm.expectRevert(YulSafeERC20.ExceedsMaxCapacity.selector);
        vault.mint(MAX_96_BITS + 1, alice);

        vm.prank(alice);
        vm.expectRevert(YulSafeERC20.ExceedsMaxCapacity.selector);
        vault.mint(MAX_96_BITS - MINIMUM_LIQUIDITY + 1, alice);
    }

    /// @notice A mint with a share count large enough to wrap the multiplication must revert
    function test_mintHugeSharesReverts() public {
        vm.prank(alice);
        vault.deposit(10 ether, alice);

        uint256 wrapping = type(uint256).max - vault.totalSupply() + 1;
        vm.prank(bob);
        vm.expectRevert(YulSafeERC20.ExceedsMaxCapacity.selector);
        vault.mint(wrapping, bob);
    }

    /// @notice Redeeming more shares than exist must revert before any arithmetic
    function test_redeemMoreThanSupplyReverts() public {
        vm.prank(alice);
        vault.deposit(10 ether, alice);

        uint256 supply = vault.totalSupply();
        vm.prank(alice);
        vm.expectRevert(YulSafeERC20.InsufficientShares.selector);
        vault.redeem(supply + 1, alice, alice);
    }

    /*//////////////////////////////////////////////////////////////
                    PREVIEW AND ACTUAL MUST AGREE
    //////////////////////////////////////////////////////////////*/

    function _seed(uint256 first, uint256 second) internal {
        vm.prank(alice);
        vault.deposit(first, alice);
        vm.prank(bob);
        vault.deposit(second, bob);
    }

    /// @notice previewMint must charge exactly what mint charges, including exact divisions
    function testFuzz_previewMintMatchesMint(uint256 first, uint256 second, uint256 shares) public {
        first = bound(first, MINIMUM_LIQUIDITY + 1, 1_000 ether);
        second = bound(second, 1, 1_000 ether);
        _seed(first, second);
        shares = bound(shares, 1, 1_000 ether);

        uint256 previewed = vault.previewMint(shares);
        vm.prank(bob);
        uint256 charged = vault.mint(shares, bob);
        assertEq(charged, previewed, "mint charged a different amount than previewMint");
    }

    /// @notice previewWithdraw must burn exactly what withdraw burns, including exact divisions
    function testFuzz_previewWithdrawMatchesWithdraw(uint256 first, uint256 second, uint256 assets)
        public
    {
        first = bound(first, MINIMUM_LIQUIDITY + 1, 1_000 ether);
        second = bound(second, 1, 1_000 ether);
        _seed(first, second);
        assets = bound(assets, 1, vault.maxWithdraw(bob));
        if (assets == 0) return;

        uint256 previewed = vault.previewWithdraw(assets);
        vm.prank(bob);
        uint256 burned = vault.withdraw(assets, bob, bob);
        assertEq(burned, previewed, "withdraw burned a different amount than previewWithdraw");
    }

    /// @notice An exact division must not cost an extra share or an extra asset
    function test_exactDivisionRoundsToExact() public {
        _seed(1_000 ether, 1_000 ether);
        // Price is exactly 1, so 5 ether of assets is exactly 5 ether of shares
        assertEq(vault.previewWithdraw(5 ether), 5 ether);
        assertEq(vault.previewMint(5 ether), 5 ether);

        vm.prank(bob);
        assertEq(vault.withdraw(5 ether, bob, bob), 5 ether);
        vm.prank(bob);
        assertEq(vault.mint(5 ether, bob), 5 ether);
    }

    /// @notice ERC4626: withdraw(maxWithdraw(owner)) must not revert
    function testFuzz_withdrawMaxNeverReverts(uint256 first, uint256 second, uint256 extra) public {
        first = bound(first, MINIMUM_LIQUIDITY + 1, 1_000 ether);
        second = bound(second, 1, 1_000 ether);
        extra = bound(extra, 1, 1_000 ether);
        _seed(first, second);
        // Move the price off 1:1 so the rounding paths are exercised
        vm.prank(alice);
        vault.mint(extra, alice);

        uint256 max = vault.maxWithdraw(bob);
        if (max == 0) return;
        uint256 balanceBefore = vault.balanceOf(bob);
        vm.prank(bob);
        uint256 burned = vault.withdraw(max, bob, bob);
        assertLe(burned, balanceBefore, "withdraw of maxWithdraw needed more shares than owned");
    }

    /// @notice ERC4626: redeem(maxRedeem(owner)) must not revert
    function testFuzz_redeemMaxNeverReverts(uint256 first, uint256 second) public {
        first = bound(first, MINIMUM_LIQUIDITY + 1, 1_000 ether);
        second = bound(second, 1, 1_000 ether);
        _seed(first, second);

        uint256 max = vault.maxRedeem(bob);
        vm.prank(bob);
        vault.redeem(max, bob, bob);
        assertEq(vault.balanceOf(bob), 0);
    }

    /*//////////////////////////////////////////////////////////////
                 VIEW CONSISTENCY DURING EXTERNAL CALLS
    //////////////////////////////////////////////////////////////*/

    /// @notice A token hook that reads the price mid-deposit must see the final,
    ///         consistent price, never totalAssets and totalSupply from different
    ///         moments. This is what a read-only reentrancy attack relies on.
    function testFuzz_priceSeenFromTokenHookIsConsistent(uint256 first, uint256 second) public {
        first = bound(first, MINIMUM_LIQUIDITY + 1, 1_000 ether);
        second = bound(second, 1, 1_000 ether);

        HookedERC20 hooked = new HookedERC20();
        YulSafeERC20 hookedVault = new YulSafeERC20(address(hooked), "Hooked Vault", "hV");
        hooked.setVault(address(hookedVault));
        hooked.mint(alice, 1_000_000 ether);
        hooked.mint(bob, 1_000_000 ether);
        vm.prank(alice);
        hooked.approve(address(hookedVault), type(uint256).max);
        vm.prank(bob);
        hooked.approve(address(hookedVault), type(uint256).max);

        vm.prank(alice);
        hookedVault.deposit(first, alice);

        uint256 callsBefore = hooked.hookCalls();
        vm.prank(bob);
        hookedVault.deposit(second, bob);
        assertGt(hooked.hookCalls(), callsBefore, "hook did not run");

        uint256 priceAfter = hookedVault.convertToAssets(1e18);
        assertEq(hooked.priceSeenInHook(), priceAfter, "hook observed a transient price");
        assertEq(hooked.totalsRatioSeenInHook(), priceAfter, "hook observed inconsistent totals");
    }
}
