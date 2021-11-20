// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title IValenceLiquidationEngine
/// @notice Interface for Dutch auction soft liquidations and auto-deleveraging (ADL).
interface IValenceLiquidationEngine {
    event LiquidationAuctionStarted(
        bytes32 indexed auctionId,
        bytes32 indexed subaccountId,
        uint256 debtToCoverUsd,
        uint256 startTime,
        uint256 duration
    );

    event LiquidationAuctionFilled(
        bytes32 indexed auctionId,
        address indexed liquidator,
        uint256 debtRepaidUsd,
        uint256 collateralAwardedUsd
    );

    event AutoDeleveraged(
        bytes32 indexed marketId,
        bytes32 indexed insolventSubaccount,
        bytes32 indexed targetSubaccount,
        uint256 sizeDeleveraged,
        uint256 settlementPrice
    );

    struct DutchAuction {
        bytes32 auctionId;
        bytes32 subaccountId;
        uint256 debtToCoverUsd;
        uint256 collateralAvailableUsd;
        uint64 startTime;
        uint64 duration;
        uint32 startDiscountBps;
        uint32 maxDiscountBps;
        bool isResolved;
    }

    function initiateLiquidation(bytes32 subaccountId) external returns (bytes32 auctionId);
    function executeLiquidationPurchase(bytes32 auctionId, uint256 debtAmountToRepay) external returns (uint256 collateralReceived);
    function getCurrentDiscount(bytes32 auctionId) external view returns (uint256 discountBps);
    function getAuction(bytes32 auctionId) external view returns (DutchAuction memory);
}
