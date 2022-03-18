// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ValenceVault} from "../../src/core/ValenceVault.sol";
import {ValenceAccount} from "../../src/core/ValenceAccount.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ValenceHandler} from "./ValenceHandler.sol";

contract ValenceInvariantsTest is Test {
    ValenceAccount internal account;
    ValenceVault internal vault;
    MockERC20 internal usdc;
    ValenceHandler internal handler;

    uint256 internal constant MAX_CAP = 100_000_000e6;

    function setUp() public {
        account = new ValenceAccount();
        vault = new ValenceVault(address(account));
        usdc = new MockERC20("USD Coin", "USDC", 6);

        vault.whitelistAsset(address(usdc), false, 1, 0, MAX_CAP);

        handler = new ValenceHandler(address(vault), address(account), address(usdc));

        // Target handler for fuzz invariant generation
        targetContract(address(handler));
    }

    /// @notice Invariant: Physical token balance held by vault equals total tracked deposits.
    function invariant_CollateralConservation() public view {
        assertEq(usdc.balanceOf(address(vault)), handler.totalGhostDeposits());
    }

    /// @notice Invariant: Internal vault deposit registry matches physical deposits exactly.
    function invariant_SumOfSubaccountBalances() public view {
        ValenceVault.AssetConfig memory cfg = vault.getAssetConfig(address(usdc));
        assertEq(cfg.totalDeposited, handler.totalGhostDeposits());
    }

    /// @notice Invariant: Total deposited never exceeds the administrative risk cap.
    function invariant_DepositCapNeverExceeded() public view {
        ValenceVault.AssetConfig memory cfg = vault.getAssetConfig(address(usdc));
        assertTrue(cfg.totalDeposited <= MAX_CAP);
    }
}
