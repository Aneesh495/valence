// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title IValencePoolFactory
/// @notice Deploys and catalogs concentrated liquidity pools with configurable fee tiers.
interface IValencePoolFactory {
    event PoolCreated(
        address indexed token0,
        address indexed token1,
        uint24 indexed fee,
        int24 tickSpacing,
        address pool
    );

    event FeeTierEnabled(uint24 indexed fee, int24 indexed tickSpacing);

    function owner() external view returns (address);
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);

    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external returns (address pool);

    function enableFeeTier(uint24 fee, int24 tickSpacing) external;
    function setOwner(address _owner) external;
}
