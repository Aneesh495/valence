// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "../../src/libraries/FullMath.sol";
import {FixedPointMath} from "../../src/libraries/FixedPointMath.sol";
import {TickMath} from "../../src/libraries/TickMath.sol";
import {BitMath} from "../../src/libraries/BitMath.sol";
import {SafeCast} from "../../src/libraries/SafeCast.sol";
import {MatrixMath} from "../../src/libraries/MatrixMath.sol";
import {RedBlackTree} from "../../src/libraries/RedBlackTree.sol";
import {LinkedList} from "../../src/libraries/LinkedList.sol";

contract TreeWrapper {
    using RedBlackTree for RedBlackTree.Tree;
    RedBlackTree.Tree internal tree;

    function insert(uint256 key) external {
        tree.insert(key);
    }

    function remove(uint256 key) external {
        tree.remove(key);
    }

    function exists(uint256 key) external view returns (bool) {
        return tree.exists(key);
    }

    function first() external view returns (uint256) {
        return tree.first();
    }

    function last() external view returns (uint256) {
        return tree.last();
    }

    function next(uint256 key) external view returns (uint256) {
        return tree.next(key);
    }

    function prev(uint256 key) external view returns (uint256) {
        return tree.prev(key);
    }

    function count() external view returns (uint256) {
        return tree.count;
    }
}

contract ListWrapper {
    using LinkedList for LinkedList.List;
    LinkedList.List internal list;

    function pushBack(bytes32 id) external {
        list.pushBack(id);
    }

    function popFront() external returns (bytes32) {
        return list.popFront();
    }

    function remove(bytes32 id) external {
        list.remove(id);
    }

    function contains(bytes32 id) external view returns (bool) {
        return list.contains(id);
    }

    function size() external view returns (uint256) {
        return list.size;
    }
}

