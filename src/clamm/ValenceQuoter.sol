// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IValencePoolFactory} from "../interfaces/IValencePoolFactory.sol";
import {IValencePool} from "../interfaces/IValencePool.sol";
import {IValenceSwapCallback} from "./ValencePool.sol";

/// @title ValenceQuoter
/// @notice Stateless exact-input and exact-output quote engine for concentrated liquidity pools.
/// @dev Executes simulated swaps and catches the revert payload to return exact quotes off-chain and on-chain.
contract ValenceQuoter is IValenceSwapCallback {
    address public immutable factory;

    error ValenceQuoter__QuoteResult(
        uint256 amountOut,
        uint160 sqrtPriceX96After,
        int24 tickAfter
    );

    error ValenceQuoter__PoolNotFound();

    constructor(address _factory) {
        require(_factory != address(0), "Zero address");
        factory = _factory;
    }

    /// @notice Returns the quote for an exact-input single pool swap.
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountOut, uint160 sqrtPriceX96After, int24 tickAfter) {
        bool zeroForOne = tokenIn < tokenOut;
        address pool = IValencePoolFactory(factory).getPool(tokenIn, tokenOut, fee);
        if (pool == address(0)) revert ValenceQuoter__PoolNotFound();

        try IValencePool(pool).swap(
            address(this),
            zeroForOne,
            int256(amountIn),
            sqrtPriceLimitX96 == 0
                ? (zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341)
                : sqrtPriceLimitX96,
            abi.encode(pool)
        ) {} catch (bytes memory reason) {
            return _parseRevertReason(reason);
        }
    }

    /// @notice Callback called during simulation swap to trigger revert with results.
    function valenceSwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external view override {
        address expectedPool = abi.decode(data, (address));
        require(msg.sender == expectedPool, "Unauthorized");

        (uint160 sqrtPriceX96, int24 tick,,,,,) = IValencePool(expectedPool).slot0();

        uint256 amountOut = uint256(-(amount0Delta < 0 ? amount0Delta : amount1Delta));
        revert ValenceQuoter__QuoteResult(amountOut, sqrtPriceX96, tick);
    }

    function _parseRevertReason(bytes memory reason)
        private
        pure
        returns (uint256 amountOut, uint160 sqrtPriceX96After, int24 tickAfter)
    {
        if (reason.length >= 4 && bytes4(reason) == ValenceQuoter__QuoteResult.selector) {
            assembly {
                reason := add(reason, 0x04)
            }
            return abi.decode(reason, (uint256, uint160, int24));
        }
        revert("Unexpected quote failure");
    }
}
