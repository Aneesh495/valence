// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title IValenceInsuranceFund
/// @notice Dual-tranche insurance reserve absorbing systemic bad debt deficits.
interface IValenceInsuranceFund {
    event DeficitCovered(bytes32 indexed marketId, uint256 deficitUsd, uint256 seniorPaid, uint256 juniorPaid);
    event TrancheDeposited(address indexed depositor, bool isSeniorTranche, uint256 assets, uint256 shares);
    event TrancheWithdrawn(address indexed redeemer, bool isSeniorTranche, uint256 assets, uint256 shares);

    function coverDeficit(bytes32 marketId, uint256 deficitUsd) external returns (uint256 coveredAmountUsd);
    function getAvailableReserves() external view returns (uint256 seniorReservesUsd, uint256 juniorReservesUsd);
}
