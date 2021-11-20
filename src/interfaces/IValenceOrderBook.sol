// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title IValenceOrderBook
/// @notice Interface for on-chain hybrid limit order book and crossing engine.
interface IValenceOrderBook {
    enum OrderSide { BUY, SELL }
    enum OrderType { LIMIT, POST_ONLY, IMMEDIATE_OR_CANCEL }

    event LimitOrderPlaced(
        bytes32 indexed orderId,
        bytes32 indexed subaccountId,
        bytes32 indexed marketId,
        OrderSide side,
        uint256 priceX96,
        uint256 quantity
    );

    event LimitOrderCancelled(bytes32 indexed orderId, bytes32 indexed subaccountId);
    event LimitOrderFilled(
        bytes32 indexed orderId,
        bytes32 indexed matchedOrderId,
        uint256 executedPriceX96,
        uint256 executedQuantity
    );

    struct Order {
        bytes32 orderId;
        bytes32 subaccountId;
        bytes32 marketId;
        OrderSide side;
        OrderType orderType;
        uint256 priceX96;
        uint256 originalQuantity;
        uint256 filledQuantity;
        uint64 timestamp;
        bool isActive;
    }

    function placeOrder(
        bytes32 subaccountId,
        bytes32 marketId,
        OrderSide side,
        OrderType orderType,
        uint256 priceX96,
        uint256 quantity
    ) external returns (bytes32 orderId);

    function cancelOrder(bytes32 orderId) external;
    function getOrder(bytes32 orderId) external view returns (Order memory);
    function getBestBid(bytes32 marketId) external view returns (uint256 priceX96);
    function getBestAsk(bytes32 marketId) external view returns (uint256 priceX96);
}
