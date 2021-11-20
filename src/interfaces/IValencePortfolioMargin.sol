// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title IValencePortfolioMargin
/// @notice Evaluates net cross-asset portfolio risk, margin requirements, and liquidation solvency.
interface IValencePortfolioMargin {
    struct AccountRiskProfile {
        uint256 totalCollateralValueUsd;  // Haircut collateral value in WAD
        uint256 totalUnrealizedPnlUsd;    // Net unrealized profit/loss across open positions
        uint256 initialMarginRequiredUsd; // Required margin for opening/increasing positions
        uint256 maintenanceMarginUsd;     // Required margin to prevent liquidation
        uint256 healthFactor;             // (Collateral + PnL) / MaintenanceMargin in WAD (1e18 = 100%)
        bool isSolvent;                   // Health factor >= 1e18
        bool isLiquidatable;              // Health factor < 1e18
    }

    struct PositionSummary {
        bytes32 marketId;
        int256 size;           // Positive for long, negative for short
        uint256 entryPriceX96; // Average entry price
        int256 unrealizedPnl;  // Unrealized profit/loss in WAD
        uint256 notionalUsd;   // Position size * current oracle mark price
    }

    function evaluateAccountRisk(bytes32 subaccountId) external view returns (AccountRiskProfile memory profile);
    function getMaintenanceMarginRequirement(bytes32 subaccountId) external view returns (uint256 mmrUsd);
    function getInitialMarginRequirement(bytes32 subaccountId) external view returns (uint256 imrUsd);
    function checkSolvency(bytes32 subaccountId) external view returns (bool isSolvent);
    function computeHypotheticalRisk(
        bytes32 subaccountId,
        bytes32 marketId,
        int256 deltaSize
    ) external view returns (AccountRiskProfile memory hypotheticalProfile);
}
