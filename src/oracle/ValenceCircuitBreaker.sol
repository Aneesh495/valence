// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IValenceOracleRelay} from "../interfaces/IValenceOracleRelay.sol";

/// @title ValenceCircuitBreaker
/// @notice Volatility tripwire and flash-crash suppression engine for perpetual markets.
/// @dev Automatically pauses trades if price velocity or deviation exceeds safety thresholds.
contract ValenceCircuitBreaker {
    address public immutable owner;
    IValenceOracleRelay public immutable oracleRelay;

    struct CircuitConfig {
        bool isEnabled;
        uint32 maxVelocityBps;       // Max permitted price change in basis points (e.g. 1000 = 10%)
        uint32 windowSeconds;        // Velocity window (e.g. 60 seconds)
        uint32 cooldownDuration;     // How long market remains paused after trip (e.g. 300 seconds)
        uint64 lastTripTimestamp;
        uint256 referencePriceX96;
        uint64 referenceTimestamp;
    }

    mapping(bytes32 => CircuitConfig) private _configs;

    event CircuitBreakerConfigured(bytes32 indexed marketId, uint32 maxVelocityBps, uint32 windowSeconds);
    event CircuitBreakerTripped(bytes32 indexed marketId, uint256 currentPriceX96, uint256 referencePriceX96);
    event CircuitBreakerReset(bytes32 indexed marketId);

    error ValenceCircuitBreaker__Unauthorized();
    error ValenceCircuitBreaker__ZeroAddress();
    error ValenceCircuitBreaker__CircuitTripped();

    modifier onlyOwner() {
        if (msg.sender != owner) revert ValenceCircuitBreaker__Unauthorized();
        _;
    }

    constructor(address _oracleRelay) {
        if (_oracleRelay == address(0)) revert ValenceCircuitBreaker__ZeroAddress();
        owner = msg.sender;
        oracleRelay = IValenceOracleRelay(_oracleRelay);
    }

    function configureMarketCircuit(
        bytes32 marketId,
        uint32 maxVelocityBps,
        uint32 windowSeconds,
        uint32 cooldownDuration
    ) external onlyOwner {
        uint256 currentPrice = oracleRelay.getIndexPrice(marketId);
        _configs[marketId] = CircuitConfig({
            isEnabled: true,
            maxVelocityBps: maxVelocityBps,
            windowSeconds: windowSeconds,
            cooldownDuration: cooldownDuration,
            lastTripTimestamp: 0,
            referencePriceX96: currentPrice,
            referenceTimestamp: uint64(block.timestamp)
        });

        emit CircuitBreakerConfigured(marketId, maxVelocityBps, windowSeconds);
    }

    /// @notice Validates current price velocity, tripping the breaker if volatility thresholds are exceeded.
    function checkAndTrip(bytes32 marketId) external returns (bool isTripped) {
        CircuitConfig storage cfg = _configs[marketId];
        if (!cfg.isEnabled) return false;

        // Check if currently cooling down
        if (cfg.lastTripTimestamp != 0) {
            if (block.timestamp <= cfg.lastTripTimestamp + cfg.cooldownDuration) {
                return true;
            } else {
                // Cooldown ended, reset breaker
                cfg.lastTripTimestamp = 0;
                cfg.referencePriceX96 = oracleRelay.getIndexPrice(marketId);
                cfg.referenceTimestamp = uint64(block.timestamp);
                emit CircuitBreakerReset(marketId);
                return false;
            }
        }

        uint256 currentPrice = oracleRelay.getIndexPrice(marketId);
        uint64 timeElapsed = uint64(block.timestamp) - cfg.referenceTimestamp;

        if (timeElapsed >= cfg.windowSeconds) {
            // Slide window forward
            cfg.referencePriceX96 = currentPrice;
            cfg.referenceTimestamp = uint64(block.timestamp);
            return false;
        }

        // Calculate velocity
        uint256 refPrice = cfg.referencePriceX96;
        if (refPrice > 0) {
            uint256 diff = currentPrice > refPrice ? currentPrice - refPrice : refPrice - currentPrice;
            uint256 changeBps = (diff * 10000) / refPrice;

            if (changeBps > cfg.maxVelocityBps) {
                cfg.lastTripTimestamp = uint64(block.timestamp);
                emit CircuitBreakerTripped(marketId, currentPrice, refPrice);
                return true;
            }
        }

        return false;
    }

    function isMarketPaused(bytes32 marketId) external view returns (bool) {
        CircuitConfig memory cfg = _configs[marketId];
        if (!cfg.isEnabled) return false;
        return cfg.lastTripTimestamp != 0 && (block.timestamp <= cfg.lastTripTimestamp + cfg.cooldownDuration);
    }
}
