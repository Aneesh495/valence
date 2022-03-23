#include "../include/orderbook.hpp"
#include "../include/portfolio_margin.hpp"
#include "../include/clamm_kernel.hpp"
#include <iostream>
#include <chrono>
#include <cassert>
#include <iomanip>

using namespace valence;

void testOrderBookCore() {
    std::cout << "[RUN] Testing C++ Limit Order Book mechanics..." << std::endl;
    LimitOrderBook book(1);

    // Place resting ask at $60,000 for 2 BTC
    Order makerSell{
        .orderId = 1,
        .subaccountId = 101,
        .marketId = 1,
        .side = OrderSide::SELL,
        .orderType = OrderType::LIMIT,
        .priceX96 = 60000ULL << 32,
        .originalQty = 2 * WAD,
        .filledQty = 0,
        .timestamp = 1000,
        .isActive = true
    };

    auto reports1 = book.submitOrder(makerSell);
    assert(reports1.empty());
    assert(book.getBestAskPrice() == (60000ULL << 32));
    assert(book.activeOrderCount() == 1);

    // Place crossing bid at $60,000 for 1 BTC
    Order takerBuy{
        .orderId = 2,
        .subaccountId = 102,
        .marketId = 1,
        .side = OrderSide::BUY,
        .orderType = OrderType::LIMIT,
        .priceX96 = 60000ULL << 32,
        .originalQty = 1 * WAD,
        .filledQty = 0,
        .timestamp = 1001,
        .isActive = true
    };

    auto reports2 = book.submitOrder(takerBuy);
    assert(reports2.size() == 1);
    assert(reports2[0].matchQty == 1 * WAD);
    assert(book.getBestAskPrice() == (60000ULL << 32)); // 1 BTC remains

    // Place post-only order that crosses: should reject without matching
    Order postOnlyCrossing{
        .orderId = 3,
        .subaccountId = 103,
        .marketId = 1,
        .side = OrderSide::BUY,
        .orderType = OrderType::POST_ONLY,
        .priceX96 = 60000ULL << 32,
        .originalQty = 1 * WAD,
        .filledQty = 0,
        .timestamp = 1002,
        .isActive = true
    };

    auto reports3 = book.submitOrder(postOnlyCrossing);
    assert(reports3.empty());

    // Cancel remaining maker sell
    bool cancelled = book.cancelOrder(1);
    assert(cancelled);
    assert(book.getBestAskPrice() == 0);
    assert(book.activeOrderCount() == 0);

    std::cout << "[PASS] C++ Limit Order Book mechanics verified!" << std::endl;
}

void testPortfolioMarginCore() {
    std::cout << "[RUN] Testing C++ Portfolio Margin SPAN engine..." << std::endl;
    PortfolioMarginEngine engine;

    // BTC-PERP: 10% IMR, 5% MMR, 50% Volatility
    engine.registerMarket(MarketRiskParameters{
        .marketId = 1,
        .baseImrBps = 1000,
        .baseMmrBps = 500,
        .annualVolatilityWad = static_cast<uint64_t>(0.50 * 1e18),
        .concentrationScaleBps = 100
    });

    // ETH-PERP: 10% IMR, 5% MMR, 60% Volatility
    engine.registerMarket(MarketRiskParameters{
        .marketId = 2,
        .baseImrBps = 1000,
        .baseMmrBps = 500,
        .annualVolatilityWad = static_cast<uint64_t>(0.60 * 1e18),
        .concentrationScaleBps = 100
    });

    // 85% correlation between BTC and ETH
    engine.setCorrelation(1, 2, static_cast<int64_t>(0.85 * 1e18));

    // Portfolio: Long 1 BTC ($60,000) and Short 20 ETH ($60,000)
    std::vector<PositionState> hedgedPortfolio = {
        PositionState{
            .marketId = 1,
            .size = static_cast<int64_t>(1 * WAD),
            .entryPriceX96 = 60000ULL << 32,
            .unrealizedPnlUsd = 0,
            .notionalUsd = 60000ULL * WAD
        },
        PositionState{
            .marketId = 2,
            .size = -static_cast<int64_t>(20 * WAD),
            .entryPriceX96 = 3000ULL << 32,
            .unrealizedPnlUsd = 0,
            .notionalUsd = 60000ULL * WAD
        }
    };

    AccountMarginProfile profile = engine.evaluateAccount(1, 20000ULL * WAD, hedgedPortfolio);

    // Gross MMR would be 60,000 * 5% + 60,000 * 5% = 6,000 USD
    // Correlation hedge reduces net MMR
    uint64_t grossMmr = 6000ULL * WAD;
    assert(profile.maintenanceMarginUsd < grossMmr);
    assert(profile.isSolvent);
    assert(!profile.isLiquidatable);

    std::cout << "[PASS] C++ Portfolio Margin SPAN engine verified (Gross MMR: $6,000 -> Hedged MMR: $"
              << (profile.maintenanceMarginUsd / WAD) << ")" << std::endl;
}

void benchmarkThroughput() {
    std::cout << "[BENCHMARK] Running 100,000 order matching latency benchmark..." << std::endl;
    LimitOrderBook book(1);

    constexpr size_t NUM_ORDERS = 100000;
    auto start = std::chrono::high_resolution_clock::now();

    // Alternate inserting bids and asks around mid price
    for (size_t i = 0; i < NUM_ORDERS; ++i) {
        OrderSide side = (i % 2 == 0) ? OrderSide::BUY : OrderSide::SELL;
        uint64_t price = ((i % 2 == 0) ? (59990 + (i % 10)) : (60010 + (i % 10))) << 32;

        Order order{
            .orderId = i + 1,
            .subaccountId = 100 + (i % 50),
            .marketId = 1,
            .side = side,
            .orderType = OrderType::LIMIT,
            .priceX96 = price,
            .originalQty = 1 * WAD,
            .filledQty = 0,
            .timestamp = static_cast<uint64_t>(i),
            .isActive = true
        };

        book.submitOrder(order);
    }

    auto end = std::chrono::high_resolution_clock::now();
    std::chrono::duration<double, std::milli> elapsed = end - start;

    double ordersPerSec = (NUM_ORDERS / elapsed.count()) * 1000.0;
    double latencyNs = (elapsed.count() * 1e6) / NUM_ORDERS;

    std::cout << std::fixed << std::setprecision(2);
    std::cout << "Executed " << NUM_ORDERS << " orders in " << elapsed.count() << " ms" << std::endl;
    std::cout << "Throughput: " << ordersPerSec << " orders/sec" << std::endl;
    std::cout << "Average Latency: " << latencyNs << " ns/order" << std::endl;
}

int main() {
    std::cout << "==================================================" << std::endl;
    std::cout << "  VALENCE C++20 CLEARING & MATCHING ENGINE TEST  " << std::endl;
    std::cout << "==================================================" << std::endl;

    testOrderBookCore();
    testPortfolioMarginCore();
    benchmarkThroughput();

    std::cout << "==================================================" << std::endl;
    std::cout << "  ALL C++ BENCHMARKS & VERIFICATIONS COMPLETED!   " << std::endl;
    std::cout << "==================================================" << std::endl;
    return 0;
}
