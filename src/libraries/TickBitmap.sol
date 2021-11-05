// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {BitMath} from "./BitMath.sol";

/// @title TickBitmap
/// @notice Stores packed bitmap of initialized ticks for concentrated liquidity AMM pools.
/// @dev Each bit in a 256-bit word represents whether a specific tick is initialized with liquidity.
library TickBitmap {
    /// @notice Computes position of a tick in the bitmap.
    /// @param tick The tick to find
    /// @return wordPos The int16 word index
    /// @return bitPos The uint8 bit offset within the word
    function position(int24 tick) private pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(tick >> 8);
        bitPos = uint8(uint24(tick % 256));
    }

    /// @notice Flips the initialization state of a tick in the bitmap.
    /// @param self The bitmap mapping in contract storage
    /// @param tick The tick to flip
    /// @param tickSpacing The tick spacing of the pool
    function flipTick(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing
    ) internal {
        require(tick % tickSpacing == 0, "Tick not on spacing boundary");
        (int16 wordPos, uint8 bitPos) = position(tick / tickSpacing);
        uint256 mask = 1 << bitPos;
        self[wordPos] ^= mask;
    }

    /// @notice Finds the next initialized tick within the same 256-bit word.
    /// @param self The bitmap mapping in contract storage
    /// @param tick The current tick
    /// @param tickSpacing The pool tick spacing
    /// @param lte True if searching downward (selling token0 for token1), false if searching upward
    /// @return next The next initialized tick, or the boundary of the current word if none found
    /// @return initialized True if an initialized tick was found within the word
    function nextInitializedTickWithinOneWord(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing,
        bool lte
    ) internal view returns (int24 next, bool initialized) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--; // Round toward negative infinity

        if (lte) {
            (int16 wordPos, uint8 bitPos) = position(compressed);
            // All bits at or below bitPos: mask = (1 << (bitPos + 1)) - 1
            uint256 mask = (1 << bitPos) - 1 + (1 << bitPos);
            uint256 masked = self[wordPos] & mask;

            initialized = masked != 0;
            // If initialized, next is MSB of masked bits; otherwise next is the lowest bit of the word
            next = initialized
                ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                : (compressed - int24(uint24(bitPos))) * tickSpacing;
        } else {
            // Searching strictly greater than current tick
            (int16 wordPos, uint8 bitPos) = position(compressed + 1);
            // All bits at or above bitPos: mask = ~((1 << bitPos) - 1)
            uint256 mask = ~((1 << bitPos) - 1);
            uint256 masked = self[wordPos] & mask;

            initialized = masked != 0;
            // If initialized, next is LSB of masked bits; otherwise next is the highest bit of the word
            next = initialized
                ? (compressed + 1 + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                : (compressed + 1 + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
        }
    }
}
