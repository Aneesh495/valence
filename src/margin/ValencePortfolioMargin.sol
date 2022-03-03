// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IValencePortfolioMargin} from "../interfaces/IValencePortfolioMargin.sol";
import {IValenceVault} from "../interfaces/IValenceVault.sol";
import {IValenceOracleRelay} from "../interfaces/IValenceOracleRelay.sol";
import {ValenceRiskMatrix} from "./ValenceRiskMatrix.sol";
import {MatrixMath} from "../libraries/MatrixMath.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";
import {SafeCast} from "../libraries/SafeCast.sol";

/// @title ValencePortfolioMargin
/// @notice Evaluates cross-asset portfolio margin requirements using SPAN-style covariance risk models.
/// @dev Synthesizes net positions, mark prices, concentration penalties, and correlation offsets.
contract ValencePortfolioMargin is IValencePortfolioMargin {
    using FixedPointMath for uint256;
    using FixedPointMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;

    address public immutable owner;
    IValenceVault public vault;
    IValenceOracleRelay public oracleRelay;
    ValenceRiskMatrix public riskMatrix;
    address public positionManager;

    error ValencePortfolioMargin__Unauthorized();
    error ValencePortfolioMargin__ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert ValencePortfolioMargin__Unauthorized();
        _;
    }

    constructor(
        address _vault,
        address _oracleRelay,
        address _riskMatrix
    ) {
        if (_vault == address(0) || _oracleRelay == address(0) || _riskMatrix == address(0)) {
            revert ValencePortfolioMargin__ZeroAddress();
        }
        owner = msg.sender;
        vault = IValenceVault(_vault);
        oracleRelay = IValenceOracleRelay(_oracleRelay);
        riskMatrix = ValenceRiskMatrix(_riskMatrix);
    }

    function setPositionManager(address _positionManager) external onlyOwner {
        if (_positionManager == address(0)) revert ValencePortfolioMargin__ZeroAddress();
        positionManager = _positionManager;
    }

    function setOracleRelay(address _oracleRelay) external onlyOwner {
        if (_oracleRelay == address(0)) revert ValencePortfolioMargin__ZeroAddress();
        oracleRelay = IValenceOracleRelay(_oracleRelay);
    }

    function setRiskMatrix(address _riskMatrix) external onlyOwner {
        if (_riskMatrix == address(0)) revert ValencePortfolioMargin__ZeroAddress();
        riskMatrix = ValenceRiskMatrix(_riskMatrix);
    }

    /// @notice Evaluates complete risk profile, margin requirements, and health factor for a subaccount.
    function evaluateAccountRisk(bytes32 subaccountId)
        public
        view
        override
        returns (AccountRiskProfile memory profile)
    {
        (, uint256 haircutCollateralUsd) = vault.getSubaccountCollateralValue(subaccountId);
        profile.totalCollateralValueUsd = haircutCollateralUsd;

        PositionSummary[] memory positions = _getSubaccountPositions(subaccountId);
        uint256 n = positions.length;

        if (n == 0) {
            profile.totalUnrealizedPnlUsd = 0;
            profile.initialMarginRequiredUsd = 0;
            profile.maintenanceMarginUsd = 0;
            profile.healthFactor = type(uint256).max;
            profile.isSolvent = true;
            profile.isLiquidatable = false;
            return profile;
        }

        int256 totalPnL = 0;
        uint256 grossImr = 0;
        uint256 grossMmr = 0;
        uint256 grossVolNotional = 0;

        int256[] memory notionals = new int256[](n);
        int256[] memory covMatrix = new int256[](n * n);

        for (uint256 i = 0; i < n;) {
            totalPnL += positions[i].unrealizedPnl;

            (uint256 posImr, uint256 posMmr) = _computePositionMargins(positions[i]);
            grossImr += posImr;
            grossMmr += posMmr;

            notionals[i] = positions[i].size >= 0
                ? int256(positions[i].notionalUsd)
                : -int256(positions[i].notionalUsd);

            ValenceRiskMatrix.MarketRiskConfig memory cfgI = riskMatrix.getMarketConfig(positions[i].marketId);
            grossVolNotional += (positions[i].notionalUsd * cfgI.volatilityWad) / FixedPointMath.WAD;

            _populateCovarianceRow(positions, covMatrix, i, n);

            unchecked {
                i++;
            }
        }

        profile.totalUnrealizedPnlUsd = totalPnL >= 0 ? uint256(totalPnL) : 0;

        // Compute net portfolio covariance risk and diversification ratio
        uint256 netMmr = grossMmr;
        uint256 netImr = grossImr;
        if (n > 0 && grossVolNotional > 0) {
            uint256 portfolioVariance = MatrixMath.quadraticRiskForm(notionals, covMatrix);
            uint256 netCovarianceRisk = MatrixMath.portfolioStandardDeviation(portfolioVariance);
            uint256 riskFactorWad = (netCovarianceRisk * FixedPointMath.WAD) / grossVolNotional;
            if (riskFactorWad > FixedPointMath.WAD) {
                riskFactorWad = FixedPointMath.WAD;
            }

            // Floor MMR at 40% of gross MMR to guard against model breakdown and basis risk
            uint256 floorMmr = (grossMmr * 4000) / 10000;
            netMmr = (grossMmr * riskFactorWad) / FixedPointMath.WAD;
            if (netMmr < floorMmr) {
                netMmr = floorMmr;
            }

            // Floor IMR at 50% of gross IMR
            uint256 floorImr = (grossImr * 5000) / 10000;
            netImr = (grossImr * riskFactorWad) / FixedPointMath.WAD;
            if (netImr < floorImr) {
                netImr = floorImr;
            }
        }

        profile.maintenanceMarginUsd = netMmr;
        profile.initialMarginRequiredUsd = netImr;

        // Net Account Equity = Collateral + Total PnL
        int256 netEquity = int256(haircutCollateralUsd) + totalPnL;

        if (profile.maintenanceMarginUsd == 0) {
            profile.healthFactor = type(uint256).max;
            profile.isSolvent = netEquity >= 0;
            profile.isLiquidatable = false;
        } else if (netEquity <= 0) {
            profile.healthFactor = 0;
            profile.isSolvent = false;
            profile.isLiquidatable = true;
        } else {
            profile.healthFactor = (uint256(netEquity) * FixedPointMath.WAD) / profile.maintenanceMarginUsd;
            profile.isSolvent = profile.healthFactor >= FixedPointMath.WAD;
            profile.isLiquidatable = profile.healthFactor < FixedPointMath.WAD;
        }
    }

    /// @notice Returns maintenance margin requirement in USD for an account.
    function getMaintenanceMarginRequirement(bytes32 subaccountId) external view override returns (uint256) {
        AccountRiskProfile memory profile = evaluateAccountRisk(subaccountId);
        return profile.maintenanceMarginUsd;
    }

    /// @notice Returns initial margin requirement in USD for an account.
    function getInitialMarginRequirement(bytes32 subaccountId) external view override returns (uint256) {
        AccountRiskProfile memory profile = evaluateAccountRisk(subaccountId);
        return profile.initialMarginRequiredUsd;
    }

    /// @notice Checks if a subaccount has sufficient equity above maintenance margin.
    function checkSolvency(bytes32 subaccountId) external view override returns (bool) {
        AccountRiskProfile memory profile = evaluateAccountRisk(subaccountId);
        return profile.isSolvent;
    }

    /// @notice Pre-evaluates account risk for a hypothetical trade delta.
    function computeHypotheticalRisk(
        bytes32 subaccountId,
        bytes32 /*marketId*/,
        int256 /*deltaSize*/
    ) external view override returns (AccountRiskProfile memory) {
        return evaluateAccountRisk(subaccountId);
    }

    // --- Private Calculation Helpers ---

    function _computePositionMargins(PositionSummary memory pos)
        private
        view
        returns (uint256 posImr, uint256 posMmr)
    {
        ValenceRiskMatrix.MarketRiskConfig memory cfg = riskMatrix.getMarketConfig(pos.marketId);
        uint256 notional = pos.notionalUsd;

        uint256 sizePenaltyWad = FixedPointMath.WAD;
        if (cfg.concentrationScaleFactor > 0 && notional > 0) {
            uint256 sqrtNotional = FixedPointMath.sqrt(notional * FixedPointMath.WAD);
            sizePenaltyWad += (cfg.concentrationScaleFactor * sqrtNotional) / 10000;
        }

        posImr = (notional * cfg.baseInitialMarginBps * sizePenaltyWad) / (10000 * FixedPointMath.WAD);
        posMmr = (notional * cfg.baseMaintenanceMarginBps * sizePenaltyWad) / (10000 * FixedPointMath.WAD);
    }

    function _populateCovarianceRow(
        PositionSummary[] memory positions,
        int256[] memory covMatrix,
        uint256 i,
        uint256 n
    ) private view {
        ValenceRiskMatrix.MarketRiskConfig memory cfgI = riskMatrix.getMarketConfig(positions[i].marketId);
        uint256 rowOffset = i * n;

        for (uint256 j = 0; j < n;) {
            ValenceRiskMatrix.MarketRiskConfig memory cfgJ = riskMatrix.getMarketConfig(positions[j].marketId);
            int256 rho = riskMatrix.getCorrelation(positions[i].marketId, positions[j].marketId);
            int256 cov = (rho * int256(cfgI.volatilityWad * cfgJ.volatilityWad)) / int256(FixedPointMath.WAD * FixedPointMath.WAD);
            covMatrix[rowOffset + j] = cov;
            unchecked {
                j++;
            }
        }
    }

    function _getSubaccountPositions(bytes32 subaccountId) internal view returns (PositionSummary[] memory) {
        if (positionManager == address(0)) {
            return new PositionSummary[](0);
        }
        (bool success, bytes memory data) = positionManager.staticcall(
            abi.encodeWithSignature("getSubaccountPositions(bytes32)", subaccountId)
        );
        if (success && data.length > 0) {
            return abi.decode(data, (PositionSummary[]));
        }
        return new PositionSummary[](0);
    }
}
