// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {FixedPointMath} from "./FixedPointMath.sol";

/// @title MatrixMath
/// @notice Matrix arithmetic and quadratic risk form evaluations for SPAN-style portfolio margin.
/// @dev Implements fixed-point vector dot products, quadratic covariance evaluation, and risk offsets.
library MatrixMath {
    using FixedPointMath for uint256;
    using FixedPointMath for int256;

    error MatrixMath__DimensionMismatch();
    error MatrixMath__NegativeVariance();

    /// @notice Computes dot product of two signed vectors: sum(u[i] * v[i]) in WAD precision.
    /// @param u First vector
    /// @param v Second vector
    /// @return result The scalar dot product in WAD
    function dotProduct(int256[] memory u, int256[] memory v) internal pure returns (int256 result) {
        if (u.length != v.length) revert MatrixMath__DimensionMismatch();
        uint256 len = u.length;
        for (uint256 i = 0; i < len;) {
            int256 prod = (u[i] * v[i]) / int256(FixedPointMath.WAD);
            result += prod;
            unchecked {
                i++;
            }
        }
    }

    /// @notice Computes the portfolio quadratic risk form: w^T * Sigma * w.
    /// @dev Sigma is an N x N covariance matrix represented in row-major order: Sigma[i * N + j].
    /// @param weights Position notional weights vector w of length N in WAD
    /// @param covMatrix Flattened covariance matrix of length N * N in WAD
    /// @return portfolioVariance The net portfolio variance in WAD
    function quadraticRiskForm(
        int256[] memory weights,
        int256[] memory covMatrix
    ) internal pure returns (uint256 portfolioVariance) {
        uint256 n = weights.length;
        if (covMatrix.length != n * n) revert MatrixMath__DimensionMismatch();

        int256 totalVariance = 0;

        for (uint256 i = 0; i < n;) {
            int256 wi = weights[i];
            if (wi != 0) {
                int256 rowSum = 0;
                uint256 rowOffset = i * n;
                for (uint256 j = 0; j < n;) {
                    int256 wj = weights[j];
                    if (wj != 0) {
                        int256 cov = covMatrix[rowOffset + j];
                        rowSum += (wj * cov) / int256(FixedPointMath.WAD);
                    }
                    unchecked {
                        j++;
                    }
                }
                totalVariance += (wi * rowSum) / int256(FixedPointMath.WAD);
            }
            unchecked {
                i++;
            }
        }

        if (totalVariance < 0) revert MatrixMath__NegativeVariance();
        return uint256(totalVariance);
    }

    /// @notice Computes standard deviation (Value-at-Risk basis) from quadratic risk variance.
    /// @param portfolioVariance The variance in WAD
    /// @return portfolioStdDev The standard deviation (sqrt) in WAD
    function portfolioStandardDeviation(uint256 portfolioVariance) internal pure returns (uint256 portfolioStdDev) {
        // sqrt(variance * WAD) gives result in WAD
        return FixedPointMath.sqrt(portfolioVariance * FixedPointMath.WAD);
    }

    /// @notice Computes correlation-adjusted risk offset between two assets.
    /// @param notionalA Net notional exposure to asset A
    /// @param notionalB Net notional exposure to asset B
    /// @param volA Annualized volatility of asset A in WAD
    /// @param volB Annualized volatility of asset B in WAD
    /// @param correlation Correlation coefficient between A and B in WAD [-WAD..WAD]
    /// @return netRisk The net portfolio risk of the two-asset pair
    function twoAssetNetRisk(
        int256 notionalA,
        int256 notionalB,
        uint256 volA,
        uint256 volB,
        int256 correlation
    ) internal pure returns (uint256 netRisk) {
        int256 riskA = (notionalA * int256(volA)) / int256(FixedPointMath.WAD);
        int256 riskB = (notionalB * int256(volB)) / int256(FixedPointMath.WAD);

        int256 varA = (riskA * riskA) / int256(FixedPointMath.WAD);
        int256 varB = (riskB * riskB) / int256(FixedPointMath.WAD);
        int256 covAB = 2 * (riskA * riskB * correlation) / int256(FixedPointMath.WAD * FixedPointMath.WAD);

        int256 totalVar = varA + varB + covAB;
        if (totalVar < 0) totalVar = 0;

        return FixedPointMath.sqrt(uint256(totalVar) * FixedPointMath.WAD);
    }
}
