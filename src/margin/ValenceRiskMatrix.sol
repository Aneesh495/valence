// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title ValenceRiskMatrix
/// @notice Stores risk parameters, tiered margin factors, and correlation coefficients for portfolio margin.
contract ValenceRiskMatrix {
    address public immutable owner;

    struct MarketRiskConfig {
        bool isConfigured;
        uint32 baseInitialMarginBps;      // e.g. 500 = 5.0% (20x leverage)
        uint32 baseMaintenanceMarginBps;  // e.g. 250 = 2.5% (40x leverage)
        uint32 concentrationScaleFactor;  // Multiplier for size concentration penalty
        uint256 volatilityWad;            // Annualized volatility in WAD
        uint32 liquidationFeeBps;         // Reward for liquidator in BPS
    }

    mapping(bytes32 => MarketRiskConfig) private _marketConfigs;
    bytes32[] private _configuredMarkets;

    // marketA => marketB => correlation [-1e18..1e18]
    mapping(bytes32 => mapping(bytes32 => int256)) private _correlations;

    event MarketRiskConfigured(
        bytes32 indexed marketId,
        uint32 baseInitialMarginBps,
        uint32 baseMaintenanceMarginBps,
        uint256 volatilityWad
    );

    event CorrelationConfigured(
        bytes32 indexed marketA,
        bytes32 indexed marketB,
        int256 correlationWad
    );

    error ValenceRiskMatrix__Unauthorized();
    error ValenceRiskMatrix__InvalidBps();
    error ValenceRiskMatrix__CorrelationOutOfBounds();

    modifier onlyOwner() {
        if (msg.sender != owner) revert ValenceRiskMatrix__Unauthorized();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function configureMarket(
        bytes32 marketId,
        uint32 baseInitialMarginBps,
        uint32 baseMaintenanceMarginBps,
        uint32 concentrationScaleFactor,
        uint256 volatilityWad,
        uint32 liquidationFeeBps
    ) external onlyOwner {
        if (baseInitialMarginBps < baseMaintenanceMarginBps) revert ValenceRiskMatrix__InvalidBps();
        if (baseInitialMarginBps > 10000) revert ValenceRiskMatrix__InvalidBps();

        if (!_marketConfigs[marketId].isConfigured) {
            _configuredMarkets.push(marketId);
        }

        _marketConfigs[marketId] = MarketRiskConfig({
            isConfigured: true,
            baseInitialMarginBps: baseInitialMarginBps,
            baseMaintenanceMarginBps: baseMaintenanceMarginBps,
            concentrationScaleFactor: concentrationScaleFactor,
            volatilityWad: volatilityWad,
            liquidationFeeBps: liquidationFeeBps
        });

        // Default self-correlation is 1.0 (1e18)
        _correlations[marketId][marketId] = 1e18;

        emit MarketRiskConfigured(marketId, baseInitialMarginBps, baseMaintenanceMarginBps, volatilityWad);
    }

    function setCorrelation(
        bytes32 marketA,
        bytes32 marketB,
        int256 correlationWad
    ) external onlyOwner {
        if (correlationWad < -1e18 || correlationWad > 1e18) revert ValenceRiskMatrix__CorrelationOutOfBounds();

        _correlations[marketA][marketB] = correlationWad;
        _correlations[marketB][marketA] = correlationWad;

        emit CorrelationConfigured(marketA, marketB, correlationWad);
    }

    function getMarketConfig(bytes32 marketId) external view returns (MarketRiskConfig memory) {
        return _marketConfigs[marketId];
    }

    function getCorrelation(bytes32 marketA, bytes32 marketB) external view returns (int256) {
        if (marketA == marketB) return 1e18;
        return _correlations[marketA][marketB];
    }

    function getConfiguredMarkets() external view returns (bytes32[] memory) {
        return _configuredMarkets;
    }
}
