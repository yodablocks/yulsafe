// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {YulSafeERC20} from "../src/YulSafeERC20.sol";
import {SoladyVault} from "./mocks/SoladyVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title GasBenchmark
/// @notice Gas comparison tests between YulSafe and Solady ERC4626
/// @dev Run with: forge test --match-contract GasBenchmark --gas-report
contract GasBenchmark is Test {
    YulSafeERC20 public yulSafe;
    SoladyVault public solady;
    MockERC20 public asset;

    address public alice = address(0x1);
    uint256 public constant INITIAL_BALANCE = 1_000_000e18;

    function setUp() public {
        // Deploy mock asset
        asset = new MockERC20("Test Token", "TEST", 18);

        // Deploy both vault implementations
        yulSafe = new YulSafeERC20(address(asset), "YulSafe Vault", "ysVAULT");
        solady = new SoladyVault(address(asset), "Solady Vault", "sVAULT");

        // Fund alice
        asset.mint(alice, INITIAL_BALANCE);

        // Approve both vaults
        vm.startPrank(alice);
        asset.approve(address(yulSafe), type(uint256).max);
        asset.approve(address(solady), type(uint256).max);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        FIRST DEPOSIT BENCHMARKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Benchmark YulSafe first deposit (includes MINIMUM_LIQUIDITY burn)
    function test_gas_yulsafe_first_deposit() public {
        vm.prank(alice);
        yulSafe.deposit(10000e18, alice);
    }

    /// @notice Benchmark Solady first deposit
    function test_gas_solady_first_deposit() public {
        vm.prank(alice);
        solady.deposit(10000e18, alice);
    }

    /*//////////////////////////////////////////////////////////////
                      SUBSEQUENT DEPOSIT BENCHMARKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Benchmark YulSafe subsequent deposit
    function test_gas_yulsafe_subsequent_deposit() public {
        // First deposit to initialize
        vm.prank(alice);
        yulSafe.deposit(10000e18, alice);

        // Benchmark subsequent deposit
        vm.prank(alice);
        yulSafe.deposit(5000e18, alice);
    }

    /// @notice Benchmark Solady subsequent deposit
    function test_gas_solady_subsequent_deposit() public {
        // First deposit to initialize
        vm.prank(alice);
        solady.deposit(10000e18, alice);

        // Benchmark subsequent deposit
        vm.prank(alice);
        solady.deposit(5000e18, alice);
    }

    /*//////////////////////////////////////////////////////////////
                          WITHDRAW BENCHMARKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Benchmark YulSafe withdraw
    function test_gas_yulsafe_withdraw() public {
        // Setup: deposit first
        vm.prank(alice);
        yulSafe.deposit(10000e18, alice);

        // Benchmark withdraw
        vm.prank(alice);
        yulSafe.withdraw(5000e18, alice, alice);
    }

    /// @notice Benchmark Solady withdraw
    function test_gas_solady_withdraw() public {
        // Setup: deposit first
        vm.prank(alice);
        solady.deposit(10000e18, alice);

        // Benchmark withdraw
        vm.prank(alice);
        solady.withdraw(5000e18, alice, alice);
    }

    /*//////////////////////////////////////////////////////////////
                           REDEEM BENCHMARKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Benchmark YulSafe redeem
    function test_gas_yulsafe_redeem() public {
        // Setup: deposit first
        vm.prank(alice);
        uint256 shares = yulSafe.deposit(10000e18, alice);

        // Benchmark redeem (half the shares)
        vm.prank(alice);
        yulSafe.redeem(shares / 2, alice, alice);
    }

    /// @notice Benchmark Solady redeem
    function test_gas_solady_redeem() public {
        // Setup: deposit first
        vm.prank(alice);
        uint256 shares = solady.deposit(10000e18, alice);

        // Benchmark redeem (half the shares)
        vm.prank(alice);
        solady.redeem(shares / 2, alice, alice);
    }

    /*//////////////////////////////////////////////////////////////
                            MINT BENCHMARKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Benchmark YulSafe mint
    function test_gas_yulsafe_mint() public {
        // First deposit to initialize
        vm.prank(alice);
        yulSafe.deposit(10000e18, alice);

        // Benchmark mint
        vm.prank(alice);
        yulSafe.mint(5000e18, alice);
    }

    /// @notice Benchmark Solady mint
    function test_gas_solady_mint() public {
        // First deposit to initialize
        vm.prank(alice);
        solady.deposit(10000e18, alice);

        // Benchmark mint
        vm.prank(alice);
        solady.mint(5000e18, alice);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTION BENCHMARKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Benchmark YulSafe totalAssets (packed storage read)
    function test_gas_yulsafe_totalAssets() public view {
        yulSafe.totalAssets();
    }

    /// @notice Benchmark Solady totalAssets
    function test_gas_solady_totalAssets() public view {
        solady.totalAssets();
    }

    /// @notice Benchmark YulSafe convertToShares
    function test_gas_yulsafe_convertToShares() public {
        vm.prank(alice);
        yulSafe.deposit(10000e18, alice);

        yulSafe.convertToShares(1000e18);
    }

    /// @notice Benchmark Solady convertToShares
    function test_gas_solady_convertToShares() public {
        vm.prank(alice);
        solady.deposit(10000e18, alice);

        solady.convertToShares(1000e18);
    }

    /// @notice Benchmark YulSafe convertToAssets
    function test_gas_yulsafe_convertToAssets() public {
        vm.prank(alice);
        yulSafe.deposit(10000e18, alice);

        yulSafe.convertToAssets(1000e18);
    }

    /// @notice Benchmark Solady convertToAssets
    function test_gas_solady_convertToAssets() public {
        vm.prank(alice);
        solady.deposit(10000e18, alice);

        solady.convertToAssets(1000e18);
    }
}
