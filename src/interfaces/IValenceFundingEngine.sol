// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title IValenceFundingEngine
/// @notice Computes and continuously accrues mark-to-index perpetual funding rates.
interface IValenceFundingEngine {
    event FundingUpdated(
        bytes32 indexed marketId,
        int256 fundingRatePerSecondWad,
        int256 cumulativeFundingIndexWad,
        uint64 timestamp
    );

    struct MarketFundingState {
        int256 cumulativeFundingIndexWad; // Running sum of funding per contract unit
        int256 lastFundingRateWad;        // Instantaneous annual funding rate
        uint64 lastUpdateTime;
        uint32 fundingIntervalSeconds;
        int32 maxFundingRateWad;          // Absolute funding clamp
    }

    function updateFunding(bytes32 marketId) external returns (int256 currentRate);
    function getFundingState(bytes32 marketId) external view returns (MarketFundingState memory);
    function getAccruedFunding(bytes32 marketId, int256 entryFundingIndex, int256 positionSize) external view returns (int256 fundingPnl);
}
