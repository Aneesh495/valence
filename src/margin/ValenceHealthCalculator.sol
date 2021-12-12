// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IValencePortfolioMargin} from "../interfaces/IValencePortfolioMargin.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";

/// @title ValenceHealthCalculator
/// @notice Computes real-time leverage metrics, free margin capacity, and liquidation proximity buffers.
contract ValenceHealthCalculator {
    using FixedPointMath for uint256;

    IValencePortfolioMargin public immutable portfolioMargin;

    struct HealthMetrics {
        uint256 healthFactor;           // In WAD (1e18 = 100%)
        uint256 freeCollateralUsd;      // Collateral available for withdrawal or new positions
        uint256 currentLeverageWad;     // Total position notional / Net equity
        uint256 maxLeverageWad;         // Theoretical maximum leverage before liquidation
        uint256 liquidationBufferBps;   // Percentage drop in portfolio value before liquidation
        bool canOpenPositions;          // Health factor allows new positions
        bool isAtRiskOfLiquidation;     // Health factor between 100% and 115%
    }

    constructor(address _portfolioMargin) {
        require(_portfolioMargin != address(0), "Zero address");
        portfolioMargin = IValencePortfolioMargin(_portfolioMargin);
    }

    /// @notice Computes comprehensive health and solvency metrics for a subaccount.
    function getAccountHealthMetrics(bytes32 subaccountId)
        external
        view
        returns (HealthMetrics memory metrics)
    {
        IValencePortfolioMargin.AccountRiskProfile memory profile = portfolioMargin.evaluateAccountRisk(subaccountId);

        metrics.healthFactor = profile.healthFactor;
        metrics.canOpenPositions = profile.isSolvent && (profile.totalCollateralValueUsd > profile.initialMarginRequiredUsd);

        if (profile.totalCollateralValueUsd > profile.initialMarginRequiredUsd) {
            metrics.freeCollateralUsd = profile.totalCollateralValueUsd - profile.initialMarginRequiredUsd;
        } else {
            metrics.freeCollateralUsd = 0;
        }

        uint256 netEquity = profile.totalCollateralValueUsd + profile.totalUnrealizedPnlUsd;
        if (netEquity > 0 && profile.maintenanceMarginUsd > 0) {
            metrics.currentLeverageWad = (profile.maintenanceMarginUsd * FixedPointMath.WAD * 40) / netEquity; // Normalized leverage
            metrics.maxLeverageWad = (FixedPointMath.WAD * 10000) / 250; // 40x max leverage
        }

        // Buffer = (HealthFactor - 1.0) / HealthFactor in BPS
        if (profile.healthFactor > FixedPointMath.WAD) {
            uint256 excess = profile.healthFactor - FixedPointMath.WAD;
            metrics.liquidationBufferBps = (excess * 10000) / profile.healthFactor;
            metrics.isAtRiskOfLiquidation = profile.healthFactor <= 1.15e18;
        } else {
            metrics.liquidationBufferBps = 0;
            metrics.isAtRiskOfLiquidation = true;
        }
    }
}
