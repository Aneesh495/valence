import { test } from "node:test";
import assert from "node:assert";
import {
  EIP712OrderSigner,
  ValenceLiquidationKeeper,
  ValenceOracleKeeper,
  ValenceClient,
  OrderSide,
  OrderType,
  DutchAuction
} from "../src";

test("EIP-712 Order Hashing and Bitmask", () => {
  const domain = {
    name: "Valence",
    version: "1.0",
    chainId: 1,
    verifyingContract: "0x1111111111111111111111111111111111111111" as const
  };

  const domainSeparator = EIP712OrderSigner.computeDomainSeparator(domain);
  assert.ok(domainSeparator.startsWith("0x"));
  assert.strictEqual(domainSeparator.length, 66);

  const order = {
    subaccountId: "0x2222222222222222222222222222222222222222222222222222222222222222" as const,
    maker: "0x3333333333333333333333333333333333333333" as const,
    marketId: "0x4444444444444444444444444444444444444444444444444444444444444444" as const,
    side: OrderSide.BUY,
    orderType: OrderType.LIMIT,
    priceX96: 60000n << 96n,
    quantity: 1000000000000000000n,
    nonce: 515n, // word 2, bit 3 (515 = 256 * 2 + 3)
    expiration: 1800000000n
  };

  const structHash = EIP712OrderSigner.hashOrder(order);
  assert.strictEqual(structHash.length, 66);

  const digest = EIP712OrderSigner.computeDigest(domainSeparator, structHash);
  assert.strictEqual(digest.length, 66);

  const bitmask = EIP712OrderSigner.getCancelBitmask(515n);
  assert.strictEqual(bitmask.wordIndex, 2n);
  assert.strictEqual(bitmask.mask, 1n << 3n);
});

test("Dutch Auction Liquidation Keeper Calculations", () => {
  const keeper = new ValenceLiquidationKeeper({
    clearinghouseAddress: "0x1111111111111111111111111111111111111111",
    liquidationEngineAddress: "0x2222222222222222222222222222222222222222",
    targetProfitMarginBps: 200, // 2%
    maxGasPriceGwei: 50n,
    minLiquidationUsd: 1000n * 10n ** 18n
  });

  const auction: DutchAuction = {
    auctionId: "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
    subaccountId: "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
    debtToCoverUsd: 5000n * 10n ** 18n,
    collateralAvailableUsd: 6000n * 10n ** 18n,
    startTime: 1000n,
    duration: 300,
    startDiscountBps: 200,
    maxDiscountBps: 1000,
    isResolved: false
  };

  // At t = 1000n (0s elapsed): discount is 200 bps (2%)
  const d0 = keeper.calculateCurrentDiscount(auction, 1000n);
  assert.strictEqual(d0, 200);

  // At t = 1150n (150s elapsed): discount is 600 bps (6%)
  const d150 = keeper.calculateCurrentDiscount(auction, 1150n);
  assert.strictEqual(d150, 600);

  // Profit evaluation at 150s: 6% discount gives profitable liquidation
  const opp = keeper.evaluateAuctionOpportunity(auction, 1150n, 15n * 10n ** 18n);
  assert.strictEqual(opp.isProfitable, true);
  assert.strictEqual(opp.discountBps, 600);
  assert.ok(opp.projectedNetProfitUsd > 0n);
});

test("Oracle Keeper Median and Velocity Calculations", () => {
  const oracleKeeper = new ValenceOracleKeeper(500); // 500 bps/min max velocity

  const prices = [3000n, 3050n, 3010n, 2990n, 3020n];
  const median = oracleKeeper.computeMedianPriceX96(prices);
  assert.strictEqual(median, 3010n);

  const marketId = "0x4444444444444444444444444444444444444444444444444444444444444444" as const;
  
  // Initial price: 3000 at t = 60
  oracleKeeper.checkPriceVelocity(marketId, 3000n, 60n);

  // Normal movement: 3010 at t = 120 (10 bps over 1 min -> 10 bps/min)
  const resNormal = oracleKeeper.checkPriceVelocity(marketId, 3010n, 120n);
  assert.strictEqual(resNormal.tripsCircuitBreaker, false);

  // Flash crash: 2500 at t = 180 (~1700 bps over 1 min -> exceeds 500 bps/min)
  const resFlashCrash = oracleKeeper.checkPriceVelocity(marketId, 2500n, 180n);
  assert.strictEqual(resFlashCrash.tripsCircuitBreaker, true);
});

test("ValenceClient Calldata Encoders", () => {
  const client = new ValenceClient({
    clearinghouseAddress: "0x1111111111111111111111111111111111111111",
    vaultAddress: "0x2222222222222222222222222222222222222222",
    orderBookAddress: "0x3333333333333333333333333333333333333333",
    routerAddress: "0x4444444444444444444444444444444444444444",
    oracleRelayAddress: "0x5555555555555555555555555555555555555555",
    portfolioMarginAddress: "0x6666666666666666666666666666666666666666",
    chainId: 1
  });

  const subaccountId = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  const usdc = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  const btcMarket = "0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

  const depositPayload = client.encodeDeposit(subaccountId, usdc, 1000000n);
  assert.strictEqual(depositPayload.to, "0x2222222222222222222222222222222222222222");
  assert.ok(depositPayload.data.startsWith("0x47e7ef24"));

  const tradePayload = client.encodeExecuteTrade(subaccountId, btcMarket, 1000000000000000000n, 60000n << 96n);
  assert.strictEqual(tradePayload.to, "0x1111111111111111111111111111111111111111");
  assert.ok(tradePayload.data.startsWith("0x7599cb51"));
});
