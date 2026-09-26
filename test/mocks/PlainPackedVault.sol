// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title PlainPackedVault
/// @notice YulSafeERC20 rewritten in plain Solidity with zero assembly.
///         Same storage layout (two 96-bit totals the compiler packs into one
///         slot on its own), same checks, same rounding, same first-deposit
///         burn, same events and errors. It exists to measure how much of
///         YulSafe's gas advantage comes from the layout, which any Solidity
///         programmer can choose, and how much from hand-written Yul.
/// @dev Not a product. Benchmark subject only.
contract PlainPackedVault is ERC20, Ownable, ReentrancyGuard {
    using SafeTransferLib for address;

    uint256 private constant MINIMUM_LIQUIDITY = 1000;
    uint256 private constant MAX_96_BITS = type(uint96).max;

    address public immutable asset;

    // Adjacent 96-bit fields share one storage slot; the compiler does the packing.
    uint96 private _totalAssets;
    uint96 private _totalSupply;

    bool private _paused;
    string private _name;
    string private _symbol;

    /// @dev Every caller bounds both values to MAX_96_BITS before calling, so the
    ///      casts cannot truncate. One SSTORE, since both fields share a slot.
    function _store(uint256 totalAssets_, uint256 totalSupply_) private {
        // forge-lint: disable-next-line(unsafe-typecast)
        _totalAssets = uint96(totalAssets_);
        // forge-lint: disable-next-line(unsafe-typecast)
        _totalSupply = uint96(totalSupply_);
    }

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    event PausedEvent();
    event UnpausedEvent();

    error Paused();
    error ZeroAmount();
    error ZeroAddress();
    error InsufficientShares();
    error ExceedsMaxCapacity();
    error InsufficientAssets();

    constructor(address asset_, string memory name_, string memory symbol_) {
        if (asset_ == address(0)) revert ZeroAddress();
        asset = asset_;
        _name = name_;
        _symbol = symbol_;
        _initializeOwner(msg.sender);
    }

    function name() public view virtual override returns (string memory) {
        return _name;
    }

    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    /*//////////////////////////////////////////////////////////////
                              ERC4626 CORE
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 assets, address receiver) public virtual nonReentrant returns (uint256 shares) {
        if (_paused) revert Paused();
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (assets > MAX_96_BITS) revert ExceedsMaxCapacity();

        (uint256 totalAssets_, uint256 totalSupply_) = (_totalAssets, _totalSupply);
        bool isFirstDeposit;

        if (totalSupply_ == 0) {
            if (assets <= MINIMUM_LIQUIDITY) revert InsufficientShares();
            shares = assets - MINIMUM_LIQUIDITY;
            isFirstDeposit = true;
            _store(assets, assets);
        } else {
            shares = (assets * totalSupply_) / totalAssets_;
            if (shares == 0) revert InsufficientShares();
            uint256 newAssets = totalAssets_ + assets;
            uint256 newSupply = totalSupply_ + shares;
            if (newAssets > MAX_96_BITS || newSupply > MAX_96_BITS) revert ExceedsMaxCapacity();
            _store(newAssets, newSupply);
        }

        emit Deposit(msg.sender, receiver, assets, shares);

        if (isFirstDeposit) _mint(address(0), MINIMUM_LIQUIDITY);
        _mint(receiver, shares);

        asset.safeTransferFrom(msg.sender, address(this), assets);
    }

    function mint(uint256 shares, address receiver) public virtual nonReentrant returns (uint256 assets) {
        if (_paused) revert Paused();
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (shares > MAX_96_BITS) revert ExceedsMaxCapacity();

        (uint256 totalAssets_, uint256 totalSupply_) = (_totalAssets, _totalSupply);
        bool isFirstMint;

        if (totalSupply_ == 0) {
            assets = shares + MINIMUM_LIQUIDITY;
            if (assets > MAX_96_BITS) revert ExceedsMaxCapacity();
            isFirstMint = true;
            _store(assets, assets);
        } else {
            uint256 numerator = shares * totalAssets_;
            assets = numerator / totalSupply_ + (numerator % totalSupply_ == 0 ? 0 : 1);
            uint256 newAssets = totalAssets_ + assets;
            uint256 newSupply = totalSupply_ + shares;
            if (newAssets > MAX_96_BITS || newSupply > MAX_96_BITS) revert ExceedsMaxCapacity();
            _store(newAssets, newSupply);
        }

        emit Deposit(msg.sender, receiver, assets, shares);

        if (isFirstMint) _mint(address(0), MINIMUM_LIQUIDITY);
        _mint(receiver, shares);

        asset.safeTransferFrom(msg.sender, address(this), assets);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        virtual
        nonReentrant
        returns (uint256 shares)
    {
        if (_paused) revert Paused();
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        (uint256 totalAssets_, uint256 totalSupply_) = (_totalAssets, _totalSupply);
        if (assets > totalAssets_) revert InsufficientAssets();

        uint256 numerator = assets * totalSupply_;
        shares = numerator / totalAssets_ + (numerator % totalAssets_ == 0 ? 0 : 1);
        if (shares == 0) revert InsufficientShares();

        _store(totalAssets_ - assets, totalSupply_ - shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);

        asset.safeTransfer(receiver, assets);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        virtual
        nonReentrant
        returns (uint256 assets)
    {
        if (_paused) revert Paused();
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        (uint256 totalAssets_, uint256 totalSupply_) = (_totalAssets, _totalSupply);
        if (shares > totalSupply_) revert InsufficientShares();

        assets = (shares * totalAssets_) / totalSupply_;
        if (assets == 0) revert InsufficientAssets();

        _store(totalAssets_ - assets, totalSupply_ - shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);

        asset.safeTransfer(receiver, assets);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view virtual returns (uint256) {
        return _totalAssets;
    }

    function convertToShares(uint256 assets) public view virtual returns (uint256) {
        (uint256 totalAssets_, uint256 totalSupply_) = (_totalAssets, _totalSupply);
        if (totalSupply_ == 0) return assets;
        return (assets * totalSupply_) / totalAssets_;
    }

    function convertToAssets(uint256 shares) public view virtual returns (uint256) {
        (uint256 totalAssets_, uint256 totalSupply_) = (_totalAssets, _totalSupply);
        if (totalSupply_ == 0) return shares;
        return (shares * totalAssets_) / totalSupply_;
    }

    function previewDeposit(uint256 assets) public view virtual returns (uint256) {
        (uint256 totalAssets_, uint256 totalSupply_) = (_totalAssets, _totalSupply);
        if (totalSupply_ == 0) return assets > MINIMUM_LIQUIDITY ? assets - MINIMUM_LIQUIDITY : 0;
        return (assets * totalSupply_) / totalAssets_;
    }

    function previewMint(uint256 shares) public view virtual returns (uint256) {
        (uint256 totalAssets_, uint256 totalSupply_) = (_totalAssets, _totalSupply);
        if (totalSupply_ == 0) return shares + MINIMUM_LIQUIDITY;
        return (shares * totalAssets_ + totalSupply_ - 1) / totalSupply_;
    }

    function previewWithdraw(uint256 assets) public view virtual returns (uint256) {
        (uint256 totalAssets_, uint256 totalSupply_) = (_totalAssets, _totalSupply);
        if (totalSupply_ == 0) return assets;
        return (assets * totalSupply_ + totalAssets_ - 1) / totalAssets_;
    }

    function previewRedeem(uint256 shares) public view virtual returns (uint256) {
        return convertToAssets(shares);
    }

    function maxDeposit(address) public view virtual returns (uint256) {
        if (_paused) return 0;
        return MAX_96_BITS - _totalAssets;
    }

    function maxMint(address) public view virtual returns (uint256) {
        if (_paused) return 0;
        return MAX_96_BITS - _totalSupply;
    }

    function maxWithdraw(address owner) public view virtual returns (uint256) {
        if (_paused) return 0;
        return convertToAssets(balanceOf(owner));
    }

    function maxRedeem(address owner) public view virtual returns (uint256) {
        if (_paused) return 0;
        return balanceOf(owner);
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    function pause() external virtual onlyOwner {
        _paused = true;
        emit PausedEvent();
    }

    function unpause() external virtual onlyOwner {
        _paused = false;
        emit UnpausedEvent();
    }

    function paused() external view virtual returns (bool) {
        return _paused;
    }
}
