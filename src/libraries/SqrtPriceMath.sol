// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {FullMath} from "./FullMath.sol";
import {SafeCast} from "./SafeCast.sol";

/// @title SqrtPriceMath
/// @notice Computes token amounts and next prices for concentrated liquidity transitions.
library SqrtPriceMath {
    using SafeCast for uint256;

    error SqrtPriceMath__InvalidPrice();
    error SqrtPriceMath__InvalidLiquidity();
    error SqrtPriceMath__PriceOverflow();

    /// @notice Gets the amount0 delta between two sqrt prices.
    /// @dev Calculates amount0 = (liquidity * 2^96 * (sqrtB - sqrtA)) / (sqrtB * sqrtA)
    function getAmount0Delta(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity,
        bool roundUp
    ) internal pure returns (uint256 amount0) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        if (sqrtRatioAX96 == 0) revert SqrtPriceMath__InvalidPrice();

        uint256 numerator1 = uint256(liquidity) << 96;
        uint256 numerator2 = sqrtRatioBX96 - sqrtRatioAX96;

        return roundUp
            ? FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(numerator1, numerator2, sqrtRatioBX96), 1, sqrtRatioAX96)
            : FullMath.mulDiv(numerator1, numerator2, sqrtRatioBX96) / sqrtRatioAX96;
    }

    /// @notice Gets the amount1 delta between two sqrt prices.
    /// @dev Calculates amount1 = liquidity * (sqrtB - sqrtA) / 2^96
    function getAmount1Delta(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity,
        bool roundUp
    ) internal pure returns (uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        return roundUp
            ? FullMath.mulDivRoundingUp(liquidity, sqrtRatioBX96 - sqrtRatioAX96, 1 << 96)
            : FullMath.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, 1 << 96);
    }

    /// @notice Calculates the next sqrt price given an input amount of token0 or token1.
    function getNextSqrtPriceFromInput(
        uint160 sqrtPX96,
        uint128 liquidity,
        uint256 amountIn,
        bool zeroForOne
    ) internal pure returns (uint160 sqrtQX96) {
        if (sqrtPX96 == 0) revert SqrtPriceMath__InvalidPrice();
        if (liquidity == 0) revert SqrtPriceMath__InvalidLiquidity();

        return zeroForOne
            ? getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity, amountIn, true)
            : getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amountIn, true);
    }

    /// @notice Calculates the next sqrt price given an output amount of token0 or token1.
    function getNextSqrtPriceFromOutput(
        uint160 sqrtPX96,
        uint128 liquidity,
        uint256 amountOut,
        bool zeroForOne
    ) internal pure returns (uint160 sqrtQX96) {
        if (sqrtPX96 == 0) revert SqrtPriceMath__InvalidPrice();
        if (liquidity == 0) revert SqrtPriceMath__InvalidLiquidity();

        return zeroForOne
            ? getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amountOut, false)
            : getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity, amountOut, false);
    }

    /// @notice Computes next sqrt price from amount0 delta.
    function getNextSqrtPriceFromAmount0RoundingUp(
        uint160 sqrtPX96,
        uint128 liquidity,
        uint256 amount,
        bool add
    ) internal pure returns (uint160) {
        if (amount == 0) return sqrtPX96;
        uint256 numerator1 = uint256(liquidity) << 96;

        if (add) {
            uint256 product;
            if ((product = amount * sqrtPX96) / amount == sqrtPX96) {
                uint256 denominator = numerator1 + product;
                if (denominator >= numerator1) {
                    return uint160(FullMath.mulDivRoundingUp(numerator1, sqrtPX96, denominator));
                }
            }
            return uint160(FullMath.mulDivRoundingUp(numerator1, 1, (numerator1 / sqrtPX96) + amount));
        } else {
            uint256 product;
            if ((product = amount * sqrtPX96) / amount != sqrtPX96 || numerator1 <= product) {
                revert SqrtPriceMath__PriceOverflow();
            }
            uint256 denominator = numerator1 - product;
            return uint160(FullMath.mulDivRoundingUp(numerator1, sqrtPX96, denominator));
        }
    }

    /// @notice Computes next sqrt price from amount1 delta.
    function getNextSqrtPriceFromAmount1RoundingDown(
        uint160 sqrtPX96,
        uint128 liquidity,
        uint256 amount,
        bool add
    ) internal pure returns (uint160) {
        if (add) {
            uint256 quotient = (amount <= type(uint160).max)
                ? (amount << 96) / liquidity
                : FullMath.mulDiv(amount, 1 << 96, liquidity);

            return uint160(uint256(sqrtPX96) + quotient);
        } else {
            uint256 quotient = (amount <= type(uint160).max)
                ? FullMath.mulDivRoundingUp(amount, 1 << 96, liquidity)
                : FullMath.mulDivRoundingUp(amount, 1 << 96, liquidity);

            if (sqrtPX96 <= quotient) revert SqrtPriceMath__PriceOverflow();
            return uint160(sqrtPX96 - quotient);
        }
    }
}
