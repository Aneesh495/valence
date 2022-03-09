// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ValenceLiquidationEngine} from "../../src/liquidation/ValenceLiquidationEngine.sol";
import {IValencePortfolioMargin} from "../../src/interfaces/IValencePortfolioMargin.sol";
import {IValenceLiquidationEngine} from "../../src/interfaces/IValenceLiquidationEngine.sol";

contract MockLiquidationPortfolioMargin is IValencePortfolioMargin {
    bool public isAccountLiquidatable = false;
    uint256 public maintenanceMargin = 5000e18;
    uint256 public collateralValue = 4000e18;

    function setLiquidatable(bool val, uint256 mmr, uint256 col) external {
        isAccountLiquidatable = val;
        maintenanceMargin = mmr;
        collateralValue = col;
    }

    function evaluateAccountRisk(bytes32) external view override returns (AccountRiskProfile memory) {
        return AccountRiskProfile({
            totalCollateralValueUsd: collateralValue,
            totalUnrealizedPnlUsd: 0,
            initialMarginRequiredUsd: maintenanceMargin * 2,
            maintenanceMarginUsd: maintenanceMargin,
            healthFactor: isAccountLiquidatable ? 0.8e18 : 1.5e18,
            isSolvent: !isAccountLiquidatable,
            isLiquidatable: isAccountLiquidatable
        });
    }

    function getMaintenanceMarginRequirement(bytes32) external view override returns (uint256) {
        return maintenanceMargin;
    }

    function getInitialMarginRequirement(bytes32) external view override returns (uint256) {
        return maintenanceMargin * 2;
    }

    function checkSolvency(bytes32) external view override returns (bool) {
        return !isAccountLiquidatable;
    }

    function computeHypotheticalRisk(bytes32, bytes32, int256)
        external
        view
        override
        returns (AccountRiskProfile memory)
    {
        return AccountRiskProfile({
            totalCollateralValueUsd: collateralValue,
            totalUnrealizedPnlUsd: 0,
            initialMarginRequiredUsd: maintenanceMargin * 2,
            maintenanceMarginUsd: maintenanceMargin,
            healthFactor: isAccountLiquidatable ? 0.8e18 : 1.5e18,
            isSolvent: !isAccountLiquidatable,
            isLiquidatable: isAccountLiquidatable
        });
    }
}

contract ValenceLiquidationTest is Test {
    ValenceLiquidationEngine internal liqEngine;
    MockLiquidationPortfolioMargin internal mockMargin;

    address internal mockVault = address(0xAAAA);
    address internal mockInsuranceFund = address(0xBBBB);
    address internal liquidator = address(0xCCCC);

    bytes32 internal subaccountId = keccak256("DISTRESSED_SUBACCOUNT");

    function setUp() public {
        mockMargin = new MockLiquidationPortfolioMargin();
        liqEngine = new ValenceLiquidationEngine(
            address(mockMargin),
            mockVault,
            mockInsuranceFund
        );
    }

    function test_Liquidation_RevertSolventAccount() public {
        mockMargin.setLiquidatable(false, 5000e18, 10000e18);

        vm.expectRevert(ValenceLiquidationEngine.ValenceLiquidationEngine__AccountNotLiquidatable.selector);
        liqEngine.initiateLiquidation(subaccountId);
    }

    function test_Liquidation_InitiateDutchAuction() public {
        mockMargin.setLiquidatable(true, 5000e18, 4000e18);

        bytes32 auctionId = liqEngine.initiateLiquidation(subaccountId);
        assertTrue(auctionId != bytes32(0));

        IValenceLiquidationEngine.DutchAuction memory auction = liqEngine.getAuction(auctionId);
        assertEq(auction.debtToCoverUsd, 5000e18);
        assertEq(auction.collateralAvailableUsd, 4000e18);
        assertEq(auction.startDiscountBps, 200);
        assertEq(auction.maxDiscountBps, 1000);
        assertEq(auction.duration, 300);
        assertFalse(auction.isResolved);
    }

    function test_Liquidation_DiscountDecayOverTime() public {
        mockMargin.setLiquidatable(true, 5000e18, 4000e18);
        bytes32 auctionId = liqEngine.initiateLiquidation(subaccountId);

        uint256 start = block.timestamp;

        // At t = 0s: start discount is 200 bps (2.0%)
        assertEq(liqEngine.getCurrentDiscount(auctionId), 200);

        // At t = 150s (halfway): 200 + (800 * 150 / 300) = 600 bps (6.0%)
        vm.warp(start + 150);
        assertEq(liqEngine.getCurrentDiscount(auctionId), 600);

        // At t = 300s: max discount is 1000 bps (10.0%)
        vm.warp(start + 300);
        assertEq(liqEngine.getCurrentDiscount(auctionId), 1000);
    }

    function test_Liquidation_PartialAndFullPurchase() public {
        mockMargin.setLiquidatable(true, 5000e18, 10000e18);
        bytes32 auctionId = liqEngine.initiateLiquidation(subaccountId);

        // Liquidator purchases at t = 150s (6% discount -> awarded = debt / 0.94)
        vm.warp(block.timestamp + 150);
        vm.prank(liquidator);
        uint256 awardedPartial = liqEngine.executeLiquidationPurchase(auctionId, 2350e18);

        // 2350 * 10000 / 9400 = 2500 USD collateral
        assertEq(awardedPartial, 2500e18);

        IValenceLiquidationEngine.DutchAuction memory aucMid = liqEngine.getAuction(auctionId);
        assertFalse(aucMid.isResolved);
        assertEq(aucMid.debtToCoverUsd, 5000e18 - 2350e18);
        assertEq(aucMid.collateralAvailableUsd, 10000e18 - 2500e18);

        // Liquidator repays all remaining debt
        vm.prank(liquidator);
        liqEngine.executeLiquidationPurchase(auctionId, 2650e18);

        IValenceLiquidationEngine.DutchAuction memory aucFinal = liqEngine.getAuction(auctionId);
        assertTrue(aucFinal.isResolved);
    }

    function test_Liquidation_RevertExpired() public {
        mockMargin.setLiquidatable(true, 5000e18, 4000e18);
        bytes32 auctionId = liqEngine.initiateLiquidation(subaccountId);

        // Warp past 300s duration (301s)
        vm.warp(block.timestamp + 301);

        vm.prank(liquidator);
        vm.expectRevert(ValenceLiquidationEngine.ValenceLiquidationEngine__AuctionExpired.selector);
        liqEngine.executeLiquidationPurchase(auctionId, 1000e18);
    }
}
