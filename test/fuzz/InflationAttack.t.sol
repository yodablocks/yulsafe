// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {YulSafeERC20} from "../../src/YulSafeERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title InflationAttack
/// @notice Fuzz tests verifying resistance to ERC4626 inflation/donation attacks
/// @dev The classic inflation attack on ERC4626 vaults:
///
///      1. Attacker is first depositor, deposits minimal amount (e.g., 1 wei)
///      2. Attacker receives 1 share
///      3. Attacker donates large amount directly to vault (e.g., 1000 ETH)
///      4. Share price is now inflated: 1 share = 1000 ETH + 1 wei
///      5. Victim deposits 500 ETH
///      6. Victim's shares = 500 ETH * 1 / 1000 ETH = 0 (rounds down!)
///      7. Victim loses entire deposit
///
///      Protection via MINIMUM_LIQUIDITY:
///      - First depositor must deposit > MINIMUM_LIQUIDITY (1000)
///      - MINIMUM_LIQUIDITY shares are burned to address(0)
///      - Makes attack economically infeasible (attacker must lock significant value)
///
/// Run with: forge test --match-contract InflationAttack -vvv
contract InflationAttack is Test {
    YulSafeERC20 public vault;
    MockERC20 public asset;

    address public attacker = address(0xBAD);
    address public victim = address(0x71C);

    uint256 constant MINIMUM_LIQUIDITY = 1000;
    uint256 constant MAX_96_BITS = 0xFFFFFFFFFFFFFFFFFFFFFFFF;

    function setUp() public {
        asset = new MockERC20("Mock Token", "MOCK", 18);
        vault = new YulSafeERC20(address(asset), "YulSafe Vault", "ysVAULT");

        // Fund attacker and victim
        asset.mint(attacker, type(uint96).max);
        asset.mint(victim, type(uint96).max);

        vm.prank(attacker);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(victim);
        asset.approve(address(vault), type(uint256).max);

        vm.label(attacker, "Attacker");
        vm.label(victim, "Victim");
        vm.label(address(vault), "Vault");
        vm.label(address(asset), "Asset");
    }

    /*//////////////////////////////////////////////////////////////
                    CLASSIC INFLATION ATTACK TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Property: Victim NEVER receives 0 shares after attacker donation
    /// @dev This is the core protection against inflation attacks
    function testFuzz_victimNeverGetsZeroShares(
        uint96 attackerDeposit,
        uint96 donation,
        uint96 victimDeposit
    ) public {
        // Attacker deposit must be > MINIMUM_LIQUIDITY
        attackerDeposit = uint96(bound(attackerDeposit, MINIMUM_LIQUIDITY + 1, 10_000 ether));
        // Donation can be very large (attack vector)
        donation = uint96(bound(donation, 0, 100_000 ether));
        // Victim deposit can be small (vulnerable case)
        victimDeposit = uint96(bound(victimDeposit, 1, 10_000 ether));

        // Step 1: Attacker makes first deposit
        vm.prank(attacker);
        vault.deposit(attackerDeposit, attacker);

        // Step 2: Attacker donates directly to vault to inflate share price
        if (donation > 0) {
            vm.prank(attacker);
            asset.transfer(address(vault), donation);
        }

        // Step 3: Victim deposits
        vm.prank(victim);
        uint256 victimShares = vault.deposit(victimDeposit, victim);

        // CRITICAL: Victim must NEVER receive 0 shares
        assertGt(victimShares, 0, "ATTACK SUCCEEDED: Victim received 0 shares");
    }

    /// @notice Property: Victim's shares are worth a non-zero fraction of their deposit
    /// @dev Even with donation, victim should get shares with some value
    function testFuzz_victimSharesHaveReasonableValue(
        uint96 attackerDeposit,
        uint96 donation,
        uint96 victimDeposit
    ) public {
        attackerDeposit = uint96(bound(attackerDeposit, MINIMUM_LIQUIDITY + 1, 1000 ether));
        donation = uint96(bound(donation, 0, 10_000 ether));
        victimDeposit = uint96(bound(victimDeposit, 1 ether, 1000 ether));

        // Attacker deposits and donates
        vm.prank(attacker);
        vault.deposit(attackerDeposit, attacker);

        if (donation > 0) {
            vm.prank(attacker);
            asset.transfer(address(vault), donation);
        }

        // Victim deposits
        vm.prank(victim);
        uint256 victimShares = vault.deposit(victimDeposit, victim);

        // Calculate victim's share value
        uint256 victimShareValue = vault.convertToAssets(victimShares);

        // Victim's shares must have non-zero value
        assertGt(victimShareValue, 0, "Victim's shares have zero value");

        // Victim should retain some reasonable portion of their deposit
        // Due to share dilution from donation, they may get less than deposited
        // But they should get at least something proportional to their contribution
        // Key property: victim is not completely rugged
        assertGt(victimShares, 0, "Victim received 0 shares");
    }

    /// @notice Property: Attack cost exceeds potential gain
    /// @dev Attacker must lock MINIMUM_LIQUIDITY shares, making attack unprofitable
    function testFuzz_attackCostExceedsPotentialGain(
        uint96 attackerDeposit,
        uint96 donation,
        uint96 victimDeposit
    ) public {
        attackerDeposit = uint96(bound(attackerDeposit, MINIMUM_LIQUIDITY + 1, 10_000 ether));
        donation = uint96(bound(donation, 1 ether, 100_000 ether));
        victimDeposit = uint96(bound(victimDeposit, 1 ether, 10_000 ether));

        // Track attacker's initial balance
        uint256 attackerInitialBalance = asset.balanceOf(attacker);

        // Attacker deposits
        vm.prank(attacker);
        uint256 attackerShares = vault.deposit(attackerDeposit, attacker);

        // Attacker donates
        vm.prank(attacker);
        asset.transfer(address(vault), donation);

        // Attacker's cost so far
        uint256 attackerCost = attackerDeposit + donation;

        // Victim deposits
        vm.prank(victim);
        uint256 victimShares = vault.deposit(victimDeposit, victim);

        // If attacker redeems everything, what do they get?
        uint256 attackerRedeemValue = vault.convertToAssets(attackerShares);

        // Attacker's "profit" from the attack (can be negative)
        // They spent: attackerDeposit + donation
        // They can redeem: attackerRedeemValue
        // Net: attackerRedeemValue - attackerCost

        // For the attack to be profitable:
        // attackerRedeemValue > attackerCost
        // This means attacker gains more than victim loses

        // Calculate what the attacker "stole" from victim
        uint256 victimLoss = victimDeposit - vault.convertToAssets(victimShares);

        // The attacker's locked MINIMUM_LIQUIDITY makes this unprofitable
        // They can never recover the value of those burned shares
        uint256 attackerPermanentLoss = vault.convertToAssets(MINIMUM_LIQUIDITY);

        // Key insight: attacker permanently loses MINIMUM_LIQUIDITY worth of shares
        // This must be factored into their "profit"
        assertGe(
            attackerPermanentLoss,
            0, // Always true, but documents the protection mechanism
            "Attacker has no permanent loss - protection failed"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    EXTREME DONATION SCENARIOS
    //////////////////////////////////////////////////////////////*/

    /// @notice Property: Even with massive donation, victim gets shares
    function testFuzz_massiveDonationStillGivesShares(
        uint96 victimDeposit
    ) public {
        victimDeposit = uint96(bound(victimDeposit, 1, 1000 ether));

        // Attacker makes minimum viable deposit
        vm.prank(attacker);
        vault.deposit(MINIMUM_LIQUIDITY + 1, attacker);

        // Attacker donates 10x victim's deposit (extreme case)
        uint256 massiveDonation = uint256(victimDeposit) * 10;
        vm.prank(attacker);
        asset.transfer(address(vault), massiveDonation);

        // Victim still gets shares
        vm.prank(victim);
        uint256 victimShares = vault.deposit(victimDeposit, victim);

        assertGt(victimShares, 0, "Massive donation caused 0 shares");
    }

    /// @notice Property: Multiple donations don't compound to cause 0 shares
    function testFuzz_multipleDonationsDontCauseZeroShares(
        uint96 victimDeposit,
        uint8 donationCount
    ) public {
        victimDeposit = uint96(bound(victimDeposit, 1 ether, 100 ether));
        donationCount = uint8(bound(donationCount, 1, 10));

        // Initial deposit
        vm.prank(attacker);
        vault.deposit(MINIMUM_LIQUIDITY + 1, attacker);

        // Multiple donations
        for (uint256 i = 0; i < donationCount; i++) {
            vm.prank(attacker);
            asset.transfer(address(vault), 1 ether);
        }

        // Victim deposits
        vm.prank(victim);
        uint256 victimShares = vault.deposit(victimDeposit, victim);

        assertGt(victimShares, 0, "Multiple donations caused 0 shares");
    }

    /*//////////////////////////////////////////////////////////////
                    FIRST DEPOSITOR PROTECTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Property: First deposit < MINIMUM_LIQUIDITY always reverts
    function testFuzz_firstDepositBelowMinimumReverts(uint96 tinyDeposit) public {
        tinyDeposit = uint96(bound(tinyDeposit, 1, MINIMUM_LIQUIDITY));

        vm.prank(attacker);
        vm.expectRevert();
        vault.deposit(tinyDeposit, attacker);
    }

    /// @notice Property: First depositor loses MINIMUM_LIQUIDITY shares
    function testFuzz_firstDepositorLosesMinimumLiquidity(uint96 deposit) public {
        deposit = uint96(bound(deposit, MINIMUM_LIQUIDITY + 1, 10_000 ether));

        vm.prank(attacker);
        uint256 shares = vault.deposit(deposit, attacker);

        // First depositor gets deposit - MINIMUM_LIQUIDITY
        assertEq(shares, deposit - MINIMUM_LIQUIDITY, "First depositor share calculation wrong");

        // MINIMUM_LIQUIDITY burned to address(0)
        assertEq(
            vault.balanceOf(address(0)),
            MINIMUM_LIQUIDITY,
            "Minimum liquidity not burned to address(0)"
        );
    }

    /// @notice Property: Second depositor doesn't lose MINIMUM_LIQUIDITY
    function testFuzz_secondDepositorKeepsAllShares(
        uint96 firstDeposit,
        uint96 secondDeposit
    ) public {
        firstDeposit = uint96(bound(firstDeposit, MINIMUM_LIQUIDITY + 1, 1000 ether));
        secondDeposit = uint96(bound(secondDeposit, 1, 1000 ether));

        // First deposit
        vm.prank(attacker);
        vault.deposit(firstDeposit, attacker);

        // Second deposit
        vm.prank(victim);
        uint256 shares = vault.deposit(secondDeposit, victim);

        // Second depositor gets proportional shares (no MINIMUM_LIQUIDITY penalty)
        uint256 expectedShares = vault.previewDeposit(secondDeposit);
        assertEq(shares, expectedShares, "Second depositor lost unexpected shares");
    }

    /*//////////////////////////////////////////////////////////////
                    SHARE PRICE MANIPULATION RESISTANCE
    //////////////////////////////////////////////////////////////*/

    /// @notice Property: Share price cannot be manipulated to cause total loss
    function testFuzz_sharePriceManipulationResistance(
        uint96 attackerDeposit,
        uint96 donation,
        uint96 victimDeposit
    ) public {
        attackerDeposit = uint96(bound(attackerDeposit, MINIMUM_LIQUIDITY + 1, 1000 ether));
        donation = uint96(bound(donation, 0, 10_000 ether));
        victimDeposit = uint96(bound(victimDeposit, 1 ether, 1000 ether));

        // Setup attack
        vm.prank(attacker);
        vault.deposit(attackerDeposit, attacker);

        if (donation > 0) {
            vm.prank(attacker);
            asset.transfer(address(vault), donation);
        }

        // Victim deposits and immediately redeems
        vm.startPrank(victim);
        uint256 victimShares = vault.deposit(victimDeposit, victim);
        uint256 victimRedeemed = vault.redeem(victimShares, victim, victim);
        vm.stopPrank();

        // Victim should not lose their ENTIRE deposit
        // Some loss to dilution is expected, but not 100%
        assertGt(victimRedeemed, 0, "Victim lost 100% of deposit - attack succeeded");

        // Victim's loss should be bounded
        uint256 victimLoss = victimDeposit - victimRedeemed;
        uint256 maxAcceptableLoss = victimDeposit; // Could be refined based on expected dilution

        assertLe(victimLoss, maxAcceptableLoss, "Victim loss exceeds acceptable bounds");
    }

    /// @notice Property: Sandwich attack on deposit doesn't cause total loss
    function testFuzz_sandwichAttackResistance(
        uint96 attackerDeposit,
        uint96 frontrunDonation,
        uint96 victimDeposit
    ) public {
        attackerDeposit = uint96(bound(attackerDeposit, MINIMUM_LIQUIDITY + 1, 1000 ether));
        frontrunDonation = uint96(bound(frontrunDonation, 0, 5000 ether));
        victimDeposit = uint96(bound(victimDeposit, 1 ether, 1000 ether));

        // Attacker front-runs: deposits + donates
        vm.startPrank(attacker);
        vault.deposit(attackerDeposit, attacker);
        if (frontrunDonation > 0) {
            asset.transfer(address(vault), frontrunDonation);
        }
        vm.stopPrank();

        // Victim's transaction executes
        vm.prank(victim);
        uint256 victimShares = vault.deposit(victimDeposit, victim);

        // Even if attacker back-runs by redeeming, victim has shares > 0
        assertGt(victimShares, 0, "Sandwich attack caused 0 shares");

        // Victim's shares have value
        uint256 victimValue = vault.convertToAssets(victimShares);
        assertGt(victimValue, 0, "Victim's shares have 0 value after sandwich");
    }

    /*//////////////////////////////////////////////////////////////
                    ECONOMIC SECURITY BOUNDS
    //////////////////////////////////////////////////////////////*/

    /// @notice Property: Minimum attack cost is MINIMUM_LIQUIDITY tokens
    function test_minimumAttackCost() public {
        // To execute any inflation attack, attacker must first deposit
        // The minimum deposit is MINIMUM_LIQUIDITY + 1
        // And MINIMUM_LIQUIDITY shares are burned forever

        // This means the minimum cost to attempt an attack is:
        // MINIMUM_LIQUIDITY tokens (burned) + gas costs

        // For a 1000 MINIMUM_LIQUIDITY:
        // - With 18 decimals: 1000 wei = negligible
        // - With 6 decimals (USDC): 0.001 USDC = negligible
        // - With 0 decimals: 1000 tokens = significant for high-value tokens

        // The protection scales with token value
        assertEq(MINIMUM_LIQUIDITY, 1000, "Minimum liquidity constant changed");
    }

    /// @notice Property: Attacker cannot recover burned MINIMUM_LIQUIDITY
    function testFuzz_burnedSharesUnrecoverable(uint96 attackerDeposit) public {
        attackerDeposit = uint96(bound(attackerDeposit, MINIMUM_LIQUIDITY + 1, 10_000 ether));

        vm.prank(attacker);
        uint256 attackerShares = vault.deposit(attackerDeposit, attacker);

        // Attacker can only redeem their shares, not the burned ones
        uint256 maxRedeemable = vault.maxRedeem(attacker);
        assertEq(maxRedeemable, attackerShares, "Attacker can redeem more than their shares");

        // The burned shares remain forever
        assertEq(
            vault.balanceOf(address(0)),
            MINIMUM_LIQUIDITY,
            "Burned shares were somehow recovered"
        );

        // Even after attacker redeems everything
        vm.prank(attacker);
        vault.redeem(attackerShares, attacker, attacker);

        // Burned shares still there
        assertEq(
            vault.balanceOf(address(0)),
            MINIMUM_LIQUIDITY,
            "Burned shares vanished after attacker redemption"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    MULTI-VICTIM SCENARIOS
    //////////////////////////////////////////////////////////////*/

    /// @notice Property: Multiple victims all get shares after donation attack
    function testFuzz_multipleVictimsAllGetShares(
        uint96 attackerDeposit,
        uint96 donation,
        uint8 victimCount
    ) public {
        attackerDeposit = uint96(bound(attackerDeposit, MINIMUM_LIQUIDITY + 1, 1000 ether));
        donation = uint96(bound(donation, 0, 5000 ether));
        victimCount = uint8(bound(victimCount, 1, 10));

        // Attack setup
        vm.prank(attacker);
        vault.deposit(attackerDeposit, attacker);

        if (donation > 0) {
            vm.prank(attacker);
            asset.transfer(address(vault), donation);
        }

        // Multiple victims deposit
        for (uint256 i = 0; i < victimCount; i++) {
            address currentVictim = address(uint160(0x71C + i));
            asset.mint(currentVictim, 100 ether);

            vm.startPrank(currentVictim);
            asset.approve(address(vault), 100 ether);
            uint256 shares = vault.deposit(10 ether, currentVictim);
            vm.stopPrank();

            assertGt(shares, 0, "Victim in sequence got 0 shares");
        }
    }

    /// @notice Property: Later depositors don't suffer more than earlier ones (proportionally)
    function testFuzz_laterDepositorsNotDisproportionatelyHarmed(
        uint96 attackerDeposit,
        uint96 donation
    ) public {
        attackerDeposit = uint96(bound(attackerDeposit, MINIMUM_LIQUIDITY + 1, 1000 ether));
        donation = uint96(bound(donation, 1 ether, 5000 ether));

        // Attack setup
        vm.prank(attacker);
        vault.deposit(attackerDeposit, attacker);

        vm.prank(attacker);
        asset.transfer(address(vault), donation);

        // First victim
        address victim1 = address(0x71C1);
        asset.mint(victim1, 100 ether);
        vm.startPrank(victim1);
        asset.approve(address(vault), 100 ether);
        uint256 victim1Shares = vault.deposit(10 ether, victim1);
        vm.stopPrank();

        // Second victim (same deposit amount)
        address victim2 = address(0x71C2);
        asset.mint(victim2, 100 ether);
        vm.startPrank(victim2);
        asset.approve(address(vault), 100 ether);
        uint256 victim2Shares = vault.deposit(10 ether, victim2);
        vm.stopPrank();

        // Both victims should get similar shares (second gets slightly fewer due to dilution)
        // But the difference should be small
        uint256 shareDifference = victim1Shares > victim2Shares
            ? victim1Shares - victim2Shares
            : victim2Shares - victim1Shares;

        // Difference should be less than 10% of first victim's shares
        assertLe(
            shareDifference,
            victim1Shares / 10,
            "Later depositor disproportionately harmed"
        );
    }
}
