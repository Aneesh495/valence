#pragma once

#include "types.hpp"
#include <map>
#include <deque>
#include <unordered_map>
#include <span>
#include <optional>

namespace valence {

/// @brief High-performance L3 Limit Order Book implementing Price-Time Priority matching.
/// Uses red-black tree (std::map) for price levels and FIFO deques for resting queues.
class LimitOrderBook {
public:
    explicit LimitOrderBook(uint32_t marketId);

    /// @brief Inserts an incoming order, crosses against resting liquidity, and rests unfulfilled remainder.
    std::vector<ExecutionReport> submitOrder(const Order& order);

    /// @brief Cancels an active resting order by ID.
    bool cancelOrder(uint64_t orderId);

    /// @brief Gets best bid price in Q64.96 format, or 0 if empty.
    [[nodiscard]] uint64_t getBestBidPrice() const noexcept;

    /// @brief Gets best ask price in Q64.96 format, or 0 if empty.
    [[nodiscard]] uint64_t getBestAskPrice() const noexcept;

    /// @brief Looks up an order by order ID.
    [[nodiscard]] std::optional<Order> getOrder(uint64_t orderId) const;

    /// @brief Total count of active resting orders in the book.
    [[nodiscard]] size_t activeOrderCount() const noexcept;

private:
    uint32_t marketId_;
    
    // Bids sorted descending (highest price first)
    std::map<uint64_t, std::deque<Order>, std::greater<uint64_t>> bids_;
    
    // Asks sorted ascending (lowest price first)
    std::map<uint64_t, std::deque<Order>, std::less<uint64_t>> asks_;

    // Fast lookup table: orderId -> Order
    std::unordered_map<uint64_t, Order> orderRegistry_;

    std::vector<ExecutionReport> matchBuyOrder(Order takerOrder);
    std::vector<ExecutionReport> matchSellOrder(Order takerOrder);
};

} // namespace valence
