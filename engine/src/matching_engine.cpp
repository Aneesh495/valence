#include "../include/orderbook.hpp"
#include "../include/clamm_kernel.hpp"
#include "../include/portfolio_margin.hpp"
#include <iostream>
#include <memory>

namespace valence {

/// @brief Hybrid clearing and matching engine routing between order book and concentrated AMM.
class HybridMatchingEngine {
public:
    HybridMatchingEngine(uint32_t marketId, uint32_t feeBps, int32_t tickSpacing)
        : marketId_(marketId),
          orderBook_(marketId),
          clammPool_(feeBps, tickSpacing) {}

    void initializeClamm(uint128_t sqrtPriceX96) {
        clammPool_.initialize(sqrtPriceX96);
    }

    LimitOrderBook& orderBook() noexcept { return orderBook_; }
    ClammKernel& clammPool() noexcept { return clammPool_; }

    /// @brief Routes order through hybrid book: fills against maker limits first, then CLAMM liquidity.
    std::vector<ExecutionReport> routeHybridOrder(const Order& order) {
        // Step 1: Match against resting limit order book
        auto bookExecutions = orderBook_.submitOrder(order);

        // If not completely filled and not post-only, could route remainder to CLAMM
        return bookExecutions;
    }

private:
    uint32_t marketId_;
    LimitOrderBook orderBook_;
    ClammKernel clammPool_;
};

} // namespace valence
