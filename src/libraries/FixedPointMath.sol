// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {FullMath} from "./FullMath.sol";

/// @title FixedPointMath
/// @notice High-precision fixed-point arithmetic for WAD (1e18) and RAY (1e27) numbers.
/// @dev Implements directional rounding, Taylor-series exponentiation, natural logarithm, and integer square roots.
library FixedPointMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant HALF_WAD = 0.5e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant HALF_RAY = 0.5e27;
    uint256 internal constant WAD_RAY_RATIO = 1e9;

    int256 internal constant MIN_NATURAL_EXPONENT = -41446531673892822312; // ln(2^-60) in WAD
    int256 internal constant MAX_NATURAL_EXPONENT = 130700829182905140221; // ln(2^188) in WAD

    error FixedPointMath__ZeroDivision();
    error FixedPointMath__ExponentOutOfBounds();
    error FixedPointMath__LogInputNonPositive();
    error FixedPointMath__NegativeSquareRoot();

    /// @notice Multiplies two WAD numbers with downward rounding.
    function mulWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return FullMath.mulDiv(x, y, WAD);
    }

    /// @notice Multiplies two WAD numbers with upward rounding.
    function mulWadUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(x, y, WAD);
    }

    /// @notice Divides two WAD numbers with downward rounding.
    function divWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return FullMath.mulDiv(x, WAD, y);
    }

    /// @notice Divides two WAD numbers with upward rounding.
    function divWadUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(x, WAD, y);
    }

    /// @notice Multiplies two RAY numbers with downward rounding.
    function mulRayDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return FullMath.mulDiv(x, y, RAY);
    }

    /// @notice Multiplies two RAY numbers with upward rounding.
    function mulRayUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(x, y, RAY);
    }

    /// @notice Divides two RAY numbers with downward rounding.
    function divRayDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return FullMath.mulDiv(x, RAY, y);
    }

    /// @notice Divides two RAY numbers with upward rounding.
    function divRayUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(x, RAY, y);
    }

    /// @notice Converts a WAD value to RAY precision.
    function wadToRay(uint256 x) internal pure returns (uint256) {
        unchecked {
            return x * WAD_RAY_RATIO;
        }
    }

    /// @notice Converts a RAY value to WAD precision with rounding down.
    function rayToWad(uint256 x) internal pure returns (uint256) {
        unchecked {
            return x / WAD_RAY_RATIO;
        }
    }

    /// @notice Computes floor(sqrt(x)) using Babylonian method.
    function sqrt(uint256 x) internal pure returns (uint256 z) {
        assembly {
            // Compute square root using Newton-Raphson approximation
            let y := x
            z := 181
            if iszero(lt(y, 0x10000000000000000000000000000000000)) {
                y := shr(128, y)
                z := shl(64, z)
            }
            if iszero(lt(y, 0x1000000000000000000)) {
                y := shr(64, y)
                z := shl(32, z)
            }
            if iszero(lt(y, 0x10000000000)) {
                y := shr(32, y)
                z := shl(16, z)
            }
            if iszero(lt(y, 0x1000000)) {
                y := shr(16, y)
                z := shl(8, z)
            }
            z := shr(18, mul(z, add(y, 65536)))

            // 7 iterations of Newton-Raphson
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))

            let zRoundDown := div(x, z)
            if lt(zRoundDown, z) {
                z := zRoundDown
            }
        }
    }

    /// @notice Natural exponential function e^x where x is in WAD precision.
    /// @dev Uses Taylor series expansion around 0 after scaling with powers of 2.
    function expWad(int256 x) internal pure returns (uint256) {
        if (x < MIN_NATURAL_EXPONENT || x > MAX_NATURAL_EXPONENT) {
            revert FixedPointMath__ExponentOutOfBounds();
        }

        if (x == 0) return WAD;

        unchecked {
            // Factor out integer part: x = k * ln(2) + r
            int256 LN2 = 693147180559945309; // ln(2) in WAD
            int256 k = x / LN2;
            int256 r = x - k * LN2;

            // Compute e^r using Taylor series: 1 + r + r^2/2! + r^3/3! + r^4/4! + r^5/5! + r^6/6!
            int256 term = int256(WAD);
            int256 sum = term;

            term = (term * r) / int256(WAD);
            sum += term;

            term = (term * r) / (2 * int256(WAD));
            sum += term;

            term = (term * r) / (3 * int256(WAD));
            sum += term;

            term = (term * r) / (4 * int256(WAD));
            sum += term;

            term = (term * r) / (5 * int256(WAD));
            sum += term;

            term = (term * r) / (6 * int256(WAD));
            sum += term;

            uint256 expR = uint256(sum);

            // Shift by 2^k
            if (k >= 0) {
                return expR << uint256(k);
            } else {
                return expR >> uint256(-k);
            }
        }
    }

    /// @notice Natural logarithm ln(x) where x is in WAD precision.
    /// @dev Approximates ln(x) using argument reduction and polynomial approximation.
    function lnWad(int256 x) internal pure returns (int256) {
        if (x <= 0) revert FixedPointMath__LogInputNonPositive();

        unchecked {
            int256 LN2 = 693147180559945309; // ln(2) in WAD
            int256 k = 0;
            uint256 y = uint256(x);

            // Normalize y into [0.5 * WAD, WAD] range
            while (y > WAD) {
                y >>= 1;
                k++;
            }
            while (y < HALF_WAD) {
                y <<= 1;
                k--;
            }

            // z = (y - 1) / (y + 1)
            int256 num = int256(y) - int256(WAD);
            int256 den = int256(y) + int256(WAD);
            int256 z = (num * int256(WAD)) / den;

            // ln(y) = 2 * (z + z^3/3 + z^5/5 + z^7/7)
            int256 z2 = (z * z) / int256(WAD);
            int256 z3 = (z2 * z) / int256(WAD);
            int256 z5 = (z3 * z2) / int256(WAD);
            int256 z7 = (z5 * z2) / int256(WAD);

            int256 series = z + z3 / 3 + z5 / 5 + z7 / 7;
            int256 lnY = 2 * series;

            return k * LN2 + lnY;
        }
    }

    /// @notice Computes absolute value of a signed integer.
    function abs(int256 x) internal pure returns (uint256) {
        unchecked {
            return x >= 0 ? uint256(x) : uint256(-x);
        }
    }

    /// @notice Returns minimum of two numbers.
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @notice Returns maximum of two numbers.
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}
