#!/usr/bin/env python3
"""
Valence Quantitative Simulation: Concentrated Liquidity AMM (CLAMM) Simulator.

Computes capital efficiency multipliers, impermanent loss curves, and tick-level
fee yield distributions for active range positions.
"""

from dataclasses import dataclass
from typing import Dict, Tuple
import numpy as np


@dataclass
class ClammPosition:
    lower_price: float
    upper_price: float
    current_price: float
    deposited_usd: float

    @property
    def capital_efficiency_multiplier(self) -> float:
        """Ratio of concentrated liquidity depth relative to full range Uni v2 curve."""
        r = np.sqrt(self.upper_price / self.lower_price)
        return 1.0 / (1.0 - (1.0 / np.sqrt(r)))


class ClammPerformanceSimulator:
    """Evaluates impermanent loss and LP returns for concentrated positions."""

    def __init__(self, position: ClammPosition):
        self.position = position

    def compute_impermanent_loss(self, future_price: float) -> float:
        """Calculates impermanent loss percentage relative to 50/50 HODL."""
        pa = self.position.lower_price
        pb = self.position.upper_price
        p0 = self.position.current_price
        p = future_price

        # Standard Uniswap v3 IL piecewise formulation
        if p <= pa:
            # Fully in token0 / base asset
            lp_val = np.sqrt(pa) * (np.sqrt(pb) - np.sqrt(pa)) * p / (np.sqrt(pb) * (np.sqrt(p0) - np.sqrt(pa)) + (np.sqrt(pb) - np.sqrt(p0)))
        elif p >= pb:
            # Fully in token1 / quote asset
            lp_val = np.sqrt(pb) * (np.sqrt(p) - np.sqrt(pa))
        else:
            # In range
            lp_val = (2 * np.sqrt(p) - np.sqrt(pa) - p / np.sqrt(pb))

        hodl_val = 0.5 * (1.0 + (p / p0))
        if hodl_val == 0:
            return 0.0
        return float((lp_val / hodl_val) - 1.0)
