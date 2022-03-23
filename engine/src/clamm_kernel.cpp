#include "../include/clamm_kernel.hpp"
#include <cmath>
#include <stdexcept>

namespace valence {

ClammKernel::ClammKernel(uint32_t feeBps, int32_t tickSpacing)
    : feeBps_(feeBps), tickSpacing_(tickSpacing) {}

void ClammKernel::initialize(uint128_t sqrtPriceX96) {
    if (sqrtPriceX96 == 0) {
        throw std::invalid_argument("Invalid sqrtPriceX96");
    }
    currentSqrtPriceX96_ = sqrtPriceX96;
    currentTick_ = getTickAtSqrtRatio(sqrtPriceX96);
}

void ClammKernel::modifyPosition(int32_t tickLower, int32_t tickUpper, int128_t liquidityDelta) {
    if (tickLower >= tickUpper) {
        throw std::invalid_argument("tickLower must be less than tickUpper");
    }

    tickLiquidityNet_[tickLower] += liquidityDelta;
    tickLiquidityNet_[tickUpper] -= liquidityDelta;

    // If current price is within range, update active liquidity
    if (currentTick_ >= tickLower && currentTick_ < tickUpper) {
        if (liquidityDelta >= 0) {
            activeLiquidity_ += static_cast<uint128_t>(liquidityDelta);
        } else {
            activeLiquidity_ -= static_cast<uint128_t>(-liquidityDelta);
        }
    }
}

std::tuple<int128_t, int128_t, uint128_t> ClammKernel::swap(
    bool zeroForOne,
    int128_t amountSpecified,
    uint128_t sqrtPriceLimitX96
) {
    int128_t amount0 = 0;
    int128_t amount1 = 0;
    uint128_t sqrtPriceX96 = currentSqrtPriceX96_;

    // Swap simulation stepping
    if (zeroForOne) {
        // Price decreases
        if (sqrtPriceLimitX96 >= sqrtPriceX96) {
            throw std::invalid_argument("sqrtPriceLimit must be less than current price");
        }
        // Approximate single-step execution
        amount0 = amountSpecified;
        double priceRatio = static_cast<double>(sqrtPriceX96) / (1ULL << 48);
        amount1 = -static_cast<int128_t>(static_cast<double>(amountSpecified) * priceRatio * 0.997);
        currentSqrtPriceX96_ = static_cast<uint128_t>(static_cast<double>(sqrtPriceX96) * 0.9995);
    } else {
        // Price increases
        if (sqrtPriceLimitX96 <= sqrtPriceX96) {
            throw std::invalid_argument("sqrtPriceLimit must be greater than current price");
        }
        amount1 = amountSpecified;
        double priceRatio = (1ULL << 48) / static_cast<double>(sqrtPriceX96);
        amount0 = -static_cast<int128_t>(static_cast<double>(amountSpecified) * priceRatio * 0.997);
        currentSqrtPriceX96_ = static_cast<uint128_t>(static_cast<double>(sqrtPriceX96) * 1.0005);
    }

    currentTick_ = getTickAtSqrtRatio(currentSqrtPriceX96_);
    return {amount0, amount1, currentSqrtPriceX96_};
}

uint128_t ClammKernel::getSqrtRatioAtTick(int32_t tick) {
    double factor = std::pow(1.0001, static_cast<double>(tick) / 2.0);
    double scaled = factor * std::pow(2.0, 96.0);
    return static_cast<uint128_t>(scaled);
}

int32_t ClammKernel::getTickAtSqrtRatio(uint128_t sqrtPriceX96) {
    double ratio = static_cast<double>(sqrtPriceX96) / std::pow(2.0, 96.0);
    double logVal = std::log(ratio * ratio) / std::log(1.0001);
    return static_cast<int32_t>(std::floor(logVal));
}

} // namespace valence
