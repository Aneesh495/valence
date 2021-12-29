// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IValenceOrderBook} from "../interfaces/IValenceOrderBook.sol";
import {IValenceAccount} from "../interfaces/IValenceAccount.sol";
import {RedBlackTree} from "../libraries/RedBlackTree.sol";
import {LinkedList} from "../libraries/LinkedList.sol";

/// @title ValenceOrderBook
/// @notice On-chain hybrid limit order book and matching engine with red-black trees and FIFO queues.
/// @dev Orders rest at discrete price ticks and cross against maker liquidity in O(log N) price traversal.
contract ValenceOrderBook is IValenceOrderBook {
    using RedBlackTree for RedBlackTree.Tree;
    using LinkedList for LinkedList.List;

    address public immutable owner;
    IValenceAccount public immutable accountManager;
    address public clearinghouse;

    // marketId => bid tree (sorted prices)
    mapping(bytes32 => RedBlackTree.Tree) private _bids;
    // marketId => ask tree (sorted prices)
    mapping(bytes32 => RedBlackTree.Tree) private _asks;

    // marketId => priceX96 => FIFO queue of order IDs
    mapping(bytes32 => mapping(uint256 => LinkedList.List)) private _priceQueues;

    // orderId => Order
    mapping(bytes32 => Order) private _orders;

    uint256 private _orderNonce;

    error ValenceOrderBook__Unauthorized();
    error ValenceOrderBook__ZeroAddress();
    error ValenceOrderBook__InvalidPriceOrQuantity();
    error ValenceOrderBook__PostOnlyCrossesBook();
    error ValenceOrderBook__OrderInactive();

    modifier onlyOwner() {
        if (msg.sender != owner) revert ValenceOrderBook__Unauthorized();
        _;
    }

    constructor(address _accountManager) {
        if (_accountManager == address(0)) revert ValenceOrderBook__ZeroAddress();
        owner = msg.sender;
        accountManager = IValenceAccount(_accountManager);
    }

    function setClearinghouse(address _clearinghouse) external onlyOwner {
        if (_clearinghouse == address(0)) revert ValenceOrderBook__ZeroAddress();
        clearinghouse = _clearinghouse;
    }

    /// @notice Places a new limit order into the book, crossing matching orders or resting in queue.
    function placeOrder(
        bytes32 subaccountId,
        bytes32 marketId,
        OrderSide side,
        OrderType orderType,
        uint256 priceX96,
        uint256 quantity
    ) external override returns (bytes32 orderId) {
        if (priceX96 == 0 || quantity == 0) revert ValenceOrderBook__InvalidPriceOrQuantity();

        // Verify subaccount permissions
        if (msg.sender != clearinghouse) {
            if (!accountManager.isOwnerOrDelegate(subaccountId, msg.sender, 2)) {
                revert ValenceOrderBook__Unauthorized();
            }
        }

        orderId = keccak256(abi.encodePacked(subaccountId, marketId, block.timestamp, ++_orderNonce));

        uint256 remainingQuantity = quantity;
        uint256 filled = 0;

        // Crossing match phase
        if (side == OrderSide.BUY) {
            uint256 bestAsk = _asks[marketId].first();
            if (bestAsk != 0 && priceX96 >= bestAsk && orderType == OrderType.POST_ONLY) {
                revert ValenceOrderBook__PostOnlyCrossesBook();
            }

            while (bestAsk != 0 && priceX96 >= bestAsk && remainingQuantity > 0) {
                LinkedList.List storage queue = _priceQueues[marketId][bestAsk];
                while (!queue.isEmpty() && remainingQuantity > 0) {
                    bytes32 makerOrderId = queue.head;
                    Order storage makerOrder = _orders[makerOrderId];

                    uint256 makerAvailable = makerOrder.originalQuantity - makerOrder.filledQuantity;
                    uint256 matchQty = remainingQuantity < makerAvailable ? remainingQuantity : makerAvailable;

                    makerOrder.filledQuantity += matchQty;
                    remainingQuantity -= matchQty;
                    filled += matchQty;

                    emit LimitOrderFilled(orderId, makerOrderId, bestAsk, matchQty);

                    if (makerOrder.filledQuantity == makerOrder.originalQuantity) {
                        makerOrder.isActive = false;
                        queue.popFront();
                    }
                }

                if (queue.isEmpty()) {
                    _asks[marketId].remove(bestAsk);
                    bestAsk = _asks[marketId].first();
                }
            }
        } else {
            uint256 bestBid = _bids[marketId].last();
            if (bestBid != 0 && priceX96 <= bestBid && orderType == OrderType.POST_ONLY) {
                revert ValenceOrderBook__PostOnlyCrossesBook();
            }

            while (bestBid != 0 && priceX96 <= bestBid && remainingQuantity > 0) {
                LinkedList.List storage queue = _priceQueues[marketId][bestBid];
                while (!queue.isEmpty() && remainingQuantity > 0) {
                    bytes32 makerOrderId = queue.head;
                    Order storage makerOrder = _orders[makerOrderId];

                    uint256 makerAvailable = makerOrder.originalQuantity - makerOrder.filledQuantity;
                    uint256 matchQty = remainingQuantity < makerAvailable ? remainingQuantity : makerAvailable;

                    makerOrder.filledQuantity += matchQty;
                    remainingQuantity -= matchQty;
                    filled += matchQty;

                    emit LimitOrderFilled(orderId, makerOrderId, bestBid, matchQty);

                    if (makerOrder.filledQuantity == makerOrder.originalQuantity) {
                        makerOrder.isActive = false;
                        queue.popFront();
                    }
                }

                if (queue.isEmpty()) {
                    _bids[marketId].remove(bestBid);
                    bestBid = _bids[marketId].last();
                }
            }
        }

        // Resting phase if unfilled and not IOC
        bool isActive = remainingQuantity > 0 && orderType != OrderType.IMMEDIATE_OR_CANCEL;

        _orders[orderId] = Order({
            orderId: orderId,
            subaccountId: subaccountId,
            marketId: marketId,
            side: side,
            orderType: orderType,
            priceX96: priceX96,
            originalQuantity: quantity,
            filledQuantity: filled,
            timestamp: uint64(block.timestamp),
            isActive: isActive
        });

        if (isActive) {
            if (side == OrderSide.BUY) {
                if (!_bids[marketId].exists(priceX96)) {
                    _bids[marketId].insert(priceX96);
                }
            } else {
                if (!_asks[marketId].exists(priceX96)) {
                    _asks[marketId].insert(priceX96);
                }
            }
            _priceQueues[marketId][priceX96].pushBack(orderId);
        }

        emit LimitOrderPlaced(orderId, subaccountId, marketId, side, priceX96, quantity);
    }

    /// @notice Cancels an active resting limit order.
    function cancelOrder(bytes32 orderId) external override {
        Order storage order = _orders[orderId];
        if (!order.isActive) revert ValenceOrderBook__OrderInactive();

        if (msg.sender != clearinghouse) {
            if (!accountManager.isOwnerOrDelegate(order.subaccountId, msg.sender, 4)) {
                revert ValenceOrderBook__Unauthorized();
            }
        }

        order.isActive = false;
        bytes32 marketId = order.marketId;
        uint256 priceX96 = order.priceX96;

        LinkedList.List storage queue = _priceQueues[marketId][priceX96];
        if (queue.contains(orderId)) {
            queue.remove(orderId);
        }

        if (queue.isEmpty()) {
            if (order.side == OrderSide.BUY) {
                if (_bids[marketId].exists(priceX96)) _bids[marketId].remove(priceX96);
            } else {
                if (_asks[marketId].exists(priceX96)) _asks[marketId].remove(priceX96);
            }
        }

        emit LimitOrderCancelled(orderId, order.subaccountId);
    }

    function getOrder(bytes32 orderId) external view override returns (Order memory) {
        return _orders[orderId];
    }

    function getBestBid(bytes32 marketId) external view override returns (uint256) {
        return _bids[marketId].last();
    }

    function getBestAsk(bytes32 marketId) external view override returns (uint256) {
        return _asks[marketId].first();
    }
}
