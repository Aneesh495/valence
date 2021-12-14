// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IValencePool} from "../interfaces/IValencePool.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {TickMath} from "../libraries/TickMath.sol";
import {TickBitmap} from "../libraries/TickBitmap.sol";
import {SqrtPriceMath} from "../libraries/SqrtPriceMath.sol";
import {SwapMath} from "../libraries/SwapMath.sol";
import {FullMath} from "../libraries/FullMath.sol";
import {SafeCast} from "../libraries/SafeCast.sol";

interface IValencePoolDeployer {
    function parameters()
        external
        view
        returns (
            address factory,
            address token0,
            address token1,
            uint24 fee,
            int24 tickSpacing
        );
}

interface IValenceMintCallback {
    function valenceMintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external;
}

interface IValenceSwapCallback {
    function valenceSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

interface IValenceFlashCallback {
    function valenceFlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external;
}

/// @title ValencePool
/// @notice Core concentrated liquidity automated market maker pool implementation.
/// @dev Implements tick bitmap navigation, 128-bit fee growth accumulation, and exact step swaps.
contract ValencePool is IValencePool {
    using SafeCast for uint256;
    using SafeCast for int256;
    using TickBitmap for mapping(int16 => uint256);

    address public immutable override factory;
    address public immutable override token0;
    address public immutable override token1;
    uint24 public immutable override fee;
    int24 public immutable override tickSpacing;
    uint128 public immutable override maxLiquidityPerTick;

    Slot0 public override slot0;
    uint128 public override liquidity;

    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;

    struct TickInfo {
        uint128 liquidityGross;
        int128 liquidityNet;
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
        bool initialized;
    }

    mapping(int24 => TickInfo) public ticks;
    mapping(int16 => uint256) public tickBitmap;
    mapping(bytes32 => PositionInfo) public positions;

    error ValencePool__Locked();
    error ValencePool__AlreadyInitialized();
    error ValencePool__InvalidPrice();
    error ValencePool__InvalidTicks();
    error ValencePool__LiquidityOverflow();
    error ValencePool__InsufficientInput();
    error ValencePool__PriceLimitExceeded();
    error ValencePool__TransferFailed();

    modifier lock() {
        if (!slot0.unlocked) revert ValencePool__Locked();
        slot0.unlocked = false;
        _;
        slot0.unlocked = true;
    }

    constructor() {
        (factory, token0, token1, fee, tickSpacing) = IValencePoolDeployer(msg.sender).parameters();
        maxLiquidityPerTick = type(uint128).max / 1000;
    }

    /// @notice Sets the initial sqrt price for the pool.
    function initialize(uint160 sqrtPriceX96) external {
        if (slot0.sqrtPriceX96 != 0) revert ValencePool__AlreadyInitialized();
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            observationIndex: 0,
            observationCardinality: 1,
            observationCardinalityNext: 1,
            feePips: fee,
            unlocked: true
        });
    }

    /// @notice Adds liquidity to a tick range.
    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        if (tickLower >= tickUpper || tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK) {
            revert ValencePool__InvalidTicks();
        }
        if (amount == 0) revert ValencePool__InsufficientInput();

        (amount0, amount1) = _modifyPosition(
            recipient,
            tickLower,
            tickUpper,
            int128(amount)
        );

        uint256 balance0Before = _balance0();
        uint256 balance1Before = _balance1();

        if (data.length > 0) {
            IValenceMintCallback(msg.sender).valenceMintCallback(amount0, amount1, data);
        }

        if (amount0 > 0 && _balance0() < balance0Before + amount0) revert ValencePool__InsufficientInput();
        if (amount1 > 0 && _balance1() < balance1Before + amount1) revert ValencePool__InsufficientInput();

        emit Mint(msg.sender, recipient, tickLower, tickUpper, amount, amount0, amount1);
    }

    /// @notice Removes liquidity from a tick range.
    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        if (tickLower >= tickUpper || tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK) {
            revert ValencePool__InvalidTicks();
        }
        if (amount == 0) revert ValencePool__InsufficientInput();

        (amount0, amount1) = _modifyPosition(
            msg.sender,
            tickLower,
            tickUpper,
            -int128(amount)
        );

        emit Burn(msg.sender, tickLower, tickUpper, amount, amount0, amount1);
    }

    /// @notice Collects accrued tokens owed to a position.
    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override lock returns (uint128 amount0, uint128 amount1) {
        bytes32 posKey = keccak256(abi.encodePacked(msg.sender, tickLower, tickUpper));
        PositionInfo storage position = positions[posKey];

        amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;

        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            _safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            _safeTransfer(token1, recipient, amount1);
        }

        emit Collect(msg.sender, recipient, tickLower, tickUpper, amount0, amount1);
    }

    /// @notice Executes a concentrated liquidity swap.
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external override lock returns (int256 amount0, int256 amount1) {
        if (amountSpecified == 0) revert ValencePool__InsufficientInput();

        Slot0 memory state = slot0;
        if (
            zeroForOne
                ? sqrtPriceLimitX96 >= state.sqrtPriceX96 || sqrtPriceLimitX96 <= TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 <= state.sqrtPriceX96 || sqrtPriceLimitX96 >= TickMath.MAX_SQRT_RATIO
        ) {
            revert ValencePool__PriceLimitExceeded();
        }

        uint128 currentLiquidity = liquidity;
        int256 amountSpecifiedRemaining = amountSpecified;
        int256 amountCalculated = 0;

        while (amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            (int24 nextTick, bool initialized) = tickBitmap.nextInitializedTickWithinOneWord(
                state.tick,
                tickSpacing,
                zeroForOne
            );

            uint160 sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(nextTick);

            uint160 targetPriceX96 = (zeroForOne ? sqrtPriceNextX96 < sqrtPriceLimitX96 : sqrtPriceNextX96 > sqrtPriceLimitX96)
                ? sqrtPriceLimitX96
                : sqrtPriceNextX96;

            (
                uint160 stepNextPriceX96,
                uint256 stepAmountIn,
                uint256 stepAmountOut,
                uint256 stepFeeAmount
            ) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                targetPriceX96,
                currentLiquidity,
                amountSpecifiedRemaining,
                state.feePips
            );

            if (amountSpecified > 0) {
                amountSpecifiedRemaining -= int256(stepAmountIn + stepFeeAmount);
                amountCalculated -= int256(stepAmountOut);
            } else {
                amountSpecifiedRemaining += int256(stepAmountOut);
                amountCalculated += int256(stepAmountIn + stepFeeAmount);
            }

            // Update fee growth global
            if (currentLiquidity > 0) {
                uint256 feeDelta = FullMath.mulDiv(stepFeeAmount, 1 << 128, currentLiquidity);
                if (zeroForOne) {
                    feeGrowthGlobal0X128 += feeDelta;
                } else {
                    feeGrowthGlobal1X128 += feeDelta;
                }
            }

            state.sqrtPriceX96 = stepNextPriceX96;

            // Shift ticks if boundary crossed
            if (state.sqrtPriceX96 == sqrtPriceNextX96) {
                if (initialized) {
                    int128 net = ticks[nextTick].liquidityNet;
                    if (zeroForOne) net = -net;
                    currentLiquidity = net < 0
                        ? currentLiquidity - uint128(-net)
                        : currentLiquidity + uint128(net);
                }
                state.tick = zeroForOne ? nextTick - 1 : nextTick;
            } else if (state.sqrtPriceX96 != targetPriceX96) {
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        slot0.sqrtPriceX96 = state.sqrtPriceX96;
        slot0.tick = state.tick;
        liquidity = currentLiquidity;

        (amount0, amount1) = zeroForOne == (amountSpecified > 0)
            ? (amountSpecified - amountSpecifiedRemaining, amountCalculated)
            : (amountCalculated, amountSpecified - amountSpecifiedRemaining);

        // Perform transfers and callbacks
        if (zeroForOne) {
            if (amount1 < 0) _safeTransfer(token1, recipient, uint256(-amount1));
            uint256 balance0Before = _balance0();
            if (data.length > 0) IValenceSwapCallback(msg.sender).valenceSwapCallback(amount0, amount1, data);
            if (_balance0() < balance0Before + uint256(amount0)) revert ValencePool__InsufficientInput();
        } else {
            if (amount0 < 0) _safeTransfer(token0, recipient, uint256(-amount0));
            uint256 balance1Before = _balance1();
            if (data.length > 0) IValenceSwapCallback(msg.sender).valenceSwapCallback(amount0, amount1, data);
            if (_balance1() < balance1Before + uint256(amount1)) revert ValencePool__InsufficientInput();
        }

        emit Swap(msg.sender, recipient, amount0, amount1, state.sqrtPriceX96, currentLiquidity, state.tick);
    }

    /// @notice Flash borrow token0 and/or token1.
    function flash(
        address recipient,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external override lock {
        uint256 fee0 = FullMath.mulDivRoundingUp(amount0, fee, 1e6);
        uint256 fee1 = FullMath.mulDivRoundingUp(amount1, fee, 1e6);

        uint256 balance0Before = _balance0();
        uint256 balance1Before = _balance1();

        if (amount0 > 0) _safeTransfer(token0, recipient, amount0);
        if (amount1 > 0) _safeTransfer(token1, recipient, amount1);

        IValenceFlashCallback(msg.sender).valenceFlashCallback(fee0, fee1, data);

        if (_balance0() < balance0Before + fee0) revert ValencePool__InsufficientInput();
        if (_balance1() < balance1Before + fee1) revert ValencePool__InsufficientInput();

        emit Flash(msg.sender, recipient, amount0, amount1, fee0, fee1);
    }

    // --- Internal Helpers ---

    function _modifyPosition(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    ) private returns (uint256 amount0, uint256 amount1) {
        bytes32 posKey = keccak256(abi.encodePacked(owner, tickLower, tickUpper));
        PositionInfo storage position = positions[posKey];

        Slot0 memory _slot0 = slot0;

        _updateTick(tickLower, _slot0.tick, liquidityDelta, false);
        _updateTick(tickUpper, _slot0.tick, liquidityDelta, true);

        if (_slot0.tick < tickLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(
                TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper),
                uint128(liquidityDelta > 0 ? liquidityDelta : -liquidityDelta),
                liquidityDelta > 0
            );
        } else if (_slot0.tick < tickUpper) {
            amount0 = SqrtPriceMath.getAmount0Delta(
                _slot0.sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(tickUpper),
                uint128(liquidityDelta > 0 ? liquidityDelta : -liquidityDelta),
                liquidityDelta > 0
            );
            amount1 = SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtRatioAtTick(tickLower),
                _slot0.sqrtPriceX96,
                uint128(liquidityDelta > 0 ? liquidityDelta : -liquidityDelta),
                liquidityDelta > 0
            );
            liquidity = liquidityDelta > 0
                ? liquidity + uint128(liquidityDelta)
                : liquidity - uint128(-liquidityDelta);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper),
                uint128(liquidityDelta > 0 ? liquidityDelta : -liquidityDelta),
                liquidityDelta > 0
            );
        }

        position.liquidity = liquidityDelta > 0
            ? position.liquidity + uint128(liquidityDelta)
            : position.liquidity - uint128(-liquidityDelta);
    }

    function _updateTick(
        int24 tick,
        int24 currentTick,
        int128 liquidityDelta,
        bool isUpper
    ) private {
        TickInfo storage info = ticks[tick];
        uint128 liquidityGrossBefore = info.liquidityGross;
        uint128 liquidityGrossAfter = liquidityDelta > 0
            ? liquidityGrossBefore + uint128(liquidityDelta)
            : liquidityGrossBefore - uint128(-liquidityDelta);

        if (liquidityGrossBefore == 0) {
            info.initialized = true;
            tickBitmap.flipTick(tick, tickSpacing);
            if (tick <= currentTick) {
                info.feeGrowthOutside0X128 = feeGrowthGlobal0X128;
                info.feeGrowthOutside1X128 = feeGrowthGlobal1X128;
            }
        }

        info.liquidityGross = liquidityGrossAfter;
        info.liquidityNet = isUpper
            ? info.liquidityNet - liquidityDelta
            : info.liquidityNet + liquidityDelta;

        if (liquidityGrossAfter == 0) {
            info.initialized = false;
            tickBitmap.flipTick(tick, tickSpacing);
        }
    }

    function _balance0() private view returns (uint256) {
        (bool success, bytes memory data) = token0.staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(this))
        );
        return success && data.length >= 32 ? abi.decode(data, (uint256)) : 0;
    }

    function _balance1() private view returns (uint256) {
        (bool success, bytes memory data) = token1.staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(this))
        );
        return success && data.length >= 32 ? abi.decode(data, (uint256)) : 0;
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            revert ValencePool__TransferFailed();
        }
    }
}
