// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ValenceVault} from "../../src/core/ValenceVault.sol";
import {ValenceAccount} from "../../src/core/ValenceAccount.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract ValenceHandler is Test {
    ValenceVault public vault;
    ValenceAccount public account;
    MockERC20 public usdc;

    bytes32[] public subaccounts;
    uint256 public totalGhostDeposits;

    constructor(
        address _vault,
        address _account,
        address _usdc
    ) {
        vault = ValenceVault(_vault);
        account = ValenceAccount(_account);
        usdc = MockERC20(_usdc);

        // Pre-create 3 subaccounts for testing
        for (uint256 i = 1; i <= 3; i++) {
            address user = address(uint160(0x1000 + i));
            vm.prank(user);
            bytes32 subId = account.createSubaccount(uint32(i));
            subaccounts.push(subId);
        }
    }

    function deposit(uint256 subaccountIndexSeed, uint256 amountSeed) external {
        if (subaccounts.length == 0) return;
        bytes32 subId = subaccounts[subaccountIndexSeed % subaccounts.length];
        address owner = account.getSubaccount(subId).owner;

        // Bound deposit amount between 1 USDC and 10,000 USDC
        uint256 amount = bound(amountSeed, 1e6, 10_000e6);

        ValenceVault.AssetConfig memory cfg = vault.getAssetConfig(address(usdc));
        if (cfg.totalDeposited + amount > cfg.maxDepositCap) return;

        usdc.mint(owner, amount);
        vm.startPrank(owner);
        usdc.approve(address(vault), amount);
        vault.deposit(subId, address(usdc), amount);
        vm.stopPrank();

        totalGhostDeposits += amount;
    }

    function withdraw(uint256 subaccountIndexSeed, uint256 amountSeed) external {
        if (subaccounts.length == 0) return;
        bytes32 subId = subaccounts[subaccountIndexSeed % subaccounts.length];
        address owner = account.getSubaccount(subId).owner;

        uint256 bal = vault.getCollateralBalance(subId, address(usdc));
        if (bal == 0) return;

        uint256 amount = bound(amountSeed, 1, bal);

        vm.prank(owner);
        vault.withdraw(subId, address(usdc), amount, owner);

        totalGhostDeposits -= amount;
    }

    function getSubaccountsCount() external view returns (uint256) {
        return subaccounts.length;
    }
}
