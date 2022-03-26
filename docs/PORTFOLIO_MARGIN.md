# SPAN-Style Portfolio Margin Mathematical Specification

## 1. Overview and Problem Formulation

Conventional decentralized derivatives protocols evaluate margin on an isolated basis: each open position requires independent initial margin ($IMR_i$) and maintenance margin ($MMR_i$):

$$\text{Isolated MMR} = \sum_{i=1}^n |w_i| \cdot MMR_{bps, i}$$

where $w_i = \text{size}_i \cdot P_i$ denotes the signed USD notional of position $i$.

Isolated margin ignores statistical cross-asset correlations. A trader holding long BTC-PERP and short ETH-PERP maintains a market-neutral basis position whose variance is dramatically smaller than either leg alone. Valence implements institutional SPAN-style portfolio margin on-chain, determining margin from the covariance matrix of returns.

---

## 2. Mathematical Formulation

### 2.1 The Covariance Matrix

Let $n$ be the number of active asset markets. For asset $i$, let $\sigma_i$ denote the annualized volatility calibrated from historical log returns:

$$\sigma_i = \sqrt{\frac{252}{K} \sum_{k=1}^K (r_{i, k} - \bar{r}_i)^2}$$

Let $\rho_{ij} \in [-1, 1]$ denote the pairwise Pearson correlation coefficient between assets $i$ and $j$. The covariance between asset $i$ and asset $j$ is given by:

$$\Sigma_{ij} = \rho_{ij} \sigma_i \sigma_j$$

In the Valence contracts, $\rho_{ij}$ and $\sigma_i$ are represented in fixed-point 18-decimal precision (WAD):
- `volatilityWad = 0.50e18` represents 50% annualized volatility.
- `correlationWad = 0.85e18` represents an 85% correlation coefficient.

### 2.2 Portfolio Variance and Quadratic Form

Let $\mathbf{w} = [w_1, w_2, \dots, w_n]^T$ be the signed USD notional vector:
- $w_i > 0$ for long positions.
- $w_i < 0$ for short positions.

The total annualized portfolio variance $V_p$ is computed via the quadratic form:

$$V_p = \mathbf{w}^T \mathbf{\Sigma} \mathbf{w} = \sum_{i=1}^n \sum_{j=1}^n w_i w_j \Sigma_{ij}$$

The annualized portfolio risk (standard deviation of USD returns) is:

$$\sigma_p = \sqrt{V_p} = \sqrt{\mathbf{w}^T \mathbf{\Sigma} \mathbf{w}}$$

### 2.3 Gross Volatility Notional and Diversification Ratio

To translate the annual portfolio standard deviation into an operational maintenance margin requirement, Valence computes the gross volatility notional:

$$\Omega_{gross} = \sum_{i=1}^n |w_i| \sigma_i$$

The portfolio diversification risk factor $\gamma$ is the ratio of net portfolio risk to gross unhedged risk:

$$\gamma = \min\left(1.0, \frac{\sigma_p}{\Omega_{gross}}\right)$$

Properties of $\gamma$:
1. **Single Asset**: If an account holds only a single position $i$, then $\sigma_p = |w_i| \sigma_i = \Omega_{gross}$, yielding $\gamma = 1.0$.
2. **Perfect Hedge**: If two positions are perfectly negatively correlated ($\rho = -1$) or long-short with high correlation, $\sigma_p \to 0$, yielding $\gamma \ll 1.0$.

### 2.4 Maintenance and Initial Margin Requirements

The gross unhedged maintenance margin requirement is:

$$MMR_{gross} = \sum_{i=1}^n |w_i| \cdot MMR_{bps, i}$$

The net portfolio maintenance margin requirement applies the diversification factor $\gamma$, bounded by an institutional safety floor:

$$MMR_{net} = \max\left(0.40 \cdot MMR_{gross}, \gamma \cdot MMR_{gross}\right)$$

Similarly, for Initial Margin Requirement (IMR):

$$IMR_{net} = \max\left(0.50 \cdot IMR_{gross}, \gamma \cdot IMR_{gross}\right)$$

The 40% floor prevents model breakdown during structural regime shifts, liquidity droughts, or sudden correlation breakdowns.

---

## 3. Position Size Concentration Penalties

To protect the clearinghouse against market impact and slippage during liquidation of large positions, Valence applies an endogenous non-linear concentration multiplier $C(w)$:

$$C(w) = 1.0 + \frac{\alpha \cdot \sqrt{|w|}}{10000}$$

where $\alpha$ is the market concentration scale factor. As position notional $|w|$ expands, both IMR and MMR scale superlinearly, constraining excessive leverage on large open interest.

---

## 4. Account Solvency and Health Factor

Net account equity $E$ is evaluated continuously:

$$E = \sum_{k=1}^m \text{Balance}_k \cdot P_k \cdot (1 - \text{Haircut}_k) + \sum_{i=1}^n \text{UnrealizedPnL}_i$$

The subaccount Health Factor ($HF$) is defined as:

$$HF = \frac{E}{MMR_{net}}$$

- **Solvent**: $HF \ge 1.0$ (Equity exceeds maintenance margin requirement).
- **Liquidatable**: $HF < 1.0$ (Subject to Dutch auction liquidation).
- **Underwater / Insolvent**: $E \le 0$ (Subject to Auto-Deleveraging).
