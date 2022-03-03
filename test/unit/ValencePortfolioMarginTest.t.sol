// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ValenceAccount} from "../../src/core/ValenceAccount.sol";
import {ValenceVault} from "../../src/core/ValenceVault.sol";
import {ValenceRiskMatrix} from "../../src/margin/ValenceRiskMatrix.sol";
import {ValencePortfolioMargin} from "../../src/margin/ValencePortfolioMargin.sol";
import {ValenceOracleRelay} from "../../src/oracle/ValenceOracleRelay.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IValencePortfolioMargin} from "../../src/interfaces/IValencePortfolioMargin.sol";

contract MockPositionManager {
    IValencePortfolioMargin.PositionSummary[] private _positions;

    function setPositions(IValencePortfolioMargin.PositionSummary[] memory pos) external {
        delete _positions;
        for (uint256 i = 0; i < pos.length; i++) {
            _positions.push(pos[i]);
        }
    }

    function getSubaccountPositions(bytes32)
        external
        view
        returns (IValencePortfolioMargin.PositionSummary[] memory)
    {
        return _positions;
    }
}

contract ValencePortfolioMarginTest is Test {
    ValenceAccount internal account;
    ValenceVault internal vault;
    ValenceRiskMatrix internal riskMatrix;
    ValenceOracleRelay internal oracle;
    ValencePortfolioMargin internal margin;
    MockPositionManager internal posManager;

    MockERC20 internal usdc;
    bytes32 internal btcMarket = keccak256("BTC-PERP");
    bytes32 internal ethMarket = keccak256("ETH-PERP");
    bytes32 internal subaccountId;

    function setUp() public {
        account = new ValenceAccount();
        vault = new ValenceVault(address(account));
        oracle = new ValenceOracleRelay();
        riskMatrix = new ValenceRiskMatrix();
        margin = new ValencePortfolioMargin(address(vault), address(oracle), address(riskMatrix));
        posManager = new MockPositionManager();

        margin.setPositionManager(address(posManager));
        vault.setPortfolioMargin(address(margin));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault.whitelistAsset(address(usdc), false, 1, 0, 10000000e6); // 0% haircut on USDC

        // Configure oracle feeds: initial BTC = $60,000, initial ETH = $3,000
        oracle.configureMarketFeed(btcMarket, address(0), address(0), 60, 200, 60000 << 96);
        oracle.configureMarketFeed(ethMarket, address(0), address(0), 60, 200, 3000 << 96);

        // Configure risk tiers:
        // BTC: 5% initial margin, 2.5% maintenance margin, 50% annualized volatility
        riskMatrix.configureMarket(btcMarket, 500, 250, 0, 0.5e18, 100);
        // ETH: 5% initial margin, 2.5% maintenance margin, 60% annualized volatility
        riskMatrix.configureMarket(ethMarket, 500, 250, 0, 0.6e18, 100);

        // Set correlation BTC-ETH = 0.85 (85%)
        riskMatrix.setCorrelation(btcMarket, ethMarket, 0.85e18);

        // Create subaccount
        subaccountId = account.createSubaccount(1);

        // Deposit 10,000 USDC collateral
        usdc.mint(address(this), 10000e6);
        usdc.approve(address(vault), 10000e6);
        vault.deposit(subaccountId, address(usdc), 10000e6);
    }

    function test_Margin_SolventNoPositions() public view {
        IValencePortfolioMargin.AccountRiskProfile memory profile = margin.evaluateAccountRisk(subaccountId);

        assertEq(profile.totalCollateralValueUsd, 10000e18);
        assertEq(profile.maintenanceMarginUsd, 0);
        assertTrue(profile.isSolvent);
        assertFalse(profile.isLiquidatable);
    }

    function test_Margin_CrossAssetHedgeOffset() public {
        // Set up long 1 BTC ($60,000) and short 20 ETH ($60,000)
        IValencePortfolioMargin.PositionSummary[] memory positions = new IValencePortfolioMargin.PositionSummary[](2);
        positions[0] = IValencePortfolioMargin.PositionSummary({
            marketId: btcMarket,
            size: 1e18, // 1 BTC long
            entryPriceX96: 60000 << 96,
            unrealizedPnl: 0,
            notionalUsd: 60000e18
        });
        positions[1] = IValencePortfolioMargin.PositionSummary({
            marketId: ethMarket,
            size: -20e18, // 20 ETH short
            entryPriceX96: 3000 << 96,
            unrealizedPnl: 0,
            notionalUsd: 60000e18
        });

        posManager.setPositions(positions);

        IValencePortfolioMargin.AccountRiskProfile memory profile = margin.evaluateAccountRisk(subaccountId);

        // Gross maintenance margin without correlation offset would be:
        // BTC MMR = 60,000 * 2.5% = 1,500 USD
        // ETH MMR = 60,000 * 2.5% = 1,500 USD
        // Total Gross MMR = 3,000 USD
        // With 85% correlation between long BTC and short ETH, net covariance risk is lower
        assertTrue(profile.maintenanceMarginUsd < 3000e18);
        assertTrue(profile.isSolvent);
    }

    function test_Margin_InsolvencyDetection() public {
        // Severe loss: unrealized PnL = -12,000 USD with 10,000 USD collateral
        IValencePortfolioMargin.PositionSummary[] memory positions = new IValencePortfolioMargin.PositionSummary[](1);
        positions[0] = IValencePortfolioMargin.PositionSummary({
            marketId: btcMarket,
            size: 1e18,
            entryPriceX96: 60000 << 96,
            unrealizedPnl: -12000e18,
            notionalUsd: 48000e18
        });

        posManager.setPositions(positions);

        IValencePortfolioMargin.AccountRiskProfile memory profile = margin.evaluateAccountRisk(subaccountId);

        assertFalse(profile.isSolvent);
        assertTrue(profile.isLiquidatable);
        assertEq(profile.healthFactor, 0);
    }
}
