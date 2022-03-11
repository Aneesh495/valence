// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ValenceClearinghouse} from "../../src/core/ValenceClearinghouse.sol";
import {ValenceVault} from "../../src/core/ValenceVault.sol";
import {ValenceAccount} from "../../src/core/ValenceAccount.sol";
import {ValencePortfolioMargin} from "../../src/margin/ValencePortfolioMargin.sol";
import {ValenceRiskMatrix} from "../../src/margin/ValenceRiskMatrix.sol";
import {ValenceOracleRelay} from "../../src/oracle/ValenceOracleRelay.sol";
import {ValenceFundingEngine} from "../../src/core/ValenceFundingEngine.sol";
import {ValencePositionManager} from "../../src/core/ValencePositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {FixedPointMath} from "../../src/libraries/FixedPointMath.sol";

contract ValenceClearinghouseTest is Test {
    ValenceAccount internal account;
    ValenceVault internal vault;
    ValenceOracleRelay internal oracle;
    ValenceRiskMatrix internal riskMatrix;
    ValencePortfolioMargin internal margin;
    ValenceFundingEngine internal funding;
    ValencePositionManager internal posManager;
    ValenceClearinghouse internal clearinghouse;

    MockERC20 internal usdc;
    address internal trader = address(0x1111);
    bytes32 internal subaccountId;
    bytes32 internal btcMarket = keccak256("BTC-PERP");

    function setUp() public {
        account = new ValenceAccount();
        vault = new ValenceVault(address(account));
        oracle = new ValenceOracleRelay();
        riskMatrix = new ValenceRiskMatrix();
        funding = new ValenceFundingEngine(address(oracle));
        posManager = new ValencePositionManager(address(oracle), address(funding));
        margin = new ValencePortfolioMargin(address(vault), address(oracle), address(riskMatrix));

        clearinghouse = new ValenceClearinghouse(
            address(vault),
            address(account),
            address(margin),
            address(oracle),
            address(funding),
            address(posManager)
        );

        // Link clearinghouse authorizations
        vault.setClearinghouse(address(clearinghouse));
        vault.setPortfolioMargin(address(margin));
        posManager.setClearinghouse(address(clearinghouse));
        margin.setPositionManager(address(posManager));

        // Configure markets
        oracle.configureMarketFeed(btcMarket, address(0), address(0), 60, 200, 60000 << 96);
        riskMatrix.configureMarket(btcMarket, 1000, 500, 0, 0.5e18, 100); // 10% IMR, 5% MMR
        funding.configureMarketFunding(btcMarket, 3600, 500);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault.whitelistAsset(address(usdc), false, 1, 0, 10_000_000e6);

        // Setup trader
        vm.prank(trader);
        subaccountId = account.createSubaccount(1);

        usdc.mint(trader, 50_000e6);
        vm.startPrank(trader);
        usdc.approve(address(vault), 50_000e6);
        vault.deposit(subaccountId, address(usdc), 50_000e6);
        vm.stopPrank();
    }

    function test_Clearinghouse_ExecuteTradeLong() public {
        // Open 1 BTC long ($60,000 notional) with $50,000 collateral
        vm.prank(trader);
        (uint256 execPrice, uint256 fee) = clearinghouse.executeTrade(
            subaccountId,
            btcMarket,
            1e18, // 1 BTC long
            60000 << 96
        );

        assertEq(execPrice, 60000 << 96);
        // Fee = 60,000 * 10 bps = 60 USD (60e18)
        assertEq(fee, 60e18);

        ValencePositionManager.Position memory pos = posManager.getPosition(subaccountId, btcMarket);
        assertEq(pos.size, 1e18);
        assertEq(pos.entryPriceX96, 60000 << 96);
    }

    function test_Clearinghouse_ExecuteTradeShortAndClose() public {
        // Open 1 BTC long
        vm.prank(trader);
        clearinghouse.executeTrade(subaccountId, btcMarket, 1e18, 60000 << 96);

        // Close position with -1 BTC short
        vm.prank(trader);
        clearinghouse.executeTrade(subaccountId, btcMarket, -1e18, 60000 << 96);

        ValencePositionManager.Position memory pos = posManager.getPosition(subaccountId, btcMarket);
        assertEq(pos.size, 0);
    }

    function test_Clearinghouse_RevertSlippage() public {
        // Limit acceptable price to $59,000 (lower than $60,000 mark price for a buy)
        vm.prank(trader);
        vm.expectRevert(ValenceClearinghouse.ValenceClearinghouse__SlippageExceeded.selector);
        clearinghouse.executeTrade(subaccountId, btcMarket, 1e18, 59000 << 96);
    }

    function test_Clearinghouse_RevertUnauthorized() public {
        address attacker = address(0x9999);
        vm.prank(attacker);
        vm.expectRevert(ValenceClearinghouse.ValenceClearinghouse__Unauthorized.selector);
        clearinghouse.executeTrade(subaccountId, btcMarket, 1e18, 60000 << 96);
    }

    function test_Clearinghouse_EmergencyPause() public {
        clearinghouse.setPaused(true);

        vm.prank(trader);
        vm.expectRevert(ValenceClearinghouse.ValenceClearinghouse__Paused.selector);
        clearinghouse.executeTrade(subaccountId, btcMarket, 1e18, 60000 << 96);

        clearinghouse.setPaused(false);
        vm.prank(trader);
        (uint256 execPrice, ) = clearinghouse.executeTrade(subaccountId, btcMarket, 1e18, 60000 << 96);
        assertEq(execPrice, 60000 << 96);
    }

    function test_Clearinghouse_FundingSettlement() public {
        // Open 1 BTC long
        vm.prank(trader);
        clearinghouse.executeTrade(subaccountId, btcMarket, 1e18, 60000 << 96);

        // Advance 1 hour
        vm.warp(block.timestamp + 3600);

        // Settle funding
        int256 payment = clearinghouse.settleFunding(subaccountId, btcMarket);
        // With mark == index price, premium is 0, so payment is 0
        assertEq(payment, 0);
    }
}
