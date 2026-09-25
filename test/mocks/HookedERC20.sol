// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "./MockERC20.sol";

interface IPriceSource {
    function convertToAssets(uint256 shares) external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @notice ERC20 with a transfer hook, standing in for ERC777-style tokens.
///         On every transfer it reads the vault's share price the way an
///         external protocol would, and records what it saw.
contract HookedERC20 is MockERC20 {
    IPriceSource public vault;
    uint256 public priceSeenInHook;
    uint256 public totalsRatioSeenInHook;
    uint256 public hookCalls;

    constructor() MockERC20("Hooked Token", "HOOK", 18) {}

    function setVault(address vault_) external {
        vault = IPriceSource(vault_);
    }

    function _afterTokenTransfer(address, address, uint256) internal override {
        if (address(vault) == address(0)) return;
        hookCalls++;
        priceSeenInHook = vault.convertToAssets(1e18);
        uint256 supply = vault.totalSupply();
        totalsRatioSeenInHook = supply == 0 ? 0 : (vault.totalAssets() * 1e18) / supply;
    }
}
