// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title IValenceOracleRelay
/// @notice Multi-source oracle aggregator with volatility dampeners, staleness guards, and TWAP.
interface IValenceOracleRelay {
    event PriceReported(bytes32 indexed marketId, uint256 priceX96, uint64 timestamp, uint8 sourceId);
    event CircuitBreakerTripped(bytes32 indexed marketId, uint256 triggerPriceX96, uint256 referencePriceX96);

    struct OracleReport {
        uint256 priceX96;
        uint64 timestamp;
        uint32 confidenceBps;
        bool isValid;
    }

    function getIndexPrice(bytes32 marketId) external view returns (uint256 priceX96);
    function getMarkPrice(bytes32 marketId) external view returns (uint256 priceX96);
    function getTwapPrice(bytes32 marketId, uint32 periodSeconds) external view returns (uint256 priceX96);
    function isCircuitBreakerActive(bytes32 marketId) external view returns (bool);
}
