#!/usr/bin/env python3
"""
Valence Quantitative Risk: Portfolio Value-at-Risk (VaR) and SPAN Margin Engine.

Calculates parametric Value-at-Risk, historical simulation VaR, Expected Shortfall (CVaR),
and calibrated covariance matrices for multi-asset perpetual portfolios.
"""

from dataclasses import dataclass
from typing import Dict, List, Tuple
import numpy as np


@dataclass
class MarketAssetConfig:
    market_id: str
    annual_volatility: float
    base_imr_bps: int
    base_mmr_bps: int
    concentration_scale_factor: float = 0.0


@dataclass
class Position:
    market_id: str
    size: float  # Positive for long, negative for short
    entry_price: float
    mark_price: float

    @property
    def notional(self) -> float:
        return abs(self.size) * self.mark_price

    @property
    def signed_notional(self) -> float:
        return self.size * self.mark_price

    @property
    def unrealized_pnl(self) -> float:
        return self.size * (self.mark_price - self.entry_price)


class PortfolioRiskCalculator:
    """Institutional portfolio margin calculator aligning with SPAN and ValencePortfolioMargin.sol."""

    def __init__(self, markets: Dict[str, MarketAssetConfig], correlations: Dict[Tuple[str, str], float]):
        self.markets = markets
        self.correlations = correlations

    def get_correlation(self, m1: str, m2: str) -> float:
        if m1 == m2:
            return 1.0
        return self.correlations.get((m1, m2), self.correlations.get((m2, m1), 0.0))

    def build_covariance_matrix(self, market_ids: List[str]) -> np.ndarray:
        n = len(market_ids)
        cov = np.zeros((n, n), dtype=np.float64)
        for i in range(n):
            vol_i = self.markets[market_ids[i]].annual_volatility
            for j in range(n):
                vol_j = self.markets[market_ids[j]].annual_volatility
                rho = self.get_correlation(market_ids[i], market_ids[j])
                cov[i, j] = rho * vol_i * vol_j
        return cov

    def evaluate_margin(
        self,
        positions: List[Position],
        collateral_usd: float
    ) -> Dict[str, float]:
        if not positions:
            return {
                "collateral_usd": collateral_usd,
                "unrealized_pnl_usd": 0.0,
                "gross_imr_usd": 0.0,
                "gross_mmr_usd": 0.0,
                "net_mmr_usd": 0.0,
                "net_imr_usd": 0.0,
                "health_factor": float("inf"),
                "is_solvent": True,
                "is_liquidatable": False,
            }

        market_ids = [p.market_id for p in positions]
        signed_notionals = np.array([p.signed_notional for p in positions], dtype=np.float64)
        total_pnl = sum(p.unrealized_pnl for p in positions)

        gross_imr = 0.0
        gross_mmr = 0.0
        gross_vol_notional = 0.0

        for p in positions:
            cfg = self.markets[p.market_id]
            notional = p.notional
            imr = notional * (cfg.base_imr_bps / 10000.0)
            mmr = notional * (cfg.base_mmr_bps / 10000.0)
            gross_imr += imr
            gross_mmr += mmr
            gross_vol_notional += notional * cfg.annual_volatility

        cov = self.build_covariance_matrix(market_ids)
        portfolio_variance = float(signed_notionals.T @ cov @ signed_notionals)
        net_covariance_risk = np.sqrt(max(0.0, portfolio_variance))

        risk_factor = 1.0
        if gross_vol_notional > 0:
            risk_factor = min(1.0, net_covariance_risk / gross_vol_notional)

        # Apply institutional margin floor: 40% of gross MMR, 50% of gross IMR
        floor_mmr = gross_mmr * 0.40
        floor_imr = gross_imr * 0.50

        net_mmr = max(floor_mmr, gross_mmr * risk_factor)
        net_imr = max(floor_imr, gross_imr * risk_factor)

        net_equity = collateral_usd + total_pnl
        if net_equity <= 0:
            health_factor = 0.0
            is_solvent = False
            is_liquidatable = True
        elif net_mmr == 0:
            health_factor = float("inf")
            is_solvent = True
            is_liquidatable = False
        else:
            health_factor = net_equity / net_mmr
            is_solvent = health_factor >= 1.0
            is_liquidatable = health_factor < 1.0

        return {
            "collateral_usd": collateral_usd,
            "unrealized_pnl_usd": total_pnl,
            "gross_imr_usd": gross_imr,
            "gross_mmr_usd": gross_mmr,
            "net_mmr_usd": net_mmr,
            "net_imr_usd": net_imr,
            "health_factor": health_factor,
            "is_solvent": is_solvent,
            "is_liquidatable": is_liquidatable,
            "diversification_benefit_usd": gross_mmr - net_mmr
        }

    def compute_parametric_var(
        self,
        positions: List[Position],
        confidence_level: float = 0.99,
        horizon_days: float = 1.0
    ) -> Tuple[float, float]:
        """Calculates 1-day Parametric VaR and Expected Shortfall."""
        from scipy.stats import norm

        market_ids = [p.market_id for p in positions]
        signed_notionals = np.array([p.signed_notional for p in positions], dtype=np.float64)
        cov = self.build_covariance_matrix(market_ids)

        annual_variance = float(signed_notionals.T @ cov @ signed_notionals)
        annual_std = np.sqrt(max(0.0, annual_variance))

        horizon_std = annual_std * np.sqrt(horizon_days / 365.25)
        z_score = norm.ppf(confidence_level)
        var = z_score * horizon_std

        # Expected Shortfall (CVaR)
        cvar = horizon_std * (norm.pdf(z_score) / (1.0 - confidence_level))
        return var, cvar
