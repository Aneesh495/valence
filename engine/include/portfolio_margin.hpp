#pragma once

#include "types.hpp"
#include <vector>
#include <unordered_map>
#include <cmath>

namespace valence {

/// @brief Institutional SPAN-style portfolio margin engine replicating ValencePortfolioMargin.sol.
/// Computes quadratic covariance forms w^T * Sigma * w, correlation offsets, and liquidation solvency.
class PortfolioMarginEngine {
public:
    PortfolioMarginEngine() = default;

    /// @brief Registers risk parameters for a market.
    void registerMarket(const MarketRiskParameters& params);

    /// @brief Sets pairwise correlation between two markets (-1.0 to +1.0 represented in WAD).
    void setCorrelation(uint32_t marketA, uint32_t marketB, int64_t correlationWad);

    /// @brief Evaluates cross-asset portfolio margin requirement and solvency for an account.
    [[nodiscard]] AccountMarginProfile evaluateAccount(
        uint64_t subaccountId,
        uint64_t collateralUsd,
        const std::vector<PositionState>& positions
    ) const;

    /// @brief Calculates quadratic risk form w^T * Sigma * w across notional vector w.
    [[nodiscard]] double computePortfolioVariance(
        const std::vector<PositionState>& positions
    ) const;

private:
    std::unordered_map<uint32_t, MarketRiskParameters> marketParams_;
    // Hash key: (min(A, B) << 32) | max(A, B)
    std::unordered_map<uint64_t, int64_t> correlations_;

    [[nodiscard]] int64_t getCorrelation(uint32_t a, uint32_t b) const noexcept;
    static uint64_t makeCorrelationKey(uint32_t a, uint32_t b) noexcept;
};

} // namespace valence
