// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IValenceRouter} from "../interfaces/IValenceRouter.sol";
import {IValencePoolFactory} from "../interfaces/IValencePoolFactory.sol";
import {IValencePool} from "../interfaces/IValencePool.sol";
import {IValenceSwapCallback} from "./ValencePool.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {SafeCast} from "../libraries/SafeCast.sol";

/// @title ValenceRouter
/// @notice Periphery execution contract for single-hop and multi-hop concentrated liquidity swaps.
/// @dev Implements callback token transfers, slippage bounding, and deadline assertions.
contract ValenceRouter is IValenceRouter, IValenceSwapCallback {
    using SafeCast for uint256;

    address public immutable factory;

    error ValenceRouter__DeadlineExpired();
    error ValenceRouter__PoolNotFound();
    error ValenceRouter__SlippageExceeded();
    error ValenceRouter__UnauthorizedCallback();
    error ValenceRouter__TransferFailed();

    struct SwapCallbackData {
        bytes path;
        address payer;
    }

    constructor(address _factory) {
        require(_factory != address(0), "Zero address");
        factory = _factory;
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert ValenceRouter__DeadlineExpired();
        _;
    }

    /// @notice Swaps an exact amount of input tokens for as many output tokens as possible.
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        bool zeroForOne = params.tokenIn < params.tokenOut;
        address pool = IValencePoolFactory(factory).getPool(params.tokenIn, params.tokenOut, params.fee);
        if (pool == address(0)) revert ValenceRouter__PoolNotFound();

        (int256 amount0, int256 amount1) = IValencePool(pool).swap(
            params.recipient,
            zeroForOne,
            int256(params.amountIn),
            params.sqrtPriceLimitX96 == 0
                ? (zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341)
                : params.sqrtPriceLimitX96,
            abi.encode(SwapCallbackData({
                path: abi.encodePacked(params.tokenIn, params.fee, params.tokenOut),
                payer: msg.sender
            }))
        );

        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
        if (amountOut < params.amountOutMinimum) revert ValenceRouter__SlippageExceeded();
    }

    /// @notice Swaps as few input tokens as possible for an exact amount of output tokens.
    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 amountIn)
    {
        bool zeroForOne = params.tokenIn < params.tokenOut;
        address pool = IValencePoolFactory(factory).getPool(params.tokenIn, params.tokenOut, params.fee);
        if (pool == address(0)) revert ValenceRouter__PoolNotFound();

        (int256 amount0, int256 amount1) = IValencePool(pool).swap(
            params.recipient,
            zeroForOne,
            -int256(params.amountOut),
            params.sqrtPriceLimitX96 == 0
                ? (zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341)
                : params.sqrtPriceLimitX96,
            abi.encode(SwapCallbackData({
                path: abi.encodePacked(params.tokenOut, params.fee, params.tokenIn),
                payer: msg.sender
            }))
        );

        amountIn = uint256(zeroForOne ? amount0 : amount1);
        if (amountIn > params.amountInMaximum) revert ValenceRouter__SlippageExceeded();
    }

    /// @notice Callback called by ValencePool during swap execution.
    function valenceSwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external override {
        require(amount0Delta > 0 || amount1Delta > 0, "No input delta");
        SwapCallbackData memory decoded = abi.decode(data, (SwapCallbackData));

        (address tokenIn, uint24 poolFee, address tokenOut) = _decodeFirstPool(decoded.path);
        address expectedPool = IValencePoolFactory(factory).getPool(tokenIn, tokenOut, poolFee);
        if (msg.sender != expectedPool) revert ValenceRouter__UnauthorizedCallback();

        address tokenToPay = amount0Delta > 0 ? tokenIn : tokenOut;
        uint256 amountToPay = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);

        _pay(tokenToPay, decoded.payer, msg.sender, amountToPay);
    }

    function _decodeFirstPool(bytes memory path) private pure returns (address tokenA, uint24 poolFee, address tokenB) {
        assembly {
            tokenA := mload(add(path, 20))
            poolFee := mload(add(path, 23))
            tokenB := mload(add(path, 43))
        }
    }

    function _pay(address token, address payer, address recipient, uint256 value) private {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, payer, recipient, value)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            revert ValenceRouter__TransferFailed();
        }
    }
}
