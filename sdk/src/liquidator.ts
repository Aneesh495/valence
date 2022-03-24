import { Address, Hash, DutchAuction } from "./types";

export interface LiquidatorConfig {
  clearinghouseAddress: Address;
  liquidationEngineAddress: Address;
  targetProfitMarginBps: number;
  maxGasPriceGwei: bigint;
  minLiquidationUsd: bigint;
}

/**
 * Autonomous liquidation keeper engine tracking active Dutch auctions and computing optimal fills.
 */
export class ValenceLiquidationKeeper {
  private config: LiquidatorConfig;

  constructor(config: LiquidatorConfig) {
    this.config = config;
  }

  /**
   * Computes current auction discount in basis points.
   */
  public calculateCurrentDiscount(auction: DutchAuction, currentTimestamp: bigint): number {
    if (currentTimestamp <= auction.startTime) {
      return auction.startDiscountBps;
    }
    const elapsed = Number(currentTimestamp - auction.startTime);
    if (elapsed >= auction.duration) {
      return auction.maxDiscountBps;
    }
    const range = auction.maxDiscountBps - auction.startDiscountBps;
    return Math.floor(auction.startDiscountBps + (range * elapsed) / auction.duration);
  }

  /**
   * Evaluates if an active auction has reached the keeper's target profitability hurdle.
   */
  public evaluateAuctionOpportunity(
    auction: DutchAuction,
    currentTimestamp: bigint,
    estimatedGasCostUsd: bigint
  ): {
    isProfitable: boolean;
    discountBps: number;
    recommendedDebtRepayUsd: bigint;
    expectedCollateralAwardedUsd: bigint;
    projectedNetProfitUsd: bigint;
  } {
    if (auction.isResolved) {
      return {
        isProfitable: false,
        discountBps: 0,
        recommendedDebtRepayUsd: 0n,
        expectedCollateralAwardedUsd: 0n,
        projectedNetProfitUsd: 0n
      };
    }

    const discountBps = this.calculateCurrentDiscount(auction, currentTimestamp);
    const denominator = BigInt(10000 - discountBps);

    // Full available debt to repay
    const debtToRepay = auction.debtToCoverUsd;
    let collateralAwarded = (debtToRepay * 10000n) / denominator;

    if (collateralAwarded > auction.collateralAvailableUsd) {
      collateralAwarded = auction.collateralAvailableUsd;
    }

    const grossProfitUsd = collateralAwarded > debtToRepay ? collateralAwarded - debtToRepay : 0n;
    const projectedNetProfitUsd = grossProfitUsd > estimatedGasCostUsd ? grossProfitUsd - estimatedGasCostUsd : 0n;

    // Check if net profit exceeds hurdle
    const targetNetProfitHurdle = (debtToRepay * BigInt(this.config.targetProfitMarginBps)) / 10000n;
    const isProfitable = projectedNetProfitUsd >= targetNetProfitHurdle && debtToRepay >= this.config.minLiquidationUsd;

    return {
      isProfitable,
      discountBps,
      recommendedDebtRepayUsd: debtToRepay,
      expectedCollateralAwardedUsd: collateralAwarded,
      projectedNetProfitUsd
    };
  }
}
