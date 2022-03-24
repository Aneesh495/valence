import { Address, Hash } from "./types";

export interface OracleUpdatePayload {
  marketId: Hash;
  priceX96: bigint;
  timestamp: bigint;
  source: "PYTH" | "CHAINLINK" | "INTERNAL";
}

/**
 * Autonomous keeper for monitoring multi-feed oracle health, geometric TWAPs, and circuit breaker velocity.
 */
export class ValenceOracleKeeper {
  private readonly maxAllowedVelocityBps: number;
  private lastObservedPrices: Map<Hash, { priceX96: bigint; timestamp: bigint }>;

  constructor(maxAllowedVelocityBps: number = 500) {
    this.maxAllowedVelocityBps = maxAllowedVelocityBps;
    this.lastObservedPrices = new Map();
  }

  /**
   * Evaluates if a newly reported price exceeds maximum price velocity bounds (circuit breaker tripwire).
   */
  public checkPriceVelocity(marketId: Hash, newPriceX96: bigint, currentTimestamp: bigint): {
    tripsCircuitBreaker: boolean;
    velocityBps: number;
  } {
    const prev = this.lastObservedPrices.get(marketId);
    if (!prev) {
      this.lastObservedPrices.set(marketId, { priceX96: newPriceX96, timestamp: currentTimestamp });
      return { tripsCircuitBreaker: false, velocityBps: 0 };
    }

    const elapsed = Number(currentTimestamp - prev.timestamp);
    if (elapsed <= 0) {
      return { tripsCircuitBreaker: false, velocityBps: 0 };
    }

    const priceDiff = newPriceX96 > prev.priceX96 ? newPriceX96 - prev.priceX96 : prev.priceX96 - newPriceX96;
    const changeBps = Number((priceDiff * 10000n) / prev.priceX96);

    // Annualized or step velocity: change / (elapsed seconds / 60)
    const velocityPerMinute = Math.floor(changeBps / Math.max(1, elapsed / 60));
    const trips = velocityPerMinute > this.maxAllowedVelocityBps;

    this.lastObservedPrices.set(marketId, { priceX96: newPriceX96, timestamp: currentTimestamp });
    return { tripsCircuitBreaker: trips, velocityBps: velocityPerMinute };
  }

  /**
   * Computes geometric median of an array of prices.
   */
  public computeMedianPriceX96(prices: bigint[]): bigint {
    if (prices.length === 0) return 0n;
    const sorted = [...prices].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
    const mid = Math.floor(sorted.length / 2);
    if (sorted.length % 2 === 1) {
      return sorted[mid];
    }
    return (sorted[mid - 1] + sorted[mid]) / 2n;
  }
}
