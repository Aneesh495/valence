// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ValencePoolFactory} from "../../src/clamm/ValencePoolFactory.sol";
import {ValencePool, IValenceMintCallback, IValenceSwapCallback} from "../../src/clamm/ValencePool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {TickMath} from "../../src/libraries/TickMath.sol";

contract PoolCaller is IValenceMintCallback, IValenceSwapCallback {
    function valenceMintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external override {
        (address t0, address t1) = abi.decode(data, (address, address));
        if (amount0Owed > 0) MockERC20(t0).transfer(msg.sender, amount0Owed);
        if (amount1Owed > 0) MockERC20(t1).transfer(msg.sender, amount1Owed);
    }

    function valenceSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        (address t0, address t1) = abi.decode(data, (address, address));
        if (amount0Delta > 0) MockERC20(t0).transfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) MockERC20(t1).transfer(msg.sender, uint256(amount1Delta));
    }
}

contract ValencePoolTest is Test {
    ValencePoolFactory internal factory;
    ValencePool internal pool;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal token0;
    MockERC20 internal token1;
    PoolCaller internal caller;

    uint24 internal constant FEE = 3000; // 0.30%
    int24 internal constant TICK_SPACING = 60;

    function setUp() public {
        factory = new ValencePoolFactory();
        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);

        caller = new PoolCaller();

        address poolAddr = factory.createPool(address(tokenA), address(tokenB), FEE);
        pool = ValencePool(poolAddr);

        token0 = MockERC20(pool.token0());
        token1 = MockERC20(pool.token1());

        // Mint initial tokens to test runner and caller
        token0.mint(address(this), 1000000e18);
        token1.mint(address(this), 1000000e18);
        token0.mint(address(caller), 1000000e18);
        token1.mint(address(caller), 1000000e18);
    }

    function test_Pool_Initialization() public {
        uint160 sqrtP96 = 1 << 96; // Price = 1.0
        pool.initialize(sqrtP96);

        (uint160 currentSqrtP, int24 currentTick,,,,,) = pool.slot0();
        assertEq(currentSqrtP, sqrtP96);
        assertEq(currentTick, 0);
    }

    function test_Pool_MintAndBurn() public {
        uint160 sqrtP96 = 1 << 96;
        pool.initialize(sqrtP96);

        int24 tickLower = -120;
        int24 tickUpper = 120;
        uint128 liquidityAmount = 1000e18;

        // Mint through caller contract
        bytes memory data = abi.encode(address(token0), address(token1));
        vm.prank(address(caller));
        (uint256 amount0, uint256 amount1) = pool.mint(
            address(caller),
            tickLower,
            tickUpper,
            liquidityAmount,
            data
        );

        assertTrue(amount0 > 0);
        assertTrue(amount1 > 0);
        assertEq(pool.liquidity(), liquidityAmount);

        // Burn half
        vm.prank(address(caller));
        (uint256 burn0, uint256 burn1) = pool.burn(tickLower, tickUpper, liquidityAmount / 2);
        assertTrue(burn0 > 0);
        assertTrue(burn1 > 0);
        assertEq(pool.liquidity(), liquidityAmount / 2);
    }

    function test_Pool_SwapToken0ForToken1() public {
        uint160 sqrtP96 = 1 << 96;
        pool.initialize(sqrtP96);

        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint128 liquidityAmount = 10000e18;

        bytes memory data = abi.encode(address(token0), address(token1));
        vm.prank(address(caller));
        pool.mint(address(caller), tickLower, tickUpper, liquidityAmount, data);

        // Swap 100 token0 for token1
        int256 amountIn = 100e18;
        uint160 minSqrtLimit = 4295128740; // minimum price

        vm.prank(address(caller));
        (int256 amount0, int256 amount1) = pool.swap(
            address(caller),
            true, // zeroForOne
            amountIn,
            minSqrtLimit,
            data
        );

        assertEq(amount0, amountIn);
        assertTrue(amount1 < 0); // Negative indicates output to recipient
        assertTrue(uint256(-amount1) > 90e18); // Output close to 100 minus fees and slippage

        (uint160 postSqrtP, int24 postTick,,,,,) = pool.slot0();
        assertTrue(postSqrtP < sqrtP96); // Selling token0 drives price down
        assertTrue(postTick < 0);
    }
}