contract MathLibrariesTest is Test {
    using FixedPointMath for uint256;
    using FixedPointMath for int256;

    TreeWrapper internal treeWrapper;
    ListWrapper internal listWrapper;

    function setUp() public {
        treeWrapper = new TreeWrapper();
        listWrapper = new ListWrapper();
    }

    function test_FullMath_StandardMultiplication() public pure {
        uint256 a = 100e18;
        uint256 b = 2e18;
        uint256 c = 1e18;
        uint256 result = FullMath.mulDiv(a, b, c);
        assertEq(result, 200e18);
    }

    function test_FullMath_PhantomOverflow() public pure {
        // (type(uint256).max / 2) * 4 overflows 256 bits, but division by 4 fits back
        uint256 a = type(uint256).max / 2;
        uint256 b = 4;
        uint256 c = 4;
        uint256 result = FullMath.mulDiv(a, b, c);
        assertEq(result, a);
    }

    function test_FullMath_MulDivRoundingUp() public pure {
        uint256 result = FullMath.mulDivRoundingUp(10, 10, 3);
        assertEq(result, 34); // ceil(100 / 3) = 34
    }

    function test_FixedPointMath_WadArithmetic() public pure {
        uint256 x = 2e18;
        uint256 y = 3e18;
        assertEq(FixedPointMath.mulWadDown(x, y), 6e18);
        assertEq(FixedPointMath.divWadDown(6e18, 2e18), 3e18);
    }

    function test_FixedPointMath_Sqrt() public pure {
        assertEq(FixedPointMath.sqrt(0), 0);
        assertEq(FixedPointMath.sqrt(1), 1);
        assertEq(FixedPointMath.sqrt(4), 2);
        assertEq(FixedPointMath.sqrt(100), 10);
        assertEq(FixedPointMath.sqrt(144e36), 12e18);
    }

    function test_FixedPointMath_ExpAndLn() public pure {
        // e^0 = 1
        uint256 expZero = FixedPointMath.expWad(0);
        assertEq(expZero, 1e18);

        // ln(1e18) = 0
        int256 lnOne = FixedPointMath.lnWad(int256(1e18));
        assertApproxEqAbs(uint256(lnOne), 0, 1e10);

        // e^(ln(2)) ~= 2
        int256 lnTwo = 693147180559945309; // ln(2)
        uint256 expLnTwo = FixedPointMath.expWad(lnTwo);
        assertApproxEqRel(expLnTwo, 2e18, 1e14);
    }

    function test_TickMath_BoundaryTicks() public pure {
        uint160 minSqrt = TickMath.getSqrtRatioAtTick(TickMath.MIN_TICK);
        uint160 maxSqrt = TickMath.getSqrtRatioAtTick(TickMath.MAX_TICK);

        assertEq(minSqrt, TickMath.MIN_SQRT_RATIO);
        assertTrue(maxSqrt <= TickMath.MAX_SQRT_RATIO);

        assertEq(TickMath.getTickAtSqrtRatio(minSqrt), TickMath.MIN_TICK);
    }

    function test_TickMath_ZeroTickIsUnity() public pure {
        uint160 sqrtRatioAtZero = TickMath.getSqrtRatioAtTick(0);
        // At tick 0, sqrtPriceX96 = 2^96
        assertEq(sqrtRatioAtZero, 1 << 96);
        assertEq(TickMath.getTickAtSqrtRatio(1 << 96), 0);
    }

    function test_BitMath_MsbAndLsb() public pure {
        assertEq(BitMath.mostSignificantBit(1), 0);
        assertEq(BitMath.mostSignificantBit(2), 1);
        assertEq(BitMath.mostSignificantBit(255), 7);
        assertEq(BitMath.mostSignificantBit(1 << 128), 128);
        assertEq(BitMath.mostSignificantBit(type(uint256).max), 255);

        assertEq(BitMath.leastSignificantBit(1), 0);
        assertEq(BitMath.leastSignificantBit(2), 1);
        assertEq(BitMath.leastSignificantBit(12), 2); // 12 = 1100 in binary, LSB = 2
        assertEq(BitMath.leastSignificantBit(1 << 64), 64);
    }

    function test_RedBlackTree_OrderedInsertionAndRemoval() public {
        treeWrapper.insert(50);
        treeWrapper.insert(20);
        treeWrapper.insert(80);
        treeWrapper.insert(10);
        treeWrapper.insert(30);

        assertEq(treeWrapper.count(), 5);
        assertEq(treeWrapper.first(), 10);
        assertEq(treeWrapper.last(), 80);

        assertEq(treeWrapper.next(20), 30);
        assertEq(treeWrapper.prev(50), 30);

        treeWrapper.remove(20);
        assertFalse(treeWrapper.exists(20));
        assertEq(treeWrapper.count(), 4);
        assertEq(treeWrapper.next(10), 30);
    }

    function test_LinkedList_FifoOperations() public {
        bytes32 id1 = keccak256("order_1");
        bytes32 id2 = keccak256("order_2");
        bytes32 id3 = keccak256("order_3");

        listWrapper.pushBack(id1);
        listWrapper.pushBack(id2);
        listWrapper.pushBack(id3);

        assertEq(listWrapper.size(), 3);
        assertTrue(listWrapper.contains(id2));

        bytes32 popped1 = listWrapper.popFront();
        assertEq(popped1, id1);
        assertEq(listWrapper.size(), 2);

        listWrapper.remove(id3);
        assertFalse(listWrapper.contains(id3));
        assertEq(listWrapper.size(), 1);
    }

    function test_MatrixMath_DotProductAndCovariance() public pure {
        int256[] memory u = new int256[](2);
        int256[] memory v = new int256[](2);
        u[0] = 2e18;
        u[1] = 3e18;
        v[0] = 4e18;
        v[1] = 5e18;

        // dot = 2 * 4 + 3 * 5 = 23
        int256 dot = MatrixMath.dotProduct(u, v);
        assertEq(dot, 23e18);

        // Two asset net risk
        uint256 netRisk = MatrixMath.twoAssetNetRisk(
            100e18, // long 100
            -100e18, // short 100
            0.5e18, // 50% vol
            0.5e18, // 50% vol
            0.9e18  // 90% correlated
        );
        // With 90% correlation, net risk of long/short hedge should be significantly smaller than unhedged (50e18)
        assertTrue(netRisk < 25e18);
    }
}
