// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ValenceVault} from "../../src/core/ValenceVault.sol";
import {ValenceAccount} from "../../src/core/ValenceAccount.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IValencePortfolioMargin} from "../../src/interfaces/IValencePortfolioMargin.sol";

contract MockInsolventPortfolioMargin is IValencePortfolioMargin {
    bool public shouldPassSolvency = true;

    function setSolvency(bool pass) external {
        shouldPassSolvency = pass;
    }

    function checkSolvency(bytes32) external view override returns (bool) {
        return shouldPassSolvency;
    }

    function evaluateAccountRisk(bytes32) external pure override returns (AccountRiskProfile memory) {
        return AccountRiskProfile({
            totalCollateralValueUsd: 0,
            totalUnrealizedPnlUsd: 0,
            initialMarginRequiredUsd: 0,
            maintenanceMarginUsd: 0,
            healthFactor: 0,
            isSolvent: false,
            isLiquidatable: true
        });
    }

    function getMaintenanceMarginRequirement(bytes32) external pure override returns (uint256) {
        return 0;
    }

    function getInitialMarginRequirement(bytes32) external pure override returns (uint256) {
        return 0;
    }

    function computeHypotheticalRisk(bytes32, bytes32, int256)
        external
        pure
        override
        returns (AccountRiskProfile memory)
    {
        return AccountRiskProfile({
            totalCollateralValueUsd: 0,
            totalUnrealizedPnlUsd: 0,
            initialMarginRequiredUsd: 0,
            maintenanceMarginUsd: 0,
            healthFactor: 0,
            isSolvent: false,
            isLiquidatable: true
        });
    }
}

contract ValenceVaultTest is Test {
    ValenceAccount internal account;
    ValenceVault internal vault;
    MockERC20 internal usdc;
    MockERC20 internal wbtc;
    MockInsolventPortfolioMargin internal margin;

    address internal user1 = address(0x1111);
    address internal user2 = address(0x2222);
    address internal clearinghouse = address(0x3333);

    bytes32 internal subaccount1;
    bytes32 internal subaccount2;

    function setUp() public {
        account = new ValenceAccount();
        vault = new ValenceVault(address(account));
        margin = new MockInsolventPortfolioMargin();

        vault.setClearinghouse(clearinghouse);
        vault.setPortfolioMargin(address(margin));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);

        // Whitelist USDC: 0% haircut, 1M cap
        vault.whitelistAsset(address(usdc), false, 1, 0, 1_000_000e6);
        // Whitelist WBTC: 15% haircut (1500 bps), 500 cap
        vault.whitelistAsset(address(wbtc), false, 2, 1500, 500e8);

        vm.prank(user1);
        subaccount1 = account.createSubaccount(1);

        vm.prank(user2);
        subaccount2 = account.createSubaccount(1);

        usdc.mint(user1, 100_000e6);
        wbtc.mint(user1, 10e8);
    }

    function test_Vault_DepositAndWithdraw() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 10_000e6);
        vault.deposit(subaccount1, address(usdc), 10_000e6);
        vm.stopPrank();

        assertEq(vault.getCollateralBalance(subaccount1, address(usdc)), 10_000e6);
        assertEq(usdc.balanceOf(address(vault)), 10_000e6);

        // Withdraw half
        vm.prank(user1);
        vault.withdraw(subaccount1, address(usdc), 5_000e6, user1);

        assertEq(vault.getCollateralBalance(subaccount1, address(usdc)), 5_000e6);
        assertEq(usdc.balanceOf(user1), 95_000e6);
    }

    function test_Vault_RevertUnauthorizedWithdrawal() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 10_000e6);
        vault.deposit(subaccount1, address(usdc), 10_000e6);
        vm.stopPrank();

        // user2 attempts to withdraw from subaccount1
        vm.prank(user2);
        vm.expectRevert(ValenceVault.ValenceVault__Unauthorized.selector);
        vault.withdraw(subaccount1, address(usdc), 1_000e6, user2);
    }

    function test_Vault_DepositCapExceeded() public {
        usdc.mint(user1, 2_000_000e6);
        vm.startPrank(user1);
        usdc.approve(address(vault), 2_000_000e6);
        vm.expectRevert(ValenceVault.ValenceVault__DepositCapExceeded.selector);
        vault.deposit(subaccount1, address(usdc), 1_000_001e6);
        vm.stopPrank();
    }

    function test_Vault_HaircutCollateralValuation() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 10_000e6);
        vault.deposit(subaccount1, address(usdc), 10_000e6);
        vm.stopPrank();

        (uint256 totalVal, uint256 haircutVal) = vault.getSubaccountCollateralValue(subaccount1);
        // Default oracle price is 1 << 96 ($1.00)
        assertEq(totalVal, 10_000e18);
        assertEq(haircutVal, 10_000e18);
    }

    function test_Vault_WithdrawalViolatesMargin() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 10_000e6);
        vault.deposit(subaccount1, address(usdc), 10_000e6);
        vm.stopPrank();

        // Set margin mock to fail solvency
        margin.setSolvency(false);

        vm.prank(user1);
        vm.expectRevert(ValenceVault.ValenceVault__WithdrawalViolatesMargin.selector);
        vault.withdraw(subaccount1, address(usdc), 1_000e6, user1);
    }

    function test_Vault_InternalTransferClearinghouse() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 10_000e6);
        vault.deposit(subaccount1, address(usdc), 10_000e6);
        vm.stopPrank();

        // Non-clearinghouse caller reverts
        vm.prank(user1);
        vm.expectRevert(ValenceVault.ValenceVault__Unauthorized.selector);
        vault.transferInternal(subaccount1, subaccount2, address(usdc), 3_000e6);

        // Clearinghouse caller succeeds
        vm.prank(clearinghouse);
        vault.transferInternal(subaccount1, subaccount2, address(usdc), 3_000e6);

        assertEq(vault.getCollateralBalance(subaccount1, address(usdc)), 7_000e6);
        assertEq(vault.getCollateralBalance(subaccount2, address(usdc)), 3_000e6);
    }
}
