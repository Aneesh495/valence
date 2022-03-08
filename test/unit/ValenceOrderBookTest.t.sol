// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ValenceOrderBook} from "../../src/orderbook/ValenceOrderBook.sol";
import {ValenceAccount} from "../../src/core/ValenceAccount.sol";
import {IValenceOrderBook} from "../../src/interfaces/IValenceOrderBook.sol";

contract ValenceOrderBookTest is Test {
    ValenceAccount internal account;
    ValenceOrderBook internal orderBook;

    address internal trader1 = address(0x1111);
    address internal trader2 = address(0x2222);

    bytes32 internal subaccount1;
    bytes32 internal subaccount2;
    bytes32 internal btcMarket = keccak256("BTC-PERP");

    function setUp() public {
        account = new ValenceAccount();
        orderBook = new ValenceOrderBook(address(account));

        vm.prank(trader1);
        subaccount1 = account.createSubaccount(1);

        vm.prank(trader2);
        subaccount2 = account.createSubaccount(1);
    }

    function test_OrderBook_PlaceAndRestLimitOrder() public {
        // Trader 1 places limit BUY at $60,000 (60000 << 96) for 1 BTC
        vm.prank(trader1);
        bytes32 buyId = orderBook.placeOrder(
            subaccount1,
            btcMarket,
            IValenceOrderBook.OrderSide.BUY,
            IValenceOrderBook.OrderType.LIMIT,
            60000 << 96,
            1e18
        );

        assertEq(orderBook.getBestBid(btcMarket), 60000 << 96);
        assertEq(orderBook.getBestAsk(btcMarket), 0);

        IValenceOrderBook.Order memory o = orderBook.getOrder(buyId);
        assertTrue(o.isActive);
        assertEq(o.originalQuantity, 1e18);
        assertEq(o.filledQuantity, 0);

        // Trader 2 places limit SELL at $61,000 (61000 << 96) for 2 BTC
        vm.prank(trader2);
        bytes32 sellId = orderBook.placeOrder(
            subaccount2,
            btcMarket,
            IValenceOrderBook.OrderSide.SELL,
            IValenceOrderBook.OrderType.LIMIT,
            61000 << 96,
            2e18
        );

        assertEq(orderBook.getBestAsk(btcMarket), 61000 << 96);
        IValenceOrderBook.Order memory s = orderBook.getOrder(sellId);
        assertTrue(s.isActive);
    }

    function test_OrderBook_CrossingMatch() public {
        // Trader 2 rests SELL at $60,000 for 1.5 BTC
        vm.prank(trader2);
        bytes32 sellId = orderBook.placeOrder(
            subaccount2,
            btcMarket,
            IValenceOrderBook.OrderSide.SELL,
            IValenceOrderBook.OrderType.LIMIT,
            60000 << 96,
            15e17 // 1.5 BTC
        );

        assertEq(orderBook.getBestAsk(btcMarket), 60000 << 96);

        // Trader 1 places crossing BUY at $60,000 for 1.0 BTC
        vm.prank(trader1);
        bytes32 buyId = orderBook.placeOrder(
            subaccount1,
            btcMarket,
            IValenceOrderBook.OrderSide.BUY,
            IValenceOrderBook.OrderType.LIMIT,
            60000 << 96,
            1e18
        );

        // Trader 1 order completely filled (not active)
        IValenceOrderBook.Order memory buyOrder = orderBook.getOrder(buyId);
        assertFalse(buyOrder.isActive);
        assertEq(buyOrder.filledQuantity, 1e18);

        // Trader 2 order partially filled (0.5 BTC remaining active)
        IValenceOrderBook.Order memory sellOrder = orderBook.getOrder(sellId);
        assertTrue(sellOrder.isActive);
        assertEq(sellOrder.filledQuantity, 1e18);
        assertEq(orderBook.getBestAsk(btcMarket), 60000 << 96);
    }

    function test_OrderBook_PostOnlyRevert() public {
        // Trader 2 rests SELL at $60,000
        vm.prank(trader2);
        orderBook.placeOrder(
            subaccount2,
            btcMarket,
            IValenceOrderBook.OrderSide.SELL,
            IValenceOrderBook.OrderType.LIMIT,
            60000 << 96,
            1e18
        );

        // Trader 1 attempts POST_ONLY BUY at $60,000 (crosses ask) -> reverts
        vm.prank(trader1);
        vm.expectRevert(ValenceOrderBook.ValenceOrderBook__PostOnlyCrossesBook.selector);
        orderBook.placeOrder(
            subaccount1,
            btcMarket,
            IValenceOrderBook.OrderSide.BUY,
            IValenceOrderBook.OrderType.POST_ONLY,
            60000 << 96,
            1e18
        );
    }

    function test_OrderBook_CancelOrder() public {
        // Trader 1 places limit BUY
        vm.prank(trader1);
        bytes32 orderId = orderBook.placeOrder(
            subaccount1,
            btcMarket,
            IValenceOrderBook.OrderSide.BUY,
            IValenceOrderBook.OrderType.LIMIT,
            59000 << 96,
            1e18
        );

        assertEq(orderBook.getBestBid(btcMarket), 59000 << 96);

        // Trader 1 cancels order
        vm.prank(trader1);
        orderBook.cancelOrder(orderId);

        assertEq(orderBook.getBestBid(btcMarket), 0);
        IValenceOrderBook.Order memory order = orderBook.getOrder(orderId);
        assertFalse(order.isActive);
    }

    function test_OrderBook_FIFOExecutionPriority() public {
        // Trader 1 places BUY order A at $50,000 for 1 BTC
        vm.prank(trader1);
        bytes32 orderA = orderBook.placeOrder(
            subaccount1,
            btcMarket,
            IValenceOrderBook.OrderSide.BUY,
            IValenceOrderBook.OrderType.LIMIT,
            50000 << 96,
            1e18
        );

        // Trader 1 places BUY order B at $50,000 for 1 BTC (behind A in FIFO queue)
        vm.prank(trader1);
        bytes32 orderB = orderBook.placeOrder(
            subaccount1,
            btcMarket,
            IValenceOrderBook.OrderSide.BUY,
            IValenceOrderBook.OrderType.LIMIT,
            50000 << 96,
            1e18
        );

        // Trader 2 places SELL for 1 BTC at $50,000
        vm.prank(trader2);
        orderBook.placeOrder(
            subaccount2,
            btcMarket,
            IValenceOrderBook.OrderSide.SELL,
            IValenceOrderBook.OrderType.LIMIT,
            50000 << 96,
            1e18
        );

        // Order A should be fully filled and inactive; Order B should still be untouched
        IValenceOrderBook.Order memory a = orderBook.getOrder(orderA);
        IValenceOrderBook.Order memory b = orderBook.getOrder(orderB);

        assertEq(a.filledQuantity, 1e18);
        assertFalse(a.isActive);

        assertEq(b.filledQuantity, 0);
        assertTrue(b.isActive);
    }
}
