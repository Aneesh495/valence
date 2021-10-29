// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title SafeCast
/// @notice Custom casting library that reverts with descriptive custom errors on overflow or underflow.
library SafeCast {
    error SafeCast__Uint256Overflow();
    error SafeCast__Uint128Overflow();
    error SafeCast__Uint160Overflow();
    error SafeCast__Int256Overflow();
    error SafeCast__Int128Overflow();

    /// @notice Casts uint256 to uint128, reverting on overflow.
    function toUint128(uint256 y) internal pure returns (uint128 z) {
        if ((z = uint128(y)) != y) revert SafeCast__Uint128Overflow();
    }

    /// @notice Casts uint256 to uint160, reverting on overflow.
    function toUint160(uint256 y) internal pure returns (uint160 z) {
        if ((z = uint160(y)) != y) revert SafeCast__Uint160Overflow();
    }

    /// @notice Casts uint256 to int256, reverting on overflow.
    function toInt256(uint256 y) internal pure returns (int256 z) {
        if (y > uint256(type(int256).max)) revert SafeCast__Int256Overflow();
        z = int256(y);
    }

    /// @notice Casts int256 to int128, reverting on overflow/underflow.
    function toInt128(int256 y) internal pure returns (int128 z) {
        if ((z = int128(y)) != y) revert SafeCast__Int128Overflow();
    }

    /// @notice Casts int256 to uint256, reverting if negative.
    function toUint256(int256 y) internal pure returns (uint256 z) {
        if (y < 0) revert SafeCast__Uint256Overflow();
        z = uint256(y);
    }
}
