// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {YulSafeERC20} from "../../src/YulSafeERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title Handler
/// @notice Wrapper contract that performs bounded actions on the vault for invariant testing
/// @dev Foundry will call random functions on this handler during invariant runs
contract Handler is Test {
    YulSafeERC20 public vault;
    MockERC20 public asset;

    // Track actors for realistic multi-user scenarios
    address[] public actors;
    address internal currentActor;

    // Ghost variables to track cumulative state
    uint256 public ghost_depositSum;
    uint256 public ghost_withdrawSum;
    uint256 public ghost_mintSharesSum;
    uint256 public ghost_redeemSharesSum;

    // Call counters for debugging
    uint256 public calls_deposit;
    uint256 public calls_withdraw;
    uint256 public calls_mint;
    uint256 public calls_redeem;

    uint256 constant MINIMUM_LIQUIDITY = 1000;
    uint256 constant MAX_96_BITS = 0xFFFFFFFFFFFFFFFFFFFFFFFF;

    modifier useActor(uint256 actorIndexSeed) {
        currentActor = actors[bound(actorIndexSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(YulSafeERC20 _vault, MockERC20 _asset) {
        vault = _vault;
        asset = _asset;

        // Create test actors
        actors.push(address(0x1001));
        actors.push(address(0x1002));
        actors.push(address(0x1003));
        actors.push(address(0x1004));
        actors.push(address(0x1005));

        // Label actors
        for (uint256 i = 0; i < actors.length; i++) {
            vm.label(actors[i], string.concat("Actor", vm.toString(i)));
        }

        // Fund all actors with assets
        for (uint256 i = 0; i < actors.length; i++) {
            asset.mint(actors[i], type(uint96).max);
            vm.prank(actors[i]);
            asset.approve(address(vault), type(uint256).max);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            HANDLER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Bounded deposit action
    function deposit(uint256 actorSeed, uint256 assets) external useActor(actorSeed) {
        // Bound assets to valid range
        uint256 currentAssets = vault.totalAssets();
        uint256 maxDeposit = MAX_96_BITS > currentAssets ? MAX_96_BITS - currentAssets : 0;

        // First deposit needs > MINIMUM_LIQUIDITY, subsequent deposits need > 0
        uint256 minDeposit = vault.totalSupply() == 0 ? MINIMUM_LIQUIDITY + 1 : 1;

        if (maxDeposit <= minDeposit) return; // Skip if no room

        assets = bound(assets, minDeposit, maxDeposit);

        // Ensure actor has enough balance
        if (asset.balanceOf(currentActor) < assets) return;

        uint256 shares = vault.deposit(assets, currentActor);

        // Update ghost variables
        ghost_depositSum += assets;
        ghost_mintSharesSum += shares;
        calls_deposit++;
    }

    /// @notice Bounded mint action
    function mint(uint256 actorSeed, uint256 shares) external useActor(actorSeed) {
        // Bound shares to valid range
        uint256 currentSupply = vault.totalSupply();
        uint256 maxMint = MAX_96_BITS > currentSupply ? MAX_96_BITS - currentSupply : 0;

        if (maxMint == 0) return;

        shares = bound(shares, 1, maxMint);

        // Calculate assets needed
        uint256 assetsNeeded = vault.previewMint(shares);

        // First mint adds MINIMUM_LIQUIDITY
        if (currentSupply == 0) {
            assetsNeeded = shares + MINIMUM_LIQUIDITY;
        }

        // Ensure actor has enough balance
        if (asset.balanceOf(currentActor) < assetsNeeded) return;

        uint256 assets = vault.mint(shares, currentActor);

        // Update ghost variables
        ghost_depositSum += assets;
        ghost_mintSharesSum += shares;
        calls_mint++;
    }

    /// @notice Bounded withdraw action
    function withdraw(uint256 actorSeed, uint256 assets) external useActor(actorSeed) {
        uint256 maxWithdraw = vault.maxWithdraw(currentActor);

        if (maxWithdraw == 0) return;

        assets = bound(assets, 1, maxWithdraw);

        uint256 shares = vault.withdraw(assets, currentActor, currentActor);

        // Update ghost variables
        ghost_withdrawSum += assets;
        ghost_redeemSharesSum += shares;
        calls_withdraw++;
    }

    /// @notice Bounded redeem action
    function redeem(uint256 actorSeed, uint256 shares) external useActor(actorSeed) {
        uint256 maxRedeem = vault.maxRedeem(currentActor);

        if (maxRedeem == 0) return;

        shares = bound(shares, 1, maxRedeem);

        uint256 assets = vault.redeem(shares, currentActor, currentActor);

        // Update ghost variables
        ghost_withdrawSum += assets;
        ghost_redeemSharesSum += shares;
        calls_redeem++;
    }

    /// @notice Transfer shares between actors (tests share accounting)
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[bound(fromSeed, 0, actors.length - 1)];
        address to = actors[bound(toSeed, 0, actors.length - 1)];

        if (from == to) return;

        uint256 balance = vault.balanceOf(from);
        if (balance == 0) return;

        amount = bound(amount, 1, balance);

        vm.prank(from);
        vault.transfer(to, amount);
    }

    /// @notice Simulate direct token transfer to vault (donation attack vector)
    function donate(uint256 actorSeed, uint256 amount) external useActor(actorSeed) {
        // Bound donation to reasonable amount
        amount = bound(amount, 0, 1000 ether);

        if (asset.balanceOf(currentActor) < amount) return;

        // Direct transfer to vault (not through deposit)
        asset.transfer(address(vault), amount);
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function getActorCount() external view returns (uint256) {
        return actors.length;
    }

    function forEachActor(function(address) external view fn) external view {
        for (uint256 i = 0; i < actors.length; i++) {
            fn(actors[i]);
        }
    }

    function reduceActors(
        uint256 acc,
        function(uint256, address) external view returns (uint256) fn
    ) external view returns (uint256) {
        for (uint256 i = 0; i < actors.length; i++) {
            acc = fn(acc, actors[i]);
        }
        return acc;
    }

    function callSummary() external view {
        console.log("Call Summary:");
        console.log("  deposit:", calls_deposit);
        console.log("  mint:", calls_mint);
        console.log("  withdraw:", calls_withdraw);
        console.log("  redeem:", calls_redeem);
        console.log("Ghost Variables:");
        console.log("  depositSum:", ghost_depositSum);
        console.log("  withdrawSum:", ghost_withdrawSum);
    }
}
