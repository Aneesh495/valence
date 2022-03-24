/**
 * Core type declarations for the Valence Decentralized Clearinghouse TypeScript SDK.
 */

export type Address = `0x${string}`;
export type Hash = `0x${string}`;

export enum OrderSide {
  BUY = 0,
  SELL = 1
}

export enum OrderType {
  LIMIT = 0,
  POST_ONLY = 1,
  IMMEDIATE_OR_CANCEL = 2,
  FILL_OR_KILL = 3
}

export interface EIP712Domain {
  name: string;
  version: string;
  chainId: number;
  verifyingContract: Address;
}

export interface OrderPayload {
  subaccountId: Hash;
  maker: Address;
  marketId: Hash;
  side: OrderSide;
  orderType: OrderType;
  priceX96: bigint;
  quantity: bigint;
  nonce: bigint;
  expiration: bigint;
}

export interface AccountRiskProfile {
  totalCollateralValueUsd: bigint;
  totalUnrealizedPnlUsd: bigint;
  initialMarginRequiredUsd: bigint;
  maintenanceMarginUsd: bigint;
  healthFactor: bigint;
  isSolvent: boolean;
  isLiquidatable: boolean;
}

export interface PositionSummary {
  marketId: Hash;
  size: bigint;
  entryPriceX96: bigint;
  unrealizedPnl: bigint;
  notionalUsd: bigint;
}

export interface DutchAuction {
  auctionId: Hash;
  subaccountId: Hash;
  debtToCoverUsd: bigint;
  collateralAvailableUsd: bigint;
  startTime: bigint;
  duration: number;
  startDiscountBps: number;
  maxDiscountBps: number;
  isResolved: boolean;
}

export interface MarketConfig {
  marketId: Hash;
  baseInitialMarginBps: number;
  baseMaintenanceMarginBps: number;
  volatilityWad: bigint;
  concentrationScaleFactor: number;
}
