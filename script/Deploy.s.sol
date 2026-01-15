// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {YulSafeERC20} from "../src/YulSafeERC20.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @title DeployYulSafe
/// @notice Deployment script for YulSafe vault
contract DeployYulSafe is Script {
    function run() external {
        // Read environment variables
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address assetToken = vm.envAddress("ASSET_TOKEN");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy YulSafe vault
        YulSafeERC20 vault = new YulSafeERC20(
            assetToken,
            "YulSafe Vault",
            "ysVAULT"
        );

        console2.log("YulSafe deployed at:", address(vault));
        console2.log("Asset token:", assetToken);
        console2.log("Owner:", vault.owner());

        vm.stopBroadcast();
    }
}

/// @title DeployTestToken
/// @notice Deploy a test ERC20 token for testing on testnet
contract DeployTestToken is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy MockERC20 (USDC-like with 6 decimals)
        MockERC20 token = new MockERC20("Mock USDC", "mUSDC", 6);

        // Mint 1,000,000 tokens to deployer
        token.mint(deployer, 1_000_000 * 10**6);

        console2.log("MockERC20 deployed at:", address(token));
        console2.log("Minted 1,000,000 mUSDC to:", deployer);

        vm.stopBroadcast();
    }
}
