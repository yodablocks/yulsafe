// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626Test} from "erc4626-tests/ERC4626.test.sol";
import {LeanVault2} from "./mocks/LeanVault2.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice The 26 a16z ERC4626 properties against LeanVault2. No first-deposit
///         special case here, so the stock harness applies with only amount
///         bounds for the 96-bit lanes.
contract LeanVault2Std is ERC4626Test {
    uint256 constant CAP = 1e27;

    function setUp() public override {
        _underlying_ = address(new MockERC20("Mock Token", "MOCK", 18));
        _vault_ = address(new LeanVault2(_underlying_, "Lean Vault 2", "lVAULT2"));
        _delta_ = 0;
        _vaultMayBeEmpty = true;
        _unlimitedAmount = false;
    }

    function setUpVault(Init memory init) public override {
        for (uint256 i = 0; i < N; i++) {
            address user = init.user[i];
            vm.assume(user != address(0) && user != _vault_ && _isEOA(user));
            uint256 shares = bound(init.share[i], 0, CAP);
            init.share[i] = shares;
            if (shares > 0) {
                MockERC20(_underlying_).mint(user, shares);
                _approve(_underlying_, user, _vault_, shares);
                vm.prank(user);
                LeanVault2(_vault_).deposit(shares, user);
            }
            uint256 assets = bound(init.asset[i], 0, CAP);
            init.asset[i] = assets;
            if (assets > 0) MockERC20(_underlying_).mint(user, assets);
        }
        setUpYield(init);
    }

    function setUpYield(Init memory init) public override {
        if (init.yield > 0) {
            uint256 gain = bound(uint256(init.yield), 1, CAP);
            // forge-lint: disable-next-line(unsafe-typecast)
            init.yield = int256(gain);
            MockERC20(_underlying_).mint(_vault_, gain);
        } else {
            init.yield = 0;
        }
    }
}
