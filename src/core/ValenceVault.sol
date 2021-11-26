// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IValenceVault} from "../interfaces/IValenceVault.sol";
import {IValenceAccount} from "../interfaces/IValenceAccount.sol";
import {IValenceOracleRelay} from "../interfaces/IValenceOracleRelay.sol";
import {IValencePortfolioMargin} from "../interfaces/IValencePortfolioMargin.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IERC4626} from "../interfaces/IERC4626.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";

/// @title ValenceVault
/// @notice Multi-asset collateral custody vault supporting standard ERC-20 and ERC-4626 yield assets.
/// @dev Implements non-reentrant state tracking, hair-cut collateral valuations, and debt reconciliation.
contract ValenceVault is IValenceVault {
    using FixedPointMath for uint256;

    address public immutable owner;
    address public clearinghouse;
    IValenceAccount public immutable accountManager;
    IValenceOracleRelay public oracleRelay;
    IValencePortfolioMargin public portfolioMargin;

    bool private _locked;

    mapping(address => AssetConfig) private _assetConfigs;
    address[] private _whitelistedAssets;

    // subaccountId => asset => balance
    mapping(bytes32 => mapping(address => uint256)) private _subaccountBalances;

    error ValenceVault__ReentrantCall();
    error ValenceVault__Unauthorized();
    error ValenceVault__AssetNotWhitelisted();
    error ValenceVault__DepositCapExceeded();
    error ValenceVault__InsufficientBalance();
    error ValenceVault__TransferFailed();
    error ValenceVault__WithdrawalViolatesMargin();
    error ValenceVault__ZeroAddress();
    error ValenceVault__ZeroAmount();

    modifier nonReentrant() {
        if (_locked) revert ValenceVault__ReentrantCall();
        _locked = true;
        _;
        _locked = false;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert ValenceVault__Unauthorized();
        _;
    }

    modifier onlyClearinghouse() {
        if (msg.sender != clearinghouse) revert ValenceVault__Unauthorized();
        _;
    }

    constructor(address _accountManager) {
        if (_accountManager == address(0)) revert ValenceVault__ZeroAddress();
        owner = msg.sender;
        accountManager = IValenceAccount(_accountManager);
    }

    function setClearinghouse(address _clearinghouse) external onlyOwner {
        if (_clearinghouse == address(0)) revert ValenceVault__ZeroAddress();
        clearinghouse = _clearinghouse;
    }

    function setOracleRelay(address _oracleRelay) external onlyOwner {
        if (_oracleRelay == address(0)) revert ValenceVault__ZeroAddress();
        oracleRelay = IValenceOracleRelay(_oracleRelay);
    }

    function setPortfolioMargin(address _portfolioMargin) external onlyOwner {
        if (_portfolioMargin == address(0)) revert ValenceVault__ZeroAddress();
        portfolioMargin = IValencePortfolioMargin(_portfolioMargin);
    }

    function whitelistAsset(
        address asset,
        bool isYieldBearing,
        uint16 riskTier,
        uint32 haircutFactor,
        uint256 maxDepositCap
    ) external onlyOwner {
        if (asset == address(0)) revert ValenceVault__ZeroAddress();
        if (!_assetConfigs[asset].isWhitelisted) {
            _whitelistedAssets.push(asset);
        }

        _assetConfigs[asset] = AssetConfig({
            isWhitelisted: true,
            isYieldBearing: isYieldBearing,
            riskTier: riskTier,
            haircutFactor: haircutFactor,
            maxDepositCap: maxDepositCap,
            totalDeposited: _assetConfigs[asset].totalDeposited
        });

        emit AssetWhitelisted(asset, riskTier, haircutFactor);
    }

    function delistAsset(address asset) external onlyOwner {
        _assetConfigs[asset].isWhitelisted = false;
        emit AssetDelisted(asset);
    }

    /// @notice Deposits collateral into a subaccount.
    function deposit(bytes32 subaccountId, address asset, uint256 amount) external nonReentrant {
        if (amount == 0) revert ValenceVault__ZeroAmount();
        AssetConfig storage config = _assetConfigs[asset];
        if (!config.isWhitelisted) revert ValenceVault__AssetNotWhitelisted();

        if (config.totalDeposited + amount > config.maxDepositCap) {
            revert ValenceVault__DepositCapExceeded();
        }

        config.totalDeposited += amount;
        _subaccountBalances[subaccountId][asset] += amount;

        _safeTransferFrom(asset, msg.sender, address(this), amount);

        emit CollateralDeposited(subaccountId, asset, amount);
    }

    /// @notice Withdraws collateral from a subaccount.
    function withdraw(
        bytes32 subaccountId,
        address asset,
        uint256 amount,
        address recipient
    ) external nonReentrant {
        if (amount == 0) revert ValenceVault__ZeroAmount();
        if (recipient == address(0)) revert ValenceVault__ZeroAddress();

        bool isClearing = msg.sender == clearinghouse;
        if (!isClearing) {
            if (!accountManager.isOwnerOrDelegate(subaccountId, msg.sender, 1)) {
                revert ValenceVault__Unauthorized();
            }
        }

        uint256 currentBalance = _subaccountBalances[subaccountId][asset];
        if (currentBalance < amount) revert ValenceVault__InsufficientBalance();

        _subaccountBalances[subaccountId][asset] = currentBalance - amount;
        _assetConfigs[asset].totalDeposited -= amount;

        // Verify withdrawal solvency if initiated by user
        if (!isClearing && address(portfolioMargin) != address(0)) {
            if (!portfolioMargin.checkSolvency(subaccountId)) {
                revert ValenceVault__WithdrawalViolatesMargin();
            }
        }

        _safeTransfer(asset, recipient, amount);

        emit CollateralWithdrawn(subaccountId, asset, amount, recipient);
    }

    /// @notice Internal transfer between subaccounts (called by Clearinghouse for settlement/liquidation).
    function transferInternal(
        bytes32 fromSubaccount,
        bytes32 toSubaccount,
        address asset,
        uint256 amount
    ) external onlyClearinghouse {
        if (amount == 0) revert ValenceVault__ZeroAmount();
        uint256 balanceFrom = _subaccountBalances[fromSubaccount][asset];
        if (balanceFrom < amount) revert ValenceVault__InsufficientBalance();

        _subaccountBalances[fromSubaccount][asset] = balanceFrom - amount;
        _subaccountBalances[toSubaccount][asset] += amount;
    }

    /// @notice Gets balance of a specific collateral token for a subaccount.
    function getCollateralBalance(bytes32 subaccountId, address asset) external view returns (uint256) {
        return _subaccountBalances[subaccountId][asset];
    }

    /// @notice Calculates the total USD value and haircut USD value of a subaccount's collateral.
    function getSubaccountCollateralValue(bytes32 subaccountId)
        external
        view
        returns (uint256 totalValueUsd, uint256 haircutValueUsd)
    {
        uint256 len = _whitelistedAssets.length;
        for (uint256 i = 0; i < len;) {
            address asset = _whitelistedAssets[i];
            uint256 bal = _subaccountBalances[subaccountId][asset];
            if (bal > 0) {
                AssetConfig memory cfg = _assetConfigs[asset];
                uint256 assetValueUsd = _computeAssetUsdValue(asset, bal, cfg.isYieldBearing);
                totalValueUsd += assetValueUsd;

                // Haircut factor in basis points (e.g. 1000 = 10% haircut, 90% credited)
                uint256 haircutMultiplier = 10000 > cfg.haircutFactor ? 10000 - cfg.haircutFactor : 0;
                uint256 hairVal = (assetValueUsd * haircutMultiplier) / 10000;
                haircutValueUsd += hairVal;
            }
            unchecked {
                i++;
            }
        }
    }

    function isWhitelistedAsset(address asset) external view returns (bool) {
        return _assetConfigs[asset].isWhitelisted;
    }

    function getAssetConfig(address asset) external view returns (AssetConfig memory) {
        return _assetConfigs[asset];
    }

    function getWhitelistedAssets() external view returns (address[] memory) {
        return _whitelistedAssets;
    }

    // --- Internal Helpers ---

    function _computeAssetUsdValue(address asset, uint256 balance, bool isYieldBearing) private view returns (uint256) {
        uint256 underlyingBalance = balance;
        if (isYieldBearing) {
            try IERC4626(asset).convertToAssets(balance) returns (uint256 assets) {
                underlyingBalance = assets;
            } catch {
                underlyingBalance = balance;
            }
        }

        uint8 decimals = 18;
        try IERC20(asset).decimals() returns (uint8 dec) {
            decimals = dec;
        } catch {}

        bytes32 marketId = bytes32(uint256(uint160(asset)));
        uint256 priceX96 = (address(oracleRelay) != address(0)) ? oracleRelay.getIndexPrice(marketId) : (1 << 96);

        // Value in WAD = balance * priceX96 * 1e18 / (2^96 * 10^decimals)
        uint256 scaledBalance = decimals <= 18
            ? underlyingBalance * (10 ** (18 - decimals))
            : underlyingBalance / (10 ** (decimals - 18));

        return (scaledBalance * priceX96) >> 96;
    }

    function _safeTransfer(address token, address to, uint256 value) private {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, value)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            revert ValenceVault__TransferFailed();
        }
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) private {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            revert ValenceVault__TransferFailed();
        }
    }
}
