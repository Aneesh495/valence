// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title IValenceADLEngine
/// @notice Interface for Auto-Deleveraging (ADL) counterparty ranking and bankruptcy resolution.
interface IValenceADLEngine {
    event AutoDeleveraged(
        bytes32 indexed marketId,
        bytes32 indexed insolventSubaccount,
        bytes32 indexed counterpartySubaccount,
        uint256 sizeDeleveraged,
        uint256 bankruptcyPriceX96
    );

    function executeADL(
        bytes32 marketId,
        bytes32 insolventSubaccount,
        int256 insolventSize,
        uint256 bankruptcyPriceX96
    ) external returns (uint256 sizeDeleveraged);
}
