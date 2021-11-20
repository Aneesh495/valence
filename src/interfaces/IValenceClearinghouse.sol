// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title IValenceClearinghouse
/// @notice Central orchestrator for Valence margin settlement, trade clearing, and position accounting.
interface IValenceClearinghouse {
    event PositionOpened(
        bytes32 indexed subaccountId,
        bytes32 indexed marketId,
        int256 sizeDelta,
        uint256 executionPriceX96,
        uint256 feePaidUsd
    );

    event PositionClosed(
        bytes32 indexed subaccountId,
        bytes32 indexed marketId,
        int256 sizeDelta,
        int256 realizedPnlUsd,
        uint256 feePaidUsd
    );

    function executeTrade(
        bytes32 subaccountId,
        bytes32 marketId,
        int256 sizeDelta,
        uint256 acceptablePriceX96
    ) external returns (uint256 executedPriceX96, uint256 feeUsd);

    function settleFunding(bytes32 subaccountId, bytes32 marketId) external returns (int256 fundingPayment);
    function liquidateAccount(bytes32 subaccountId) external returns (bytes32 auctionId);
}
