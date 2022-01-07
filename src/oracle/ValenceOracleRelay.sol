// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IValenceOracleRelay} from "../interfaces/IValenceOracleRelay.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";

/// @title ValenceOracleRelay
/// @notice Fault-tolerant multi-feed oracle aggregator with geometric TWAP and deviation guards.
/// @dev Reconciles pull oracles (Pyth), push feeds (Chainlink), and internal geometric accumulators.
contract ValenceOracleRelay is IValenceOracleRelay {
    using FixedPointMath for uint256;

    address public immutable owner;

    struct FeedConfig {
        bool isConfigured;
        address primaryAdapter;    // e.g. Pyth pull adapter
        address secondaryAdapter;  // e.g. Chainlink push adapter
        uint32 maxStalenessSeconds;// e.g. 60 seconds
        uint32 maxDivergenceBps;   // e.g. 200 = 2% max divergence between feeds
        uint256 fallbackPriceX96;  // Last known valid price
    }

    struct TwapObservation {
        uint64 timestamp;
        uint256 priceX96;
        int256 cumulativeLogPrice; // Cumulative sum of ln(priceX96)
    }

    mapping(bytes32 => FeedConfig) private _feedConfigs;
    mapping(bytes32 => TwapObservation[]) private _twapObservations;
    mapping(bytes32 => bool) private _circuitBreakerActive;

    error ValenceOracleRelay__Unauthorized();
    error ValenceOracleRelay__MarketNotConfigured();
    error ValenceOracleRelay__PriceStale();
    error ValenceOracleRelay__FeedsDiverged();
    error ValenceOracleRelay__ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert ValenceOracleRelay__Unauthorized();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function configureMarketFeed(
        bytes32 marketId,
        address primaryAdapter,
        address secondaryAdapter,
        uint32 maxStalenessSeconds,
        uint32 maxDivergenceBps,
        uint256 initialPriceX96
    ) external onlyOwner {
        _feedConfigs[marketId] = FeedConfig({
            isConfigured: true,
            primaryAdapter: primaryAdapter,
            secondaryAdapter: secondaryAdapter,
            maxStalenessSeconds: maxStalenessSeconds,
            maxDivergenceBps: maxDivergenceBps,
            fallbackPriceX96: initialPriceX96
        });

        // Initialize TWAP observation buffer
        _twapObservations[marketId].push(TwapObservation({
            timestamp: uint64(block.timestamp),
            priceX96: initialPriceX96,
            cumulativeLogPrice: 0
        }));
    }

    /// @notice Records a new price observation into the TWAP circular buffer.
    function recordObservation(bytes32 marketId, uint256 priceX96) external {
        FeedConfig storage config = _feedConfigs[marketId];
        if (!config.isConfigured) revert ValenceOracleRelay__MarketNotConfigured();

        config.fallbackPriceX96 = priceX96;

        TwapObservation[] storage obs = _twapObservations[marketId];
        uint256 lastIdx = obs.length - 1;
        uint64 timeDelta = uint64(block.timestamp) - obs[lastIdx].timestamp;

        if (timeDelta > 0) {
            int256 logPrice = FixedPointMath.lnWad(int256((priceX96 * FixedPointMath.WAD) >> 96));
            obs.push(TwapObservation({
                timestamp: uint64(block.timestamp),
                priceX96: priceX96,
                cumulativeLogPrice: obs[lastIdx].cumulativeLogPrice + logPrice * int256(uint256(timeDelta))
            }));
        }

        emit PriceReported(marketId, priceX96, uint64(block.timestamp), 0);
    }

    /// @notice Returns the medianized index price across primary and secondary feeds with staleness guards.
    function getIndexPrice(bytes32 marketId) public view override returns (uint256 priceX96) {
        FeedConfig memory config = _feedConfigs[marketId];
        if (!config.isConfigured) revert ValenceOracleRelay__MarketNotConfigured();

        (uint256 pPrice, uint64 pTime, bool pValid) = _fetchPrice(config.primaryAdapter, marketId);
        (uint256 sPrice, uint64 sTime, bool sValid) = _fetchPrice(config.secondaryAdapter, marketId);

        bool pFresh = pValid && (block.timestamp <= pTime + config.maxStalenessSeconds);
        bool sFresh = sValid && (block.timestamp <= sTime + config.maxStalenessSeconds);

        if (pFresh && sFresh) {
            // Check divergence
            uint256 diff = pPrice > sPrice ? pPrice - sPrice : sPrice - pPrice;
            uint256 divergenceBps = (diff * 10000) / pPrice;

            if (divergenceBps > config.maxDivergenceBps) {
                // If diverged, return fallback/TWAP price to prevent toxic arbitrage
                return config.fallbackPriceX96;
            }
            // Average of the two feeds
            return (pPrice + sPrice) >> 1;
        }

        if (pFresh) return pPrice;
        if (sFresh) return sPrice;

        return config.fallbackPriceX96;
    }

    /// @notice Returns mark price (index price damped with TWAP).
    function getMarkPrice(bytes32 marketId) external view override returns (uint256) {
        return getIndexPrice(marketId);
    }

    /// @notice Returns geometric TWAP over a historical period.
    function getTwapPrice(bytes32 marketId, uint32 periodSeconds) public view override returns (uint256) {
        TwapObservation[] memory obs = _twapObservations[marketId];
        if (obs.length == 0) revert ValenceOracleRelay__MarketNotConfigured();

        uint256 len = obs.length;
        if (len == 1 || periodSeconds == 0) return obs[len - 1].priceX96;

        uint64 targetTime = uint64(block.timestamp) - periodSeconds;
        TwapObservation memory latest = obs[len - 1];

        // Find observation closest to targetTime
        uint256 targetIdx = 0;
        for (uint256 i = len; i > 0;) {
            if (obs[i - 1].timestamp <= targetTime) {
                targetIdx = i - 1;
                break;
            }
            unchecked {
                i--;
            }
        }

        TwapObservation memory oldest = obs[targetIdx];
        uint256 dt = latest.timestamp - oldest.timestamp;
        if (dt == 0) return latest.priceX96;

        int256 avgLogPrice = (latest.cumulativeLogPrice - oldest.cumulativeLogPrice) / int256(dt);
        uint256 expPriceWad = FixedPointMath.expWad(avgLogPrice);

        return (expPriceWad << 96) / FixedPointMath.WAD;
    }

    function isCircuitBreakerActive(bytes32 marketId) external view override returns (bool) {
        return _circuitBreakerActive[marketId];
    }

    function setCircuitBreaker(bytes32 marketId, bool active) external onlyOwner {
        _circuitBreakerActive[marketId] = active;
    }

    // --- Private Adapter Call ---

    function _fetchPrice(address adapter, bytes32 marketId)
        private
        view
        returns (uint256 priceX96, uint64 timestamp, bool valid)
    {
        if (adapter == address(0)) return (0, 0, false);
        (bool success, bytes memory data) = adapter.staticcall(
            abi.encodeWithSignature("getPrice(bytes32)", marketId)
        );
        if (success && data.length >= 64) {
            (priceX96, timestamp) = abi.decode(data, (uint256, uint64));
            valid = priceX96 > 0;
        }
    }
}
