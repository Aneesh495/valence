// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title FullMath
/// @notice Facilitates multiplication and division that can have overflow of an intermediate value without loss of precision.
/// @dev Handles "phantom overflow": where (a * b) would exceed 256 bits, but (a * b) / denominator fits into 256 bits.
/// Credit to Remco Bloemen under MIT license https://2π.com/17/512-bit-division
library FullMath {
    /// @notice Thrown when the denominator is zero.
    error FullMath__DenominatorIsZero();

    /// @notice Thrown when the 512-bit division result overflows uint256.
    error FullMath__Overflow512();

    /// @notice Calculates floor(a * b / denominator) with full 512-bit precision.
    /// @param a The multiplicand
    /// @param b The multiplier
    /// @param denominator The divisor
    /// @return result The 256-bit rounded-down quotient
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = a * b.
            // Compute the product mod 2**256 and mod 2**256 - 1
            // then use the Chinese Remainder Theorem to reconstruct the 512 bit result.
            uint256 prod0; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases, 256 by 256 division
            if (prod1 == 0) {
                if (denominator == 0) revert FullMath__DenominatorIsZero();
                assembly {
                    result := div(prod0, denominator)
                }
                return result;
            }

            // Ensure the result fits in 256 bits
            if (denominator <= prod1) revert FullMath__Overflow512();

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [prod1 prod0].
            // Compute remainder using mulmod.
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
            }
            // Subtract 256 bit number from 512 bit number
            assembly {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator.
            // Compute largest power of two divisor of denominator: denominator & (~denominator + 1).
            uint256 twos = (0 - denominator) & denominator;
            // Divide denominator by power of two
            assembly {
                denominator := div(denominator, twos)
            }

            // Divide [prod1 prod0] by the factors of two
            assembly {
                prod0 := div(prod0, twos)
            }
            // Shift in bits from prod1 into prod0. For this we need
            // to flip `twos` such that it is 2**256 / twos.
            // If twos is 1, then twos = 0.
            assembly {
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            // Invert denominator mod 2**256
            // Now that denominator is an odd number, it has an inverse
            // modulo 2**256 such that denominator * inv = 1 mod 2**256.
            // Compute the inverse using Newton-Raphson iteration in the
            // ring of integers modulo 2**256, starting from a 3-bit approximation.
            uint256 inv = (3 * denominator) ^ 2;
            // Newton-Raphson iterations to double correct bits: 3 -> 6 -> 12 -> 24 -> 48 -> 96 -> 192 -> 256
            inv *= 2 - denominator * inv; // inverse mod 2**8
            inv *= 2 - denominator * inv; // inverse mod 2**16
            inv *= 2 - denominator * inv; // inverse mod 2**32
            inv *= 2 - denominator * inv; // inverse mod 2**64
            inv *= 2 - denominator * inv; // inverse mod 2**128
            inv *= 2 - denominator * inv; // inverse mod 2**256

            // Because the division is now exact we can divide by multiplying
            // with the modular inverse of denominator.
            // This will give us the correct result modulo 2**256.
            // Since the preconditions guarantee that the outcome is less than 2**256,
            // this is the final result.
            result = prod0 * inv;
            return result;
        }
    }

    /// @notice Calculates ceil(a * b / denominator) with full 512-bit precision.
    /// @param a The multiplicand
    /// @param b The multiplier
    /// @param denominator The divisor
    /// @return result The 256-bit rounded-up quotient
    function mulDivRoundingUp(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            result = mulDiv(a, b, denominator);
            if (mulmod(a, b, denominator) > 0) {
                if (result == type(uint256).max) revert FullMath__Overflow512();
                result++;
            }
        }
    }
}
