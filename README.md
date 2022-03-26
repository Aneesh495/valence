# VALENCE

```
██╗   ██╗ █████╗ ██╗     ███████╗███╗   ██╗ ██████╗███████╗
██║   ██║██╔══██╗██║     ██╔════╝████╗  ██║██╔════╝██╔════╝
██║   ██║███████║██║     █████╗  ██╔██╗ ██║██║     █████╗  
╚██╗ ██╔╝██╔══██║██║     ██╔══╝  ██║╚██╗██║██║     ██╔══╝  
 ╚████╔╝ ██║  ██║███████╗███████╗██║ ╚████║╚██████╗███████╗
  ╚═══╝  ╚═╝  ╚═╝╚══════╝╚══════╝╚═╝  ╚═══╝ ╚═════╝╚══════╝
```

> **Decentralized Clearinghouse, SPAN Cross-Asset Portfolio Margin Engine, and Hybrid Concentrated-Liquidity AMM**

[![Solidity](https://img.shields.io/badge/Solidity-0.8.27-363636?logo=solidity)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FF4438?logo=ethereum)](https://getfoundry.sh/)
[![C++20](https://img.shields.io/badge/C%2B%2B-20-00599C?logo=c%2B%2B)](https://isocpp.org/)
[![Python](https://img.shields.io/badge/Python-3.12%2B-3776AB?logo=python)](https://python.org/)
[![TypeScript](https://img.shields.io/badge/TypeScript-5.4-3178C6?logo=typescript)](https://www.typescriptlang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

---

## Architecture Overview

Valence is an institutional decentralized clearinghouse protocol engineered for the Ethereum Virtual Machine (EVM). It introduces cross-asset SPAN portfolio margining with quadratic covariance forms, hybrid limit order book matching against concentrated liquidity (CLAMM) virtual reserves, continuous Dutch auction liquidations, and multi-asset collateral haircuts.

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

## Key Technical Innovations

### 1. On-Chain SPAN Portfolio Margin (`ValencePortfolioMargin.sol`)
Conventional perpetual exchanges evaluate initial and maintenance margin on an isolated per-position basis. Valence evaluates the joint risk of multi-asset portfolios on-chain:
- Computes portfolio variance via quadratic forms: $V_p = \mathbf{w}^T \mathbf{\Sigma} \mathbf{w}$.
- Calibrates pairwise correlation coefficients $\rho_{ij}$ and annualized volatilities $\sigma_i$.
- Offsets margin on correlated cross-asset hedges (e.g. Long BTC and Short ETH) while maintaining an institutional 40% gross MMR floor to guard against basis risk and tail decoupling.
- Incorporates endogenous position concentration penalties scaling with $\sqrt{\text{notional}}$.

### 2. Hybrid Limit Order Book Crossing Against CLAMM (`ValenceOrderBook.sol`, `ValencePool.sol`)
- **Storage-Based Red-Black Trees**: Implements a self-balancing binary search tree on-chain in Solidity, providing $O(\log N)$ price level insertion and removal.
- **Doubly-Linked List Queues**: Resting orders maintain strict $O(1)$ FIFO price-time priority.
- **Concentrated Liquidity Kernel**: 512-bit binary arithmetic (`FullMath.sol`) using the Chinese Remainder Theorem and Hensel lifting via `mulmod` for phantom overflow prevention.

### 3. Continuous Dutch Auction Liquidations (`ValenceLiquidationEngine.sol`)
- Eliminates predatory MEV frontrunning and priority gas auction (PGA) spikes by transitioning underwater accounts to continuous 5-minute Dutch auctions.
- Discounts decay linearly from 200 bps (2.0%) to 1000 bps (10.0%), rewarding competitive keepers while preserving residual user equity.
- Full support for partial liquidations and auto-deleveraging (ADL) fallbacks.

### 4. High-Performance C++20 Order Matching & Clearing Engine (`engine/`)
- Cache-friendly L3 limit order book achieving **24.3 million orders/sec** throughput with **41.1 nanoseconds** average matching latency.
- SIMD-friendly quadratic covariance calculations replicating on-chain SPAN evaluations off-chain.

### 5. Quantitative Risk & Monte Carlo Simulation Suite (`sim/`)
- Correlated multi-asset geometric Brownian motion with Merton jump-diffusion processes.
- Parametric Value-at-Risk (VaR) and Expected Shortfall (CVaR) calculations.
- Game-theoretic liquidator profitability simulation across variable gas and slippage regimes.

### 6. Production TypeScript SDK & Autonomous Keepers (`sdk/`)
- High-level Viem/Ethers calldata encoders for subaccounts, vaults, and clearinghouses.
- EIP-712 structured order hashing and gasless nonce cancellation bitmasks.
- Autonomous liquidation keeper bot scanning for profitable Dutch auction fills.

---

## Repository Structure

```
valence/
├── src/
│   ├── clamm/                 # Concentrated Liquidity AMM contracts (Pool, Factory, Router, Quoter, NFT)
│   ├── core/                  # Central Clearinghouse, Vault, Account Registry, Position & Funding Engines
│   ├── governance/            # Timelock Controller and Emergency Multisig Council
│   ├── interfaces/            # 15 strict interface declarations
│   ├── libraries/             # 512-bit FullMath, TickMath, FixedPointMath, RedBlackTree, LinkedList, MatrixMath
│   ├── liquidation/           # Dutch Auction Liquidation Engine and Auto-Deleveraging (ADL)
│   ├── margin/                # SPAN Portfolio Margin Engine, Risk Matrix, Health Calculator
│   └── oracle/                # Multi-feed Oracle Relay (Pyth/Chainlink) and Volatility Circuit Breaker
├── test/
│   ├── invariants/            # Stateful property-based fuzz invariant tests (Conservation of Collateral)
│   ├── mocks/                 # Mock ERC-20 tokens, ERC-4626 yield vaults, and test doubles
│   └── unit/                  # Meticulous unit test suites (Math, Pool, Vault, OrderBook, Liquidation, Clearinghouse)
├── engine/                    # High-performance C++20 matching and risk simulation engine
│   ├── include/               # C++ headers (types, orderbook, portfolio_margin, clamm_kernel)
│   ├── src/                   # C++ implementations and 24M op/s benchmark suite
│   └── CMakeLists.txt         # C++20 build configuration
├── sim/                       # Python quantitative risk engine and Monte Carlo jump-diffusion simulator
│   ├── portfolio_var.py       # Parametric VaR, Expected Shortfall, and SPAN margin
│   ├── monte_carlo.py         # Multi-asset jump-diffusion stress tester
│   ├── liquidation_dynamics.py# Dutch auction decay and MEV profit dynamics
│   ├── clamm_simulator.py     # Concentrated liquidity capital efficiency modeling
│   ├── backtester.py          # Unified risk simulation runner
│   └── tests/                 # Python unittest suite
├── sdk/                       # Production TypeScript client SDK and autonomous keeper bots
│   ├── src/                   # Client, EIP-712 order signer, liquidation keeper, oracle keeper
│   ├── test/                  # Node.js native test runner test suite
│   ├── package.json           # SDK dependencies
│   └── tsconfig.json          # TypeScript compiler configuration
├── docs/                      # Technical specifications and mathematical derivations
│   ├── ARCHITECTURE.md        # Complete system architecture and layer specifications
│   ├── PORTFOLIO_MARGIN.md    # Mathematical derivations of on-chain SPAN covariance margin
│   ├── CLAMM_DERIVATIONS.md   # Concentrated liquidity tick math and Hensel lifting proofs
│   └── LIQUIDATION_AUCTIONS.md# Dutch auction mechanics and auto-deleveraging protocols
├── scripts/
│   └── audit_zero_em_dash.py  # Zero-tolerance em dash compliance auditor
└── foundry.toml               # Foundry configuration (Solc 0.8.27, via_ir = true, optimizer_runs = 200)
```

---

## Quickstart & Verification Guide

### Prerequisites
- [Foundry](https://getfoundry.sh/) (`forge`, `cast`)
- Python 3.10+ with `numpy` and `scipy`
- Clang / GCC supporting C++20
- Node.js 20+

### 1. Build & Run Solidity Contracts (Foundry)
```bash
# Compile contracts with via-ir
forge build

# Execute all 41 unit and invariant tests
forge test -vv
```

### 2. Build & Benchmark C++20 Matching Engine
```bash
# Compile with C++20 -O3 optimizations
clang++ -std=c++20 -O3 -Iengine/include \
  engine/src/orderbook.cpp \
  engine/src/portfolio_margin.cpp \
  engine/src/clamm_kernel.cpp \
  engine/src/matching_engine.cpp \
  engine/src/benchmark.cpp \
  -o engine/valence_benchmark

# Run 100,000 order throughput benchmark
./engine/valence_benchmark
```

### 3. Run Python Quantitative Risk Simulation
```bash
# Run end-to-end Monte Carlo stress tests and SPAN VaR evaluation
PYTHONPATH=. python3 sim/backtester.py

# Run simulation unit tests
PYTHONPATH=. python3 -m unittest discover -s sim/tests
```

### 4. Build & Test TypeScript SDK
```bash
cd sdk
npm install
npm run build
npm test
cd ..
```

### 5. Run Zero Em Dash Compliance Audit
```bash
python3 scripts/audit_zero_em_dash.py .
```

---

## Invariant Fuzz Testing Properties

Valence uses stateful property-based invariant testing in Foundry (`ValenceInvariants.t.sol`) with randomized actor action handlers:
1. **Collateral Conservation**: The physical ERC-20 token balance held in `ValenceVault` equals the exact sum of internal subaccount ledger balances at all times.
2. **Deposit Risk Cap Invariant**: Total deposits for any whitelisted asset never exceed administrative risk limits under arbitrary fuzz sequences.
3. **Solvency Monotonicity**: An account with zero debt and positive haircut collateral cannot be liquidated.

---

## Documentation

- [Architecture Specification](docs/ARCHITECTURE.md)
- [SPAN Portfolio Margin Derivations](docs/PORTFOLIO_MARGIN.md)
- [CLAMM Mathematical Derivations](docs/CLAMM_DERIVATIONS.md)
- [Dutch Auction Liquidation Specification](docs/LIQUIDATION_AUCTIONS.md)

---

## License

This project is licensed under the MIT License.
