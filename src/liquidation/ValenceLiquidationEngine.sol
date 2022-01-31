// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IValenceLiquidationEngine} from "../interfaces/IValenceLiquidationEngine.sol";
import {IValencePortfolioMargin} from "../interfaces/IValencePortfolioMargin.sol";
import {IValenceVault} from "../interfaces/IValenceVault.sol";
import {IValenceInsuranceFund} from "../interfaces/IValenceInsuranceFund.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";
import {IERC20} from "../interfaces/IERC20.sol";

/// @title ValenceLiquidationEngine
/// @notice Continuous Dutch auction liquidation coordinator with decaying discounts and MEV resistance.
/// @dev Sells distressed collateral to liquidators along a continuous discount curve to preserve account equity.
contract ValenceLiquidationEngine is IValenceLiquidationEngine {
    using FixedPointMath for uint256;

    address public immutable owner;
    address public clearinghouse;
    IValencePortfolioMargin public portfolioMargin;
    IValenceVault public vault;
    IValenceInsuranceFund public insuranceFund;

    mapping(bytes32 => DutchAuction) private _auctions;
    mapping(bytes32 => bytes32) private _subaccountActiveAuction;

    uint256 private _auctionNonce;

    error ValenceLiquidationEngine__Unauthorized();
    error ValenceLiquidationEngine__AccountNotLiquidatable();
    error ValenceLiquidationEngine__AuctionAlreadyActive();
    error ValenceLiquidationEngine__AuctionInactive();
    error ValenceLiquidationEngine__AuctionExpired();
    error ValenceLiquidationEngine__ZeroAddress();
    error ValenceLiquidationEngine__TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert ValenceLiquidationEngine__Unauthorized();
        _;
    }

    modifier onlyClearinghouse() {
        if (msg.sender != clearinghouse) revert ValenceLiquidationEngine__Unauthorized();
        _;
    }

    constructor(
        address _portfolioMargin,
        address _vault,
        address _insuranceFund
    ) {
        if (_portfolioMargin == address(0) || _vault == address(0) || _insuranceFund == address(0)) {
            revert ValenceLiquidationEngine__ZeroAddress();
        }
        owner = msg.sender;
        portfolioMargin = IValencePortfolioMargin(_portfolioMargin);
        vault = IValenceVault(_vault);
        insuranceFund = IValenceInsuranceFund(_insuranceFund);
    }

    function setClearinghouse(address _clearinghouse) external onlyOwner {
        if (_clearinghouse == address(0)) revert ValenceLiquidationEngine__ZeroAddress();
        clearinghouse = _clearinghouse;
    }

    /// @notice Initiates a Dutch liquidation auction for an insolvent subaccount.
    function initiateLiquidation(bytes32 subaccountId) external override returns (bytes32 auctionId) {
        IValencePortfolioMargin.AccountRiskProfile memory profile = portfolioMargin.evaluateAccountRisk(subaccountId);
        if (!profile.isLiquidatable) revert ValenceLiquidationEngine__AccountNotLiquidatable();

        if (_subaccountActiveAuction[subaccountId] != bytes32(0)) {
            bytes32 existing = _subaccountActiveAuction[subaccountId];
            if (!_auctions[existing].isResolved && block.timestamp <= _auctions[existing].startTime + _auctions[existing].duration) {
                revert ValenceLiquidationEngine__AuctionAlreadyActive();
            }
        }

        auctionId = keccak256(abi.encodePacked(subaccountId, block.timestamp, ++_auctionNonce));

        uint256 debtToCover = profile.maintenanceMarginUsd;
        uint256 collateralAvailable = profile.totalCollateralValueUsd;

        _auctions[auctionId] = DutchAuction({
            auctionId: auctionId,
            subaccountId: subaccountId,
            debtToCoverUsd: debtToCover,
            collateralAvailableUsd: collateralAvailable,
            startTime: uint64(block.timestamp),
            duration: 300, // 5 minutes auction duration
            startDiscountBps: 200, // 2.0% starting discount
            maxDiscountBps: 1000, // 10.0% max discount
            isResolved: false
        });

        _subaccountActiveAuction[subaccountId] = auctionId;

        emit LiquidationAuctionStarted(auctionId, subaccountId, debtToCover, block.timestamp, 300);
    }

    /// @notice Purchases collateral from an active Dutch auction at the current decayed discount price.
    function executeLiquidationPurchase(bytes32 auctionId, uint256 debtAmountToRepay)
        external
        override
        returns (uint256 collateralAwardedUsd)
    {
        DutchAuction storage auction = _auctions[auctionId];
        if (auction.isResolved) revert ValenceLiquidationEngine__AuctionInactive();
        if (block.timestamp > auction.startTime + auction.duration) revert ValenceLiquidationEngine__AuctionExpired();

        uint256 discountBps = getCurrentDiscount(auctionId);

        // Value of collateral awarded = debtRepaid / (1 - discount)
        // e.g. 10% discount: 90 USD debt covers 100 USD collateral
        uint256 denominator = 10000 - discountBps;
        collateralAwardedUsd = (debtAmountToRepay * 10000) / denominator;

        if (collateralAwardedUsd > auction.collateralAvailableUsd) {
            collateralAwardedUsd = auction.collateralAvailableUsd;
        }

        auction.collateralAvailableUsd -= collateralAwardedUsd;
        if (debtAmountToRepay >= auction.debtToCoverUsd || auction.collateralAvailableUsd == 0) {
            auction.isResolved = true;
            delete _subaccountActiveAuction[auction.subaccountId];
        } else {
            auction.debtToCoverUsd -= debtAmountToRepay;
        }

        emit LiquidationAuctionFilled(auctionId, msg.sender, debtAmountToRepay, collateralAwardedUsd);
    }

    /// @notice Computes current liquidation discount in BPS based on elapsed time along exponential/linear decay curve.
    function getCurrentDiscount(bytes32 auctionId) public view override returns (uint256 discountBps) {
        DutchAuction memory auction = _auctions[auctionId];
        if (auction.startTime == 0) return 0;
        if (block.timestamp <= auction.startTime) return auction.startDiscountBps;

        uint64 elapsed = uint64(block.timestamp) - auction.startTime;
        if (elapsed >= auction.duration) return auction.maxDiscountBps;

        uint256 range = auction.maxDiscountBps - auction.startDiscountBps;
        // Linear decay approximation
        discountBps = auction.startDiscountBps + (range * elapsed) / auction.duration;
    }

    function getAuction(bytes32 auctionId) external view override returns (DutchAuction memory) {
        return _auctions[auctionId];
    }
}
