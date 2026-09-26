// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626Test} from "erc4626-tests/ERC4626.test.sol";
import {YulSafeERC20} from "../src/YulSafeERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title YulSafeERC4626Std
/// @notice Runs a16z's ERC4626 property suite (lib/erc4626-tests, AGPL-3.0,
///         test-only) against YulSafe: round-trip properties, preview bounds,
///         caller independence of conversions, and non-reverting max functions.
/// @dev Two adaptations, both about inputs rather than properties:
///      - Amounts are bounded to the 96-bit lanes, and the first deposit must
///        exceed MINIMUM_LIQUIDITY, otherwise almost every fuzz input reverts
///        in setup and is discarded.
///      - The vault has no yield path. A positive "yield" is a direct transfer,
///        which the packed accounting ignores by design, so it doubles as a
///        donation-resistance check. A negative yield has no way to happen.
contract YulSafeERC4626Std is ERC4626Test {
    uint256 constant MINIMUM_LIQUIDITY = 1000;
    uint256 constant CAP = 1e27; // four users plus yield stay far below 2^96

    function setUp() public virtual override {
        _underlying_ = address(new MockERC20("Mock Token", "MOCK", 18));
        _vault_ = address(new YulSafeERC20(_underlying_, "YulSafe Vault", "ysVAULT"));
        _delta_ = 0;
        _vaultMayBeEmpty = false;
        _unlimitedAmount = false;
    }

    function setUpVault(Init memory init) public override {
        for (uint256 i = 0; i < N; i++) {
            address user = init.user[i];
            vm.assume(user != address(0) && user != _vault_ && _isEOA(user));

            uint256 shares = bound(init.share[i], 0, CAP);
            if (shares > 0 && shares <= MINIMUM_LIQUIDITY) shares = MINIMUM_LIQUIDITY + 1;
            init.share[i] = shares;
            if (shares > 0) {
                MockERC20(_underlying_).mint(user, shares);
                _approve(_underlying_, user, _vault_, shares);
                vm.prank(user);
                YulSafeERC20(_vault_).deposit(shares, user);
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
            // gain is at most CAP, far below int256 max
            // forge-lint: disable-next-line(unsafe-typecast)
            init.yield = int256(gain);
            MockERC20(_underlying_).mint(_vault_, gain);
        } else {
            init.yield = 0;
        }
    }
}
