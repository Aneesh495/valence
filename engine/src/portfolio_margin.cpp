#include "../include/portfolio_margin.hpp"
#include <cmath>
#include <algorithm>

namespace valence {

void PortfolioMarginEngine::registerMarket(const MarketRiskParameters& params) {
    marketParams_[params.marketId] = params;
}

void PortfolioMarginEngine::setCorrelation(uint32_t marketA, uint32_t marketB, int64_t correlationWad) {
    uint64_t key = makeCorrelationKey(marketA, marketB);
    correlations_[key] = correlationWad;
}

uint64_t PortfolioMarginEngine::makeCorrelationKey(uint32_t a, uint32_t b) noexcept {
    uint32_t minId = std::min(a, b);
    uint32_t maxId = std::max(a, b);
    return (static_cast<uint64_t>(minId) << 32) | static_cast<uint64_t>(maxId);
}

int64_t PortfolioMarginEngine::getCorrelation(uint32_t a, uint32_t b) const noexcept {
    if (a == b) return static_cast<int64_t>(WAD); // Self-correlation is 1.0
    uint64_t key = makeCorrelationKey(a, b);
    auto it = correlations_.find(key);
    if (it != correlations_.end()) {
        return it->second;
    }
    return 0; // Uncorrelated default
}

double PortfolioMarginEngine::computePortfolioVariance(const std::vector<PositionState>& positions) const {
    size_t n = positions.size();
    if (n == 0) return 0.0;

    double variance = 0.0;
    for (size_t i = 0; i < n; ++i) {
        auto itI = marketParams_.find(positions[i].marketId);
        double volI = (itI != marketParams_.end()) ? static_cast<double>(itI->second.annualVolatilityWad) / 1e18 : 0.50;
        double notionalI = (positions[i].size >= 0) ? static_cast<double>(positions[i].notionalUsd) : -static_cast<double>(positions[i].notionalUsd);

        for (size_t j = 0; j < n; ++j) {
            auto itJ = marketParams_.find(positions[j].marketId);
            double volJ = (itJ != marketParams_.end()) ? static_cast<double>(itJ->second.annualVolatilityWad) / 1e18 : 0.50;
            double notionalJ = (positions[j].size >= 0) ? static_cast<double>(positions[j].notionalUsd) : -static_cast<double>(positions[j].notionalUsd);

            double rho = static_cast<double>(getCorrelation(positions[i].marketId, positions[j].marketId)) / 1e18;
            double cov = rho * volI * volJ;

            variance += notionalI * cov * notionalJ;
        }
    }

    return std::max(0.0, variance);
}

AccountMarginProfile PortfolioMarginEngine::evaluateAccount(
    uint64_t subaccountId,
    uint64_t collateralUsd,
    const std::vector<PositionState>& positions
) const {
    AccountMarginProfile profile{
        .subaccountId = subaccountId,
        .totalCollateralUsd = collateralUsd,
        .haircutCollateralUsd = collateralUsd,
        .totalUnrealizedPnlUsd = 0,
        .initialMarginRequiredUsd = 0,
        .maintenanceMarginUsd = 0,
        .healthFactorWad = 0,
        .isSolvent = true,
        .isLiquidatable = false
    };

    if (positions.empty()) {
        profile.healthFactorWad = UINT64_MAX;
        return profile;
    }

    uint64_t grossImr = 0;
    uint64_t grossMmr = 0;
    int64_t totalPnL = 0;
    double grossVolNotional = 0.0;

    for (const auto& pos : positions) {
        totalPnL += pos.unrealizedPnlUsd;

        auto it = marketParams_.find(pos.marketId);
        uint32_t imrBps = (it != marketParams_.end()) ? it->second.baseImrBps : 1000;
        uint32_t mmrBps = (it != marketParams_.end()) ? it->second.baseMmrBps : 500;
        double vol = (it != marketParams_.end()) ? static_cast<double>(it->second.annualVolatilityWad) / 1e18 : 0.50;

        uint64_t posImr = (pos.notionalUsd * imrBps) / BPS_SCALE;
        uint64_t posMmr = (pos.notionalUsd * mmrBps) / BPS_SCALE;

        grossImr += posImr;
        grossMmr += posMmr;
        grossVolNotional += static_cast<double>(pos.notionalUsd) * vol;
    }

    profile.totalUnrealizedPnlUsd = totalPnL;

    double portfolioVariance = computePortfolioVariance(positions);
    double netCovarianceRisk = std::sqrt(portfolioVariance);

    double riskFactor = 1.0;
    if (grossVolNotional > 0.0) {
        riskFactor = std::min(1.0, netCovarianceRisk / grossVolNotional);
    }

    // Floor at 40% of gross MMR and 50% of gross IMR
    uint64_t floorMmr = (grossMmr * 4000) / BPS_SCALE;
    uint64_t netMmr = static_cast<uint64_t>(grossMmr * riskFactor);
    profile.maintenanceMarginUsd = std::max(netMmr, floorMmr);

    uint64_t floorImr = (grossImr * 5000) / BPS_SCALE;
    uint64_t netImr = static_cast<uint64_t>(grossImr * riskFactor);
    profile.initialMarginRequiredUsd = std::max(netImr, floorImr);

    int64_t netEquity = static_cast<int64_t>(profile.haircutCollateralUsd) + totalPnL;
    if (netEquity <= 0) {
        profile.healthFactorWad = 0;
        profile.isSolvent = false;
        profile.isLiquidatable = true;
    } else if (profile.maintenanceMarginUsd == 0) {
        profile.healthFactorWad = UINT64_MAX;
        profile.isSolvent = true;
        profile.isLiquidatable = false;
    } else {
        uint128_t scaled = (static_cast<uint128_t>(netEquity) * WAD) / profile.maintenanceMarginUsd;
        profile.healthFactorWad = (scaled > UINT64_MAX) ? UINT64_MAX : static_cast<uint64_t>(scaled);
        profile.isSolvent = profile.healthFactorWad >= WAD;
        profile.isLiquidatable = profile.healthFactorWad < WAD;
    }

    return profile;
}

} // namespace valence
