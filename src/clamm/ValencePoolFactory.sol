// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IValencePoolFactory} from "../interfaces/IValencePoolFactory.sol";
import {ValencePool, IValencePoolDeployer} from "./ValencePool.sol";

/// @title ValencePoolFactory
/// @notice Deploys and indexes concentrated liquidity pools with deterministic salt and fee tiers.
contract ValencePoolFactory is IValencePoolFactory, IValencePoolDeployer {
    address public override owner;

    struct Parameters {
        address factory;
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;
    }

    Parameters public override parameters;

    mapping(uint24 => int24) public override feeAmountTickSpacing;
    mapping(address => mapping(address => mapping(uint24 => address))) public override getPool;
    address[] public allPools;

    error ValencePoolFactory__Unauthorized();
    error ValencePoolFactory__IdenticalAddresses();
    error ValencePoolFactory__ZeroAddress();
    error ValencePoolFactory__FeeTierNotEnabled();
    error ValencePoolFactory__PoolAlreadyExists();
    error ValencePoolFactory__InvalidFeeOrSpacing();

    modifier onlyOwner() {
        if (msg.sender != owner) revert ValencePoolFactory__Unauthorized();
        _;
    }

    constructor() {
        owner = msg.sender;

        // Default canonical fee tiers
        _enableFeeTier(100, 1);     // 0.01% - tickSpacing 1
        _enableFeeTier(500, 10);   // 0.05% - tickSpacing 10
        _enableFeeTier(3000, 60);  // 0.30% - tickSpacing 60
        _enableFeeTier(10000, 200);// 1.00% - tickSpacing 200
    }

    function setOwner(address _owner) external override onlyOwner {
        if (_owner == address(0)) revert ValencePoolFactory__ZeroAddress();
        owner = _owner;
    }

    function enableFeeTier(uint24 fee, int24 tickSpacing) external override onlyOwner {
        _enableFeeTier(fee, tickSpacing);
    }

    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external override returns (address pool) {
        if (tokenA == tokenB) revert ValencePoolFactory__IdenticalAddresses();
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert ValencePoolFactory__ZeroAddress();

        int24 tickSpacing = feeAmountTickSpacing[fee];
        if (tickSpacing == 0) revert ValencePoolFactory__FeeTierNotEnabled();
        if (getPool[token0][token1][fee] != address(0)) revert ValencePoolFactory__PoolAlreadyExists();

        parameters = Parameters({
            factory: address(this),
            token0: token0,
            token1: token1,
            fee: fee,
            tickSpacing: tickSpacing
        });

        bytes32 salt = keccak256(abi.encodePacked(token0, token1, fee));
        pool = address(new ValencePool{salt: salt}());
        delete parameters;

        getPool[token0][token1][fee] = pool;
        getPool[token1][token0][fee] = pool; // Populate reverse mapping for lookup convenience
        allPools.push(pool);

        emit PoolCreated(token0, token1, fee, tickSpacing, pool);
    }

    function allPoolsLength() external view returns (uint256) {
        return allPools.length;
    }

    function _enableFeeTier(uint24 fee, int24 tickSpacing) private {
        if (fee >= 1000000 || tickSpacing <= 0 || tickSpacing > 16384) {
            revert ValencePoolFactory__InvalidFeeOrSpacing();
        }
        feeAmountTickSpacing[fee] = tickSpacing;
        emit FeeTierEnabled(fee, tickSpacing);
    }
}
