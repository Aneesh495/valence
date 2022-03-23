#!/usr/bin/env python3
"""
Valence Quantitative Simulation: End-to-End Stress Test and Risk Engine Benchmark.

Integrates Portfolio VaR, Monte Carlo Jump-Diffusion, and Dutch Auction Dynamics
into an automated institutional risk report.
"""

import sys
import numpy as np
from portfolio_var import PortfolioRiskCalculator, MarketAssetConfig, Position
from monte_carlo import MultiAssetSimulator, SimulationConfig
from liquidation_dynamics import LiquidationAuctionSimulator, DutchAuctionParameters


def run_full_risk_benchmark():
    print("==================================================")
    print("   VALENCE QUANTITATIVE RISK & SIMULATION SUITE   ")
    print("==================================================")

    # 1. Setup Market Configurations
    markets = {
        "BTC-PERP": MarketAssetConfig(
            market_id="BTC-PERP",
            annual_volatility=0.50,
            base_imr_bps=1000,
            base_mmr_bps=500
        ),
        "ETH-PERP": MarketAssetConfig(
            market_id="ETH-PERP",
            annual_volatility=0.60,
            base_imr_bps=1000,
            base_mmr_bps=500
        ),
        "SOL-PERP": MarketAssetConfig(
            market_id="SOL-PERP",
            annual_volatility=0.85,
            base_imr_bps=1500,
            base_mmr_bps=750
        )
    }

    # Pairwise correlations
    correlations = {
        ("BTC-PERP", "ETH-PERP"): 0.85,
        ("BTC-PERP", "SOL-PERP"): 0.70,
        ("ETH-PERP", "SOL-PERP"): 0.75,
    }

    calculator = PortfolioRiskCalculator(markets, correlations)

    # 2. Portfolio Margin Evaluation (Hedged BTC vs ETH position)
    positions = [
        Position("BTC-PERP", size=1.0, entry_price=60000.0, mark_price=60000.0),   # Long $60k BTC
        Position("ETH-PERP", size=-20.0, entry_price=3000.0, mark_price=3000.0),   # Short $60k ETH
    ]

    margin_eval = calculator.evaluate_margin(positions, collateral_usd=20000.0)
    var_99, cvar_99 = calculator.compute_parametric_var(positions, confidence_level=0.99, horizon_days=1.0)

    print("\n[PORTFOLIO MARGIN EVALUATION]")
    print(f"Gross Maintenance Margin : ${margin_eval['gross_mmr_usd']:,.2f}")
    print(f"Net Portfolio Margin     : ${margin_eval['net_mmr_usd']:,.2f}")
    print(f"Diversification Offset   : ${margin_eval['diversification_benefit_usd']:,.2f}")
    print(f"Account Health Factor    : {margin_eval['health_factor']:.2f}x")
    print(f"1-Day 99% Parametric VaR : ${var_99:,.2f}")
    print(f"1-Day 99% Expected Short : ${cvar_99:,.2f}")

    assert margin_eval["is_solvent"]
    assert margin_eval["net_mmr_usd"] < margin_eval["gross_mmr_usd"]

    # 3. Monte Carlo Jump-Diffusion Stress Testing
    print("\n[MONTE CARLO JUMP-DIFFUSION STRESS TEST]")
    corr_matrix = np.array([
        [1.00, 0.85, 0.70],
        [0.85, 1.00, 0.75],
        [0.70, 0.75, 1.00]
    ])

    sim_config = SimulationConfig(num_paths=1000, num_steps=288, jump_intensity=3.0)
    mc_sim = MultiAssetSimulator(
        asset_names=["BTC-PERP", "ETH-PERP", "SOL-PERP"],
        initial_prices={"BTC-PERP": 60000.0, "ETH-PERP": 3000.0, "SOL-PERP": 150.0},
        annual_volatilities={"BTC-PERP": 0.50, "ETH-PERP": 0.60, "SOL-PERP": 0.85},
        correlation_matrix=corr_matrix,
        config=sim_config
    )

    stress_res = mc_sim.run_stress_test(
        portfolio_positions={"BTC-PERP": 1.0, "ETH-PERP": -20.0},
        collateral_usd=20000.0
    )

    print(f"Insolvency Probability   : {stress_res['insolvency_probability'] * 100:.2f}%")
    print(f"Max Simulated Loss       : ${stress_res['max_simulated_loss_usd']:,.2f}")
    print(f"Median Terminal Equity   : ${stress_res['median_terminal_equity_usd']:,.2f}")
    print(f"5th Percentile Equity    : ${stress_res['fifth_percentile_equity_usd']:,.2f}")

    # 4. Dutch Auction Liquidation Simulation
    print("\n[DUTCH AUCTION LIQUIDATION SIMULATION]")
    auction_params = DutchAuctionParameters(
        debt_to_cover_usd=5000.0,
        collateral_available_usd=6000.0,
        duration_seconds=300
    )
    liq_sim = LiquidationAuctionSimulator(auction_params)
    arrival = liq_sim.simulate_liquidator_arrival(target_roi_bps=200, gas_cost_usd=12.0)

    print(f"Competitive Liquidator T : {arrival['elapsed_seconds']:.1f}s")
    print(f"Clearing Discount Rate   : {arrival['discount_bps']:.1f} bps ({arrival['discount_bps']/100:.2f}%)")
    print(f"Liquidator Net Profit    : ${arrival['net_profit_usd']:,.2f}")
    print(f"Liquidator Realized ROI  : {arrival['roi_percentage']:.2f}%")

    print("\n==================================================")
    print("   ALL QUANTITATIVE SIMULATION CHECKS PASSED!    ")
    print("==================================================")


if __name__ == "__main__":
    run_full_risk_benchmark()
