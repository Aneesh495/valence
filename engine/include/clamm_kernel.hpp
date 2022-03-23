#pragma once

#include "types.hpp"
#include <cstdint>
#include <map>
#include <vector>

namespace valence {

struct TickInfo {
    int32_t tickIndex;
    int128_t liquidityNet;
    uint128_t liquidityGross;
    uint128_t feeGrowthOutside0X128;
    uint128_t feeGrowthOutside1X128;
    bool initialized;
};

/// @brief Concentrated Liquidity Automated Market Maker kernel in C++.
/// Replicates ValencePool.sol tick math, liquidity transitions, and step swap math.
class ClammKernel {
public:
    ClammKernel(uint32_t feeBps, int32_t tickSpacing);

    /// @brief Initializes pool at initial sqrtPriceX96.
    void initialize(uint128_t sqrtPriceX96);

    /// @brief Modifies liquidity within a tick range [tickLower, tickUpper].
    void modifyPosition(int32_t tickLower, int32_t tickUpper, int128_t liquidityDelta);

    /// @brief Executes a swap along the concentrated liquidity curve.
    /// @param zeroForOne True if swapping token0 for token1, false otherwise.
    /// @param amountSpecified Exact input or exact output amount.
    /// @param sqrtPriceLimitX96 Bound limit for slippage protection.
    /// @return {amount0Delta, amount1Delta, endSqrtPriceX96}
    std::tuple<int128_t, int128_t, uint128_t> swap(
        bool zeroForOne,
        int128_t amountSpecified,
        uint128_t sqrtPriceLimitX96
    );

    [[nodiscard]] uint128_t currentSqrtPriceX96() const noexcept { return currentSqrtPriceX96_; }
    [[nodiscard]] int32_t currentTick() const noexcept { return currentTick_; }
    [[nodiscard]] uint128_t activeLiquidity() const noexcept { return activeLiquidity_; }

    /// @brief Computes sqrt(1.0001^tick) * 2^96 using binary decomposition.
    [[nodiscard]] static uint128_t getSqrtRatioAtTick(int32_t tick);

    /// @brief Computes floor(log_1.0001(sqrtPriceX96 / 2^96)).
    [[nodiscard]] static int32_t getTickAtSqrtRatio(uint128_t sqrtPriceX96);

private:
    uint32_t feeBps_;
    int32_t tickSpacing_;
    uint128_t currentSqrtPriceX96_{0};
    int32_t currentTick_{0};
    uint128_t activeLiquidity_{0};

    std::map<int32_t, int128_t> tickLiquidityNet_;
};

} // namespace valence
