# Dutch Auction Liquidation and Solvency Defense Specification

## 1. Liquidation Mechanism Design

Conventional DeFi lending protocols and perpetual exchanges rely on fixed-discount flash liquidations: as soon as an account crosses below the maintenance margin threshold ($HF < 1.0$), any liquidator can instantly purchase collateral at a fixed penalty (e.g. 5% or 10%).

### Vulnerabilities of Fixed-Discount Liquidations:
1. **Pervasive MEV & Priority Gas Wars**: Searchers engage in PGA (Priority Gas Auctions) and bribing block builders, consuming massive gas and causing transaction congestion.
2. **Excessive Penalty on Mild Distress**: An account only $1 under maintenance margin suffers the full 10% penalty, destroying user equity prematurely.
3. **Liquidity Failure Under Extreme Volatility**: During sharp market crashes, fixed discounts can become smaller than order book slippage, causing liquidations to stall and generating bad debt.

Valence addresses these vulnerabilities by implementing continuous Dutch auction liquidations with dynamic discount schedules.

---

## 2. Continuous Dutch Auction Mechanics (`ValenceLiquidationEngine.sol`)

When a subaccount violates maintenance margin requirements ($HF < 1.0$), a 5-minute Dutch auction is initialized.

### 2.1 Discount Decay Schedule

Let $t_0$ be the auction start time and $D = 300\text{ seconds}$ be the auction duration. For any current timestamp $t \in [t_0, t_0 + D]$:

$$\Delta t = t - t_0$$

The effective discount $d(t) \in [d_{min}, d_{max}]$ in basis points is given by:

$$d(t) = d_{min} + \left(d_{max} - d_{min}\right) \cdot \frac{\Delta t}{D}$$

Default institutional parameters:
- $d_{min} = 200\text{ bps}$ (2.0% initial discount)
- $d_{max} = 1000\text{ bps}$ (10.0% maximum discount)
- $D = 300\text{ seconds}$ (5 minutes total duration)

### 2.2 Collateral Pricing and Debt Repayment

A liquidator repays debt $Q_{debt}$ in USD and receives collateral value $C_{awarded}$:

$$C_{awarded} = \frac{Q_{debt}}{1 - \frac{d(t)}{10000}}$$

Example:
- At $t = t_0 + 150\text{s}$ (halfway through the auction), the discount is:
  $$d(150) = 200 + (800 \cdot 150 / 300) = 600\text{ bps } (6.0\%)$$
- If a liquidator repays $2,350\text{ USD}$ of debt, they receive:
  $$C_{awarded} = \frac{2350}{1 - 0.06} = \frac{2350}{0.94} = 2,500\text{ USD of collateral}$$
- Gross liquidator profit: $2500 - 2350 = 150\text{ USD}$.

### 2.3 Partial Liquidation Support

Liquidators are not required to repay the entire debt at once. Auctions accept partial fills. Each purchase proportionally reduces both the debt to cover and remaining available collateral, allowing multiple competitive keepers to absorb distressed positions smoothly.

---

## 3. Auto-Deleveraging (ADL) Protocol (`ValenceADLEngine.sol`)

If an auction expires without full resolution and the account's equity falls below zero ($E \le 0$), the protocol invokes the Auto-Deleveraging Engine.

### 3.1 Priority Ranking

Traders on the profitable counter-side of the market are ranked by leverage and unrealized profit:

$$\text{ADL Score}_k = \text{UnrealizedPnL}_{ratio, k} \cdot \text{EffectiveLeverage}_k$$

Traders in the top quintile (highest ADL score) are sequentially matched against the bankrupt position at the bankruptcy price (the mark price where the underwater account's equity is zero).

### 3.2 Benefits of ADL
- **Zero Bad Debt Socialization**: Eliminates system insolvency without socialized loss hair-cutting across uninvolved solvent traders.
- **Capital Protection**: Protects the Insurance Fund as a last-resort reserve.

---

## 4. Multi-Tranche Insurance Fund (`ValenceInsuranceFund.sol`)

The Valence Insurance Fund acts as a solvency backstop before ADL is triggered:
1. **Junior Tranche**: Community LP capital that absorbs first-loss liquidations in exchange for 70% of liquidation penalties and perpetual trading fee cuts.
2. **Senior Tranche**: Reserve pool deployed only when Junior Tranche capital falls below 20% of its target capacity.
