// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title BitMath
/// @notice Optimized bit manipulation routines for most-significant-bit and least-significant-bit discovery.
/// @dev Uses assembly binary search to evaluate 256-bit words in O(1) gas.
library BitMath {
    error BitMath__ZeroInput();

    /// @notice Returns the most significant bit of a non-zero 256-bit word.
    /// @param x The word to evaluate
    /// @return r The index of the most significant bit [0..255]
    function mostSignificantBit(uint256 x) internal pure returns (uint8 r) {
        if (x == 0) revert BitMath__ZeroInput();

        assembly {
            if iszero(lt(x, 0x100000000000000000000000000000000)) {
                x := shr(128, x)
                r := or(r, 128)
            }
            if iszero(lt(x, 0x10000000000000000)) {
                x := shr(64, x)
                r := or(r, 64)
            }
            if iszero(lt(x, 0x100000000)) {
                x := shr(32, x)
                r := or(r, 32)
            }
            if iszero(lt(x, 0x10000)) {
                x := shr(16, x)
                r := or(r, 16)
            }
            if iszero(lt(x, 0x100)) {
                x := shr(8, x)
                r := or(r, 8)
            }
            if iszero(lt(x, 0x10)) {
                x := shr(4, x)
                r := or(r, 4)
            }
            if iszero(lt(x, 0x4)) {
                x := shr(2, x)
                r := or(r, 2)
            }
            if iszero(lt(x, 0x2)) {
                r := or(r, 1)
            }
        }
    }

    /// @notice Returns the least significant bit of a non-zero 256-bit word.
    /// @param x The word to evaluate
    /// @return r The index of the least significant bit [0..255]
    function leastSignificantBit(uint256 x) internal pure returns (uint8 r) {
        if (x == 0) revert BitMath__ZeroInput();

        assembly {
            // Isolate lowest bit: x & -x
            let isolated := and(x, sub(0, x))
            if iszero(lt(isolated, 0x100000000000000000000000000000000)) {
                r := or(r, 128)
                isolated := shr(128, isolated)
            }
            if iszero(lt(isolated, 0x10000000000000000)) {
                r := or(r, 64)
                isolated := shr(64, isolated)
            }
            if iszero(lt(isolated, 0x100000000)) {
                r := or(r, 32)
                isolated := shr(32, isolated)
            }
            if iszero(lt(isolated, 0x10000)) {
                r := or(r, 16)
                isolated := shr(16, isolated)
            }
            if iszero(lt(isolated, 0x100)) {
                r := or(r, 8)
                isolated := shr(8, isolated)
            }
            if iszero(lt(isolated, 0x10)) {
                r := or(r, 4)
                isolated := shr(4, isolated)
            }
            if iszero(lt(isolated, 0x4)) {
                r := or(r, 2)
                isolated := shr(2, isolated)
            }
            if iszero(lt(isolated, 0x2)) {
                r := or(r, 1)
            }
        }
    }
}
