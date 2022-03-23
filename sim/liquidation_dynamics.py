#!/usr/bin/env python3
"""
Valence Quantitative Simulation: Dutch Auction Liquidation Dynamics and MEV Simulation.

Models continuous discount decay curves, liquidator profit margins, gas priority fees,
and insurance fund solvency under cascade liquidation scenarios.
"""

from dataclasses import dataclass
from typing import Dict, List, Tuple
import numpy as np


@dataclass
class DutchAuctionParameters:
    debt_to_cover_usd: float
    collateral_available_usd: float
    duration_seconds: int = 300
    start_discount_bps: int = 200  # 2.0%
    max_discount_bps: int = 1000   # 10.0%


class LiquidationAuctionSimulator:
    """Simulates Dutch auction pricing and liquidator bid dynamics."""

    def __init__(self, auction: DutchAuctionParameters):
        self.auction = auction

    def get_discount_bps_at_time(self, elapsed_seconds: float) -> float:
        if elapsed_seconds <= 0:
            return float(self.auction.start_discount_bps)
        if elapsed_seconds >= self.auction.duration_seconds:
            return float(self.auction.max_discount_bps)

        fraction = elapsed_seconds / self.auction.duration_seconds
        range_bps = self.auction.max_discount_bps - self.auction.start_discount_bps
        return self.auction.start_discount_bps + (range_bps * fraction)

    def calculate_liquidator_profit(
        self,
        elapsed_seconds: float,
        debt_repaid_usd: float,
        gas_cost_usd: float = 15.0,
        hedging_slippage_bps: int = 15
    ) -> Dict[str, float]:
        """Calculates net liquidator profit including discount, hedging slippage, and gas."""
        discount_bps = self.get_discount_bps_at_time(elapsed_seconds)
        discount_ratio = discount_bps / 10000.0

        # Collateral awarded = debt_repaid / (1 - discount)
        collateral_awarded_usd = min(
            self.auction.collateral_available_usd,
            debt_repaid_usd / (1.0 - discount_ratio)
        )

        gross_profit = collateral_awarded_usd - debt_repaid_usd
        hedging_cost = collateral_awarded_usd * (hedging_slippage_bps / 10000.0)
        net_profit = gross_profit - hedging_cost - gas_cost_usd

        return {
            "elapsed_seconds": elapsed_seconds,
            "discount_bps": discount_bps,
            "collateral_awarded_usd": collateral_awarded_usd,
            "gross_profit_usd": gross_profit,
            "net_profit_usd": net_profit,
            "roi_percentage": (net_profit / debt_repaid_usd) * 100.0 if debt_repaid_usd > 0 else 0.0
        }

    def simulate_liquidator_arrival(
        self,
        target_roi_bps: int = 150,
        gas_cost_usd: float = 15.0
    ) -> Dict[str, float]:
        """Finds the optimal time t where a competitive liquidator executes."""
        for t in np.linspace(0, self.auction.duration_seconds, 301):
            eval_res = self.calculate_liquidator_profit(
                t,
                self.auction.debt_to_cover_usd,
                gas_cost_usd=gas_cost_usd
            )
            roi_bps = eval_res["roi_percentage"] * 100.0
            if roi_bps >= target_roi_bps:
                return eval_res

        # Expired before meeting target ROI
        return self.calculate_liquidator_profit(
            self.auction.duration_seconds,
            self.auction.debt_to_cover_usd,
            gas_cost_usd=gas_cost_usd
        )
