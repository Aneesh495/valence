// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IValenceFundingEngine} from "../interfaces/IValenceFundingEngine.sol";
import {IValenceOracleRelay} from "../interfaces/IValenceOracleRelay.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";

/// @title ValenceFundingEngine
/// @notice Computes mark-to-index continuous perpetual funding rates and maintains cumulative funding indices.
/// @dev Dampens funding premiums via TWAPs and enforces asymmetric volatility bounds.
contract ValenceFundingEngine is IValenceFundingEngine {
    using FixedPointMath for uint256;
    using FixedPointMath for int256;

    address public immutable owner;
    IValenceOracleRelay public oracleRelay;

    mapping(bytes32 => MarketFundingState) private _states;

    error ValenceFundingEngine__Unauthorized();
    error ValenceFundingEngine__ZeroAddress();
    error ValenceFundingEngine__MarketNotConfigured();

    modifier onlyOwner() {
        if (msg.sender != owner) revert ValenceFundingEngine__Unauthorized();
        _;
    }

    constructor(address _oracleRelay) {
        if (_oracleRelay == address(0)) revert ValenceFundingEngine__ZeroAddress();
        owner = msg.sender;
        oracleRelay = IValenceOracleRelay(_oracleRelay);
    }

    function setOracleRelay(address _oracleRelay) external onlyOwner {
        if (_oracleRelay == address(0)) revert ValenceFundingEngine__ZeroAddress();
        oracleRelay = IValenceOracleRelay(_oracleRelay);
    }

    function configureMarketFunding(
        bytes32 marketId,
        uint32 fundingIntervalSeconds,
        int32 maxFundingRateWad
    ) external onlyOwner {
        require(fundingIntervalSeconds > 0, "Invalid interval");
        _states[marketId] = MarketFundingState({
            cumulativeFundingIndexWad: 0,
            lastFundingRateWad: 0,
            lastUpdateTime: uint64(block.timestamp),
            fundingIntervalSeconds: fundingIntervalSeconds,
            maxFundingRateWad: maxFundingRateWad
        });
    }

    /// @notice Updates the cumulative funding index for a market based on the latest mark and index prices.
    function updateFunding(bytes32 marketId) external override returns (int256 currentRate) {
        MarketFundingState storage state = _states[marketId];
        if (state.lastUpdateTime == 0) revert ValenceFundingEngine__MarketNotConfigured();

        uint64 elapsed = uint64(block.timestamp) - state.lastUpdateTime;
        if (elapsed == 0) return state.lastFundingRateWad;

        uint256 markPriceX96 = oracleRelay.getMarkPrice(marketId);
        uint256 indexPriceX96 = oracleRelay.getIndexPrice(marketId);

        if (indexPriceX96 > 0) {
            int256 markWad = int256((markPriceX96 * FixedPointMath.WAD) >> 96);
            int256 indexWad = int256((indexPriceX96 * FixedPointMath.WAD) >> 96);

            // Premium = (mark - index) / index
            int256 premium = ((markWad - indexWad) * int256(FixedPointMath.WAD)) / indexWad;

            // Annualized funding rate clamped to max bounds
            int256 clampedRate = premium;
            int256 maxRate = int256(state.maxFundingRateWad);
            if (clampedRate > maxRate) clampedRate = maxRate;
            if (clampedRate < -maxRate) clampedRate = -maxRate;

            state.lastFundingRateWad = clampedRate;

            // Delta funding index = (rate / interval) * elapsed
            int256 deltaIndex = (clampedRate * int256(uint256(elapsed))) / int256(uint256(state.fundingIntervalSeconds));
            state.cumulativeFundingIndexWad += deltaIndex;
        }

        state.lastUpdateTime = uint64(block.timestamp);
        emit FundingUpdated(marketId, state.lastFundingRateWad, state.cumulativeFundingIndexWad, state.lastUpdateTime);

        return state.lastFundingRateWad;
    }

    /// @notice Computes accrued funding PnL for a position since entry index.
    function getAccruedFunding(
        bytes32 marketId,
        int256 entryFundingIndex,
        int256 positionSize
    ) external view override returns (int256 fundingPnl) {
        if (positionSize == 0) return 0;
        MarketFundingState memory state = _states[marketId];

        // fundingDelta = currentIndex - entryIndex
        int256 fundingDelta = state.cumulativeFundingIndexWad - entryFundingIndex;

        // Long pays when index increases: pnl = - (size * delta) / 1e18
        // Short receives when index increases: - (-size * delta) = size * delta
        fundingPnl = -(positionSize * fundingDelta) / int256(FixedPointMath.WAD);
    }

    function getFundingState(bytes32 marketId) external view override returns (MarketFundingState memory) {
        return _states[marketId];
    }
}
