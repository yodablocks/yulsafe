// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {YulSafeERC4626Std} from "./ERC4626Std.t.sol";
import {LeanVault} from "./mocks/LeanVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice The same 26 a16z ERC4626 properties against the lean shell.
contract LeanVaultStd is YulSafeERC4626Std {
    function setUp() public override {
        _underlying_ = address(new MockERC20("Mock Token", "MOCK", 18));
        _vault_ = address(new LeanVault(_underlying_, "Lean Vault", "lVAULT"));
        _delta_ = 0;
        _vaultMayBeEmpty = false;
        _unlimitedAmount = false;
    }
}
