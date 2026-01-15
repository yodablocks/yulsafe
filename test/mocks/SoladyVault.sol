// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "solady/tokens/ERC4626.sol";

/// @title SoladyVault
/// @notice Minimal Solady ERC4626 implementation for gas comparison
/// @dev Wraps Solady's abstract ERC4626 with concrete implementations
contract SoladyVault is ERC4626 {
    address private immutable _asset;
    string private _name;
    string private _symbol;

    constructor(address asset_, string memory name_, string memory symbol_) {
        _asset = asset_;
        _name = name_;
        _symbol = symbol_;
    }

    /// @dev Returns the address of the underlying asset.
    function asset() public view virtual override returns (address) {
        return _asset;
    }

    /// @dev Returns the name of the token.
    function name() public view virtual override returns (string memory) {
        return _name;
    }

    /// @dev Returns the symbol of the token.
    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    /// @dev Returns the total amount of the underlying asset managed by the vault.
    function totalAssets() public view virtual override returns (uint256) {
        return ERC4626(_asset).balanceOf(address(this));
    }
}
