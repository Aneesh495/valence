#!/usr/bin/env python3
"""
Unit tests for Valence quantitative risk and simulation models.
"""

import unittest
import numpy as np
from sim.portfolio_var import PortfolioRiskCalculator, MarketAssetConfig, Position
from sim.monte_carlo import MultiAssetSimulator, SimulationConfig
from sim.liquidation_dynamics import LiquidationAuctionSimulator, DutchAuctionParameters
from sim.clamm_simulator import ClammPosition, ClammPerformanceSimulator


class TestRiskModels(unittest.TestCase):

    def setUp(self):
        self.markets = {
            "BTC-PERP": MarketAssetConfig("BTC-PERP", annual_volatility=0.50, base_imr_bps=1000, base_mmr_bps=500),
            "ETH-PERP": MarketAssetConfig("ETH-PERP", annual_volatility=0.60, base_imr_bps=1000, base_mmr_bps=500)
        }
        self.correlations = {("BTC-PERP", "ETH-PERP"): 0.85}
        self.calculator = PortfolioRiskCalculator(self.markets, self.correlations)

    def test_hedged_portfolio_margin_reduction(self):
        positions = [
            Position("BTC-PERP", size=1.0, entry_price=60000.0, mark_price=60000.0),
            Position("ETH-PERP", size=-20.0, entry_price=3000.0, mark_price=3000.0),
        ]
        res = self.calculator.evaluate_margin(positions, collateral_usd=20000.0)
        self.assertTrue(res["is_solvent"])
        self.assertLess(res["net_mmr_usd"], res["gross_mmr_usd"])
        self.assertGreater(res["diversification_benefit_usd"], 0)

    def test_parametric_var_positive(self):
        positions = [
            Position("BTC-PERP", size=1.0, entry_price=60000.0, mark_price=60000.0),
        ]
        var, cvar = self.calculator.compute_parametric_var(positions, confidence_level=0.99)
        self.assertGreater(var, 0)
        self.assertGreater(cvar, var)

    def test_dutch_auction_decay(self):
        params = DutchAuctionParameters(
            debt_to_cover_usd=5000.0,
            collateral_available_usd=6000.0,
            duration_seconds=300
        )
        sim = LiquidationAuctionSimulator(params)
        d0 = sim.get_discount_bps_at_time(0)
        d150 = sim.get_discount_bps_at_time(150)
        d300 = sim.get_discount_bps_at_time(300)

        self.assertEqual(d0, 200)
        self.assertEqual(d150, 600)
        self.assertEqual(d300, 1000)

    def test_clamm_capital_efficiency(self):
        pos = ClammPosition(
            lower_price=2800.0,
            upper_price=3200.0,
            current_price=3000.0,
            deposited_usd=10000.0
        )
        self.assertGreater(pos.capital_efficiency_multiplier, 1.0)


if __name__ == "__main__":
    unittest.main()
