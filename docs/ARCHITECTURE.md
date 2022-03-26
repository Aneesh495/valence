# Valence Architecture Specification

Valence is an institutional decentralized clearinghouse, cross-asset portfolio margin engine, and hybrid concentrated-liquidity automated market maker (CLAMM) built on the Ethereum Virtual Machine (EVM).

```
                                  [ TRADERS / API / KEEPERS ]
                                               │
                        ┌──────────────────────┴──────────────────────┐
                        ▼                                             ▼
             [ ValenceRouter / Quoter ]                   [ ValenceOrderBook ]
             (Multi-hop CLAMM Swaps)                      (L3 Limit Order Book)
                        │                                             │
                        ▼                                             ▼
             [ ValencePool (CLAMM) ]                      [ EIP-712 Order Signer ]
             (Ticks, Bitmaps, Virtual Reserves)           (Gasless Nonce Bitmaps)
                        │                                             │
                        └──────────────────────┬──────────────────────┘
                                               │
                                               ▼
                                  [ ValenceClearinghouse ]
                        ┌──────────────────────┼──────────────────────┐
                        ▼                      ▼                      ▼
             [ ValencePositionManager ] [ ValenceFundingEngine ] [ ValenceFeeDistributor ]
             (Perpetual Lifecycle)      (Continuous Index)       (Streaming Revenue)
                        │                      │                      │
                        └──────────────────────┼──────────────────────┘
                                               │
                                               ▼
                                 [ ValencePortfolioMargin ]
                        ┌──────────────────────┴──────────────────────┐
                        ▼                                             ▼
             [ ValenceRiskMatrix ]                        [ MatrixMath (w^T * Sigma * w) ]
             (Risk Tiers, Correlations)                   (Vectorized Covariance Form)
                                               │
                                               ▼
                                      [ ValenceVault ]
                        ┌──────────────────────┴──────────────────────┐
                        ▼                                             ▼
             [ Subaccount Registry ]                      [ Multi-Asset Collateral ]
             (Granular Delegated Keys)                    (ERC-20, ERC-4626 Haircuts)
                                               │
                                               ▼
                                 [ ValenceLiquidationEngine ]
                        ┌──────────────────────┴──────────────────────┐
                        ▼                                             ▼
             [ Dutch Auction Coordinator ]                [ ValenceADLEngine ]
             (Linear/Decaying Discounts)                  (Auto-Deleveraging Queue)
                                               │
                                               ▼
                                  [ ValenceInsuranceFund ]
                                  (Junior / Senior Tranches)
```

---

## 1. System Layers

### 1.1 Collateral Custody Layer (`ValenceVault.sol`, `ValenceAccount.sol`)
- **ValenceVault**: Holds physical ERC-20 collateral and ERC-4626 yield-bearing vault shares. Implements asset whitelisting, deposit risk caps, haircut multipliers (e.g. 15% haircut credited as 85% collateral value), and solvency checks on withdrawals.
- **ValenceAccount**: Hierarchical subaccount registry. Owners generate up to 2^32 distinct subaccounts per EOA. Supports fine-grained delegated session keys with bitmask permissions (Deposit: 1, Trade: 2, Cancel: 4, Liquidate: 8).

### 1.2 Risk & Portfolio Margin Engine (`ValencePortfolioMargin.sol`, `ValenceRiskMatrix.sol`, `MatrixMath.sol`)
- Implements institutional SPAN-style portfolio margining. Rather than computing isolated margin per position, the engine evaluates the quadratic covariance form:
  $$\text{Portfolio Variance} = \mathbf{w}^T \mathbf{\Sigma} \mathbf{w}$$
  where $\mathbf{w}$ is the vector of signed position notionals and $\mathbf{\Sigma}_{ij} = \rho_{ij} \sigma_i \sigma_j$ is the asset covariance matrix.
- Hedged positions with positive correlation (e.g. Long BTC and Short ETH) receive significant margin relief, bounded by a conservative 40% gross MMR floor to guard against basis risk and extreme tail decoupling.

### 1.3 Hybrid Concentrated Liquidity & Limit Order Book (`ValencePool.sol`, `ValenceOrderBook.sol`)
- **ValencePool**: Uniswap v3/v4-style concentrated liquidity kernel with discrete tick spacing, tick bitmaps, and step swap math using 512-bit binary arithmetic.
- **ValenceOrderBook**: On-chain hybrid limit order book combining storage-based Red-Black Trees for $O(\log N)$ price level discovery and doubly-linked lists for $O(1)$ FIFO time priority queues. Supports limit orders, post-only orders, and immediate-or-cancel (IOC) orders.

### 1.4 Oracle & Circuit Breaker Infrastructure (`ValenceOracleRelay.sol`, `ValenceCircuitBreaker.sol`)
- **ValenceOracleRelay**: Multi-feed price aggregator pulling from Pyth Network and Chainlink aggregators. Maintains an on-chain geometric time-weighted average price (TWAP) ring buffer.
- **ValenceCircuitBreaker**: Tracks short-term price velocity $v = \frac{|\Delta P|}{P \cdot \Delta t}$. If price velocity exceeds the administrative threshold (e.g. 500 bps/minute), the market tripwire fires and freezes new position expansions.

### 1.5 Liquidation Waterfall & Solvency Defense (`ValenceLiquidationEngine.sol`, `ValenceADLEngine.sol`, `ValenceInsuranceFund.sol`)
- **Continuous Dutch Auctions**: Underwater accounts undergo soft liquidations via 5-minute Dutch auctions. Collateral discounts start at 200 bps (2%) and linearly decay to 1000 bps (10%), ensuring competitive liquidator participation without toxic frontrunning or liquidation cascades.
- **Auto-Deleveraging (ADL)**: If an account remains insolvent and the insurance fund is depleted, positions in the most profitable opposing quintile are systematically deleveraged at the bankruptcy price.
- **Dual-Tranche Insurance Fund**: Junior LP capital absorbs initial losses with high fee yields; Senior backstop capital provides structural solvency guarantees.

---

## 2. Low-Level EVM Optimization & Engineering Decisions

1. **Custom Fixed-Point Mathematics (`FullMath.sol`, `FixedPointMath.sol`)**:
   - Multiplication and division of two 256-bit numbers with 512-bit intermediate precision using the Chinese Remainder Theorem and Hensel lifting via modulo arithmetic (`mulmod`).
2. **Tick Bitmap Word Search (`TickBitmap.sol`, `BitMath.sol`)**:
   - Single-opcode bit discovery using de Bruijn bit scan sequences for MSB and LSB operations, enabling constant-gas tick traversal.
3. **Via-IR Compilation**:
   - All contracts compile under Solidity 0.8.27 with `via_ir = true` and `optimizer_runs = 200`. Variable lifetimes are optimized into EVM stack slots to prevent stack-too-deep exceptions while preserving inline clarity.
4. **Storage Packing**:
   - Subaccounts, risk tiers, and tick records are packed into single 32-byte storage slots to minimize cold `SLOAD` (2100 gas) and `SSTORE` (20000 gas) overhead.
