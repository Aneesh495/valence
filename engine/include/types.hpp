#pragma once

#include <cstdint>
#include <string>
#include <vector>
#include <array>
#include <chrono>

namespace valence {

// Fixed-point scale constants
constexpr uint64_t WAD = 1000000000000000000ULL; // 1e18
constexpr uint64_t BPS_SCALE = 10000;

using int128_t = __int128_t;
using uint128_t = __uint128_t;

enum class OrderSide : uint8_t {
    BUY = 0,
    SELL = 1
};

enum class OrderType : uint8_t {
    LIMIT = 0,
    POST_ONLY = 1,
    IMMEDIATE_OR_CANCEL = 2,
    FILL_OR_KILL = 3
};

struct Order {
    uint64_t orderId;
    uint64_t subaccountId;
    uint32_t marketId;
    OrderSide side;
    OrderType orderType;
    uint64_t priceX96;      // Q64.96 fixed-point price
    uint64_t originalQty;   // In WAD (1e18)
    uint64_t filledQty;     // In WAD (1e18)
    uint64_t timestamp;
    bool isActive;

    [[nodiscard]] uint64_t remainingQty() const noexcept {
        return originalQty - filledQty;
    }
};

struct ExecutionReport {
    uint64_t takerOrderId;
    uint64_t makerOrderId;
    uint64_t matchPriceX96;
    uint64_t matchQty;
    uint64_t feeChargedUsd;
    uint64_t timestamp;
};

struct MarketRiskParameters {
    uint32_t marketId;
    uint32_t baseImrBps;
    uint32_t baseMmrBps;
    uint64_t annualVolatilityWad;
    uint32_t concentrationScaleBps;
};

struct PositionState {
    uint32_t marketId;
    int64_t size;            // Positive for long, negative for short (in WAD)
    uint64_t entryPriceX96;
    int64_t unrealizedPnlUsd;
    uint64_t notionalUsd;
};

struct AccountMarginProfile {
    uint64_t subaccountId;
    uint64_t totalCollateralUsd;
    uint64_t haircutCollateralUsd;
    int64_t totalUnrealizedPnlUsd;
    uint64_t initialMarginRequiredUsd;
    uint64_t maintenanceMarginUsd;
    uint64_t healthFactorWad;
    bool isSolvent;
    bool isLiquidatable;
};

} // namespace valence
