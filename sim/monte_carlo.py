#!/usr/bin/env python3
"""
Valence Quantitative Simulation: Correlated Multi-Asset Jump-Diffusion Simulator.

Generates realistic high-volatility price trajectories with jump processes and
evaluates clearinghouse portfolio margin solvency under extreme market dislocations.
"""

from dataclasses import dataclass
from typing import Dict, List, Tuple
import numpy as np


@dataclass
class SimulationConfig:
    num_paths: int = 1000
    num_steps: int = 288  # 5-minute intervals across 24 hours
    dt_years: float = 1.0 / (365.25 * 288)
    jump_intensity: float = 2.0  # Average jumps per year
    jump_mean: float = -0.05     # Average jump size (downside skew)
    jump_std: float = 0.10       # Jump volatility


class MultiAssetSimulator:
    """Simulates correlated geometric Brownian motion with Poisson jump diffusion."""

    def __init__(
        self,
        asset_names: List[str],
        initial_prices: Dict[str, float],
        annual_volatilities: Dict[str, float],
        correlation_matrix: np.ndarray,
        config: SimulationConfig = SimulationConfig()
    ):
        self.asset_names = asset_names
        self.initial_prices = np.array([initial_prices[a] for a in asset_names], dtype=np.float64)
        self.vols = np.array([annual_volatilities[a] for a in asset_names], dtype=np.float64)
        self.corr = correlation_matrix
        self.config = config
        self.cholesky = np.linalg.cholesky(correlation_matrix)

    def generate_paths(self) -> np.ndarray:
        """
        Generates simulated price matrix with shape (num_paths, num_steps + 1, num_assets).
        """
        k = len(self.asset_names)
        paths = np.zeros((self.config.num_paths, self.config.num_steps + 1, k), dtype=np.float64)
        paths[:, 0, :] = self.initial_prices

        dt = self.config.dt_years
        sqrt_dt = np.sqrt(dt)

        # Drift under risk-neutral / continuous funding assumptions
        drift = -0.5 * (self.vols ** 2) * dt

        for t in range(self.config.num_steps):
            # Correlated Gaussian innovations
            uncorrelated_z = np.random.standard_normal((self.config.num_paths, k))
            correlated_z = uncorrelated_z @ self.cholesky.T

            diffusion_increment = drift + (self.vols * sqrt_dt * correlated_z)

            # Poisson jump component
            num_jumps = np.random.poisson(self.config.jump_intensity * dt, size=(self.config.num_paths, 1))
            jump_sizes = np.where(
                num_jumps > 0,
                np.random.normal(self.config.jump_mean, self.config.jump_std, size=(self.config.num_paths, k)),
                0.0
            )

            paths[:, t + 1, :] = paths[:, t, :] * np.exp(diffusion_increment + jump_sizes)

        return paths

    def run_stress_test(
        self,
        portfolio_positions: Dict[str, float],
        collateral_usd: float
    ) -> Dict[str, float]:
        """Evaluates liquidation probabilities and maximum drawdown across all simulated paths."""
        paths = self.generate_paths()
        sizes = np.array([portfolio_positions.get(a, 0.0) for a in self.asset_names], dtype=np.float64)

        # Calculate portfolio value over time: (num_paths, num_steps + 1)
        # PnL = sum_i(size_i * (price_t_i - price_0_i))
        initial_values = self.initial_prices * sizes
        values = (paths * sizes).sum(axis=2) - initial_values.sum() + collateral_usd

        min_equity_per_path = values.min(axis=1)
        insolvent_paths = (min_equity_per_path <= 0).sum()
        insolvency_probability = insolvent_paths / self.config.num_paths

        max_drawdown = float(np.maximum(0.0, collateral_usd - min_equity_per_path).max())

        return {
            "insolvency_probability": float(insolvency_probability),
            "max_simulated_loss_usd": max_drawdown,
            "median_terminal_equity_usd": float(np.median(values[:, -1])),
            "fifth_percentile_equity_usd": float(np.percentile(values[:, -1], 5.0)),
        }
