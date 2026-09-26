// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {YulSafeERC4626Std} from "./ERC4626Std.t.sol";
import {PlainPackedVault} from "./mocks/PlainPackedVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice The same 26 a16z ERC4626 properties, run against the plain Solidity
///         twin, so the gas comparison is between two contracts that provably
///         satisfy the same standard properties.
contract PlainPackedVaultStd is YulSafeERC4626Std {
    function setUp() public override {
        _underlying_ = address(new MockERC20("Mock Token", "MOCK", 18));
        _vault_ = address(new PlainPackedVault(_underlying_, "Plain Vault", "pVAULT"));
        _delta_ = 0;
        _vaultMayBeEmpty = false;
        _unlimitedAmount = false;
    }
}
