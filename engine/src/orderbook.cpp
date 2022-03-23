#include "../include/orderbook.hpp"
#include <algorithm>

namespace valence {

LimitOrderBook::LimitOrderBook(uint32_t marketId)
    : marketId_(marketId) {}

std::vector<ExecutionReport> LimitOrderBook::submitOrder(const Order& incomingOrder) {
    std::vector<ExecutionReport> reports;
    if (incomingOrder.originalQty == 0 || incomingOrder.priceX96 == 0) {
        return reports;
    }

    if (incomingOrder.side == OrderSide::BUY) {
        reports = matchBuyOrder(incomingOrder);
    } else {
        reports = matchSellOrder(incomingOrder);
    }

    return reports;
}

std::vector<ExecutionReport> LimitOrderBook::matchBuyOrder(Order takerOrder) {
    std::vector<ExecutionReport> executions;

    // Best ask check for POST_ONLY
    if (!asks_.empty()) {
        auto bestAskPrice = asks_.begin()->first;
        if (takerOrder.priceX96 >= bestAskPrice && takerOrder.orderType == OrderType::POST_ONLY) {
            // Post-only would cross; cancel/reject order
            return executions;
        }
    }

    // Matching loop
    while (!asks_.empty() && takerOrder.remainingQty() > 0) {
        auto askIt = asks_.begin();
        uint64_t bestAskPrice = askIt->first;

        if (takerOrder.priceX96 < bestAskPrice) {
            break; // No further match possible
        }

        auto& queue = askIt->second;
        while (!queue.empty() && takerOrder.remainingQty() > 0) {
            Order& makerOrder = queue.front();
            uint64_t matchQty = std::min(takerOrder.remainingQty(), makerOrder.remainingQty());

            takerOrder.filledQty += matchQty;
            makerOrder.filledQty += matchQty;

            executions.push_back(ExecutionReport{
                .takerOrderId = takerOrder.orderId,
                .makerOrderId = makerOrder.orderId,
                .matchPriceX96 = bestAskPrice,
                .matchQty = matchQty,
                .feeChargedUsd = (matchQty * 10) / BPS_SCALE,
                .timestamp = takerOrder.timestamp
            });

            if (makerOrder.remainingQty() == 0) {
                makerOrder.isActive = false;
                orderRegistry_.erase(makerOrder.orderId);
                queue.pop_front();
            }
        }

        if (queue.empty()) {
            asks_.erase(askIt);
        }
    }

    // Resting phase
    bool shouldRest = takerOrder.remainingQty() > 0 && 
                      takerOrder.orderType != OrderType::IMMEDIATE_OR_CANCEL &&
                      takerOrder.orderType != OrderType::FILL_OR_KILL;

    if (shouldRest) {
        takerOrder.isActive = true;
        orderRegistry_[takerOrder.orderId] = takerOrder;
        bids_[takerOrder.priceX96].push_back(takerOrder);
    }

    return executions;
}

std::vector<ExecutionReport> LimitOrderBook::matchSellOrder(Order takerOrder) {
    std::vector<ExecutionReport> executions;

    // Best bid check for POST_ONLY
    if (!bids_.empty()) {
        auto bestBidPrice = bids_.begin()->first;
        if (takerOrder.priceX96 <= bestBidPrice && takerOrder.orderType == OrderType::POST_ONLY) {
            return executions;
        }
    }

    // Matching loop
    while (!bids_.empty() && takerOrder.remainingQty() > 0) {
        auto bidIt = bids_.begin();
        uint64_t bestBidPrice = bidIt->first;

        if (takerOrder.priceX96 > bestBidPrice) {
            break;
        }

        auto& queue = bidIt->second;
        while (!queue.empty() && takerOrder.remainingQty() > 0) {
            Order& makerOrder = queue.front();
            uint64_t matchQty = std::min(takerOrder.remainingQty(), makerOrder.remainingQty());

            takerOrder.filledQty += matchQty;
            makerOrder.filledQty += matchQty;

            executions.push_back(ExecutionReport{
                .takerOrderId = takerOrder.orderId,
                .makerOrderId = makerOrder.orderId,
                .matchPriceX96 = bestBidPrice,
                .matchQty = matchQty,
                .feeChargedUsd = (matchQty * 10) / BPS_SCALE,
                .timestamp = takerOrder.timestamp
            });

            if (makerOrder.remainingQty() == 0) {
                makerOrder.isActive = false;
                orderRegistry_.erase(makerOrder.orderId);
                queue.pop_front();
            }
        }

        if (queue.empty()) {
            bids_.erase(bidIt);
        }
    }

    // Resting phase
    bool shouldRest = takerOrder.remainingQty() > 0 &&
                      takerOrder.orderType != OrderType::IMMEDIATE_OR_CANCEL &&
                      takerOrder.orderType != OrderType::FILL_OR_KILL;

    if (shouldRest) {
        takerOrder.isActive = true;
        orderRegistry_[takerOrder.orderId] = takerOrder;
        asks_[takerOrder.priceX96].push_back(takerOrder);
    }

    return executions;
}

bool LimitOrderBook::cancelOrder(uint64_t orderId) {
    auto it = orderRegistry_.find(orderId);
    if (it == orderRegistry_.end()) {
        return false;
    }

    const Order& order = it->second;
    uint64_t price = order.priceX96;

    if (order.side == OrderSide::BUY) {
        auto bidIt = bids_.find(price);
        if (bidIt != bids_.end()) {
            auto& queue = bidIt->second;
            queue.erase(std::remove_if(queue.begin(), queue.end(),
                [orderId](const Order& o) { return o.orderId == orderId; }), queue.end());
            if (queue.empty()) {
                bids_.erase(bidIt);
            }
        }
    } else {
        auto askIt = asks_.find(price);
        if (askIt != asks_.end()) {
            auto& queue = askIt->second;
            queue.erase(std::remove_if(queue.begin(), queue.end(),
                [orderId](const Order& o) { return o.orderId == orderId; }), queue.end());
            if (queue.empty()) {
                asks_.erase(askIt);
            }
        }
    }

    orderRegistry_.erase(it);
    return true;
}

uint64_t LimitOrderBook::getBestBidPrice() const noexcept {
    if (bids_.empty()) return 0;
    return bids_.begin()->first;
}

uint64_t LimitOrderBook::getBestAskPrice() const noexcept {
    if (asks_.empty()) return 0;
    return asks_.begin()->first;
}

std::optional<Order> LimitOrderBook::getOrder(uint64_t orderId) const {
    auto it = orderRegistry_.find(orderId);
    if (it != orderRegistry_.end()) {
        return it->second;
    }
    return std::nullopt;
}

size_t LimitOrderBook::activeOrderCount() const noexcept {
    return orderRegistry_.size();
}

} // namespace valence
