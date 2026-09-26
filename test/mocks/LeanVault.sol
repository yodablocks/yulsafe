// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title LeanVault
/// @notice The cheapest ERC4626 accounting shell we could write in plain
///         Solidity while keeping YulSafe's security features: a pause switch,
///         a reentrancy guard and the first-deposit burn. Three ideas, no assembly:
///         1. totalAssets, totalSupply and the pause flag share one storage slot,
///            so every path reads one word and writes one word.
///         2. The reentrancy guard lives in transient storage (EIP-1153), two
///            TSTOREs instead of a cold SLOAD and two SSTOREs per call.
///         3. The share token is minimal and reads its supply from the packed
///            word, so supply is written once, not once here and once in an
///            ERC20 base.
/// @dev Benchmark subject. Same semantics as YulSafeERC20, same 26 a16z
///      properties. No permit; add it if an integrator needs it.
contract LeanVault is Ownable, ReentrancyGuardTransient {
    using SafeTransferLib for address;

    uint256 private constant MINIMUM_LIQUIDITY = 1000;
    uint256 private constant MAX_96_BITS = type(uint96).max;

    address public immutable asset;

    // One slot: 96 + 96 + 8 bits.
    uint96 private _totalAssets;
    uint96 private _totalSupply;
    bool private _paused;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    string private _name;
    string private _symbol;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
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
    error InsufficientBalance();
    error InsufficientAllowance();

    constructor(address asset_, string memory name_, string memory symbol_) {
        if (asset_ == address(0)) revert ZeroAddress();
        asset = asset_;
        _name = name_;
        _symbol = symbol_;
        _initializeOwner(msg.sender);
    }

    /// @dev Solady's guard falls back to storage off mainnet unless told otherwise.
    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }

    /*//////////////////////////////////////////////////////////////
                             SHARE TOKEN
    //////////////////////////////////////////////////////////////*/

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function decimals() public pure returns (uint8) {
        return 18;
    }

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address owner) public view returns (uint256) {
        return _balances[owner];
    }

    function allowance(address owner, address spender) public view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        uint256 fromBalance = _balances[from];
        if (fromBalance < amount) revert InsufficientBalance();
        unchecked {
            _balances[from] = fromBalance - amount;
            // Sum of balances equals the 96-bit supply, so this cannot overflow.
            _balances[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) private {
        uint256 allowed = _allowances[owner][spender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            unchecked {
                _allowances[owner][spender] = allowed - amount;
            }
        }
    }

    /// @dev Supply is not touched here; the caller already wrote it into the packed word.
    function _mintShares(address to, uint256 amount) private {
        unchecked {
            _balances[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    function _burnShares(address from, uint256 amount) private {
        uint256 fromBalance = _balances[from];
        if (fromBalance < amount) revert InsufficientBalance();
        unchecked {
            _balances[from] = fromBalance - amount;
        }
        emit Transfer(from, address(0), amount);
    }

    /*//////////////////////////////////////////////////////////////
                              ERC4626 CORE
    //////////////////////////////////////////////////////////////*/

    /// @dev Every caller bounds both values to MAX_96_BITS first, so the casts cannot truncate.
    function _store(uint256 totalAssets_, uint256 totalSupply_) private {
        // forge-lint: disable-next-line(unsafe-typecast)
        _totalAssets = uint96(totalAssets_);
        // forge-lint: disable-next-line(unsafe-typecast)
        _totalSupply = uint96(totalSupply_);
    }

    function deposit(uint256 assets, address receiver) public nonReentrant returns (uint256 shares) {
        (uint256 totalAssets_, uint256 totalSupply_, bool paused_) = (_totalAssets, _totalSupply, _paused);
        if (paused_) revert Paused();
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (assets > MAX_96_BITS) revert ExceedsMaxCapacity();

        if (totalSupply_ == 0) {
            if (assets <= MINIMUM_LIQUIDITY) revert InsufficientShares();
            shares = assets - MINIMUM_LIQUIDITY;
            _store(assets, assets);
            _mintShares(address(0), MINIMUM_LIQUIDITY);
        } else {
            shares = (assets * totalSupply_) / totalAssets_;
            if (shares == 0) revert InsufficientShares();
            uint256 newAssets = totalAssets_ + assets;
            uint256 newSupply = totalSupply_ + shares;
            if (newAssets > MAX_96_BITS || newSupply > MAX_96_BITS) revert ExceedsMaxCapacity();
            _store(newAssets, newSupply);
        }

        _mintShares(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);

        asset.safeTransferFrom(msg.sender, address(this), assets);
    }

    function mint(uint256 shares, address receiver) public nonReentrant returns (uint256 assets) {
        (uint256 totalAssets_, uint256 totalSupply_, bool paused_) = (_totalAssets, _totalSupply, _paused);
        if (paused_) revert Paused();
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (shares > MAX_96_BITS) revert ExceedsMaxCapacity();

        if (totalSupply_ == 0) {
            assets = shares + MINIMUM_LIQUIDITY;
            if (assets > MAX_96_BITS) revert ExceedsMaxCapacity();
            _store(assets, assets);
            _mintShares(address(0), MINIMUM_LIQUIDITY);
        } else {
            uint256 numerator = shares * totalAssets_;
            assets = numerator / totalSupply_ + (numerator % totalSupply_ == 0 ? 0 : 1);
            uint256 newAssets = totalAssets_ + assets;
            uint256 newSupply = totalSupply_ + shares;
            if (newAssets > MAX_96_BITS || newSupply > MAX_96_BITS) revert ExceedsMaxCapacity();
            _store(newAssets, newSupply);
        }

        _mintShares(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);

        asset.safeTransferFrom(msg.sender, address(this), assets);
    }

    function withdraw(uint256 assets, address receiver, address owner) public nonReentrant returns (uint256 shares) {
        (uint256 totalAssets_, uint256 totalSupply_, bool paused_) = (_totalAssets, _totalSupply, _paused);
        if (paused_) revert Paused();
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (assets > totalAssets_) revert InsufficientAssets();

        uint256 numerator = assets * totalSupply_;
        shares = numerator / totalAssets_ + (numerator % totalAssets_ == 0 ? 0 : 1);
        if (shares == 0) revert InsufficientShares();

        _store(totalAssets_ - assets, totalSupply_ - shares);

        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        _burnShares(owner, shares);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        asset.safeTransfer(receiver, assets);
    }

    function redeem(uint256 shares, address receiver, address owner) public nonReentrant returns (uint256 assets) {
        (uint256 totalAssets_, uint256 totalSupply_, bool paused_) = (_totalAssets, _totalSupply, _paused);
        if (paused_) revert Paused();
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (shares > totalSupply_) revert InsufficientShares();

        assets = (shares * totalAssets_) / totalSupply_;
        if (assets == 0) revert InsufficientAssets();

        _store(totalAssets_ - assets, totalSupply_ - shares);

        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        _burnShares(owner, shares);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        asset.safeTransfer(receiver, assets);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view returns (uint256) {
        return _totalAssets;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        (uint256 totalAssets_, uint256 totalSupply_) = (_totalAssets, _totalSupply);
        if (totalSupply_ == 0) return assets;
        return (assets * totalSupply_) / totalAssets_;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        (uint256 totalAssets_, uint256 totalSupply_) = (_totalAssets, _totalSupply);
        if (totalSupply_ == 0) return shares;
        return (shares * totalAssets_) / totalSupply_;
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        (uint256 totalAssets_, uint256 totalSupply_) = (_totalAssets, _totalSupply);
        if (totalSupply_ == 0) return assets > MINIMUM_LIQUIDITY ? assets - MINIMUM_LIQUIDITY : 0;
        return (assets * totalSupply_) / totalAssets_;
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        (uint256 totalAssets_, uint256 totalSupply_) = (_totalAssets, _totalSupply);
        if (totalSupply_ == 0) return shares + MINIMUM_LIQUIDITY;
        return (shares * totalAssets_ + totalSupply_ - 1) / totalSupply_;
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        (uint256 totalAssets_, uint256 totalSupply_) = (_totalAssets, _totalSupply);
        if (totalSupply_ == 0) return assets;
        return (assets * totalSupply_ + totalAssets_ - 1) / totalAssets_;
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    function maxDeposit(address) public view returns (uint256) {
        if (_paused) return 0;
        return MAX_96_BITS - _totalAssets;
    }

    function maxMint(address) public view returns (uint256) {
        if (_paused) return 0;
        return MAX_96_BITS - _totalSupply;
    }

    function maxWithdraw(address owner) public view returns (uint256) {
        if (_paused) return 0;
        return convertToAssets(_balances[owner]);
    }

    function maxRedeem(address owner) public view returns (uint256) {
        if (_paused) return 0;
        return _balances[owner];
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    function pause() external onlyOwner {
        _paused = true;
        emit PausedEvent();
    }

    function unpause() external onlyOwner {
        _paused = false;
        emit UnpausedEvent();
    }

    function paused() external view returns (bool) {
        return _paused;
    }
}
