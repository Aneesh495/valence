// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title IValenceAccount
/// @notice Manages primary accounts, subaccount namespaces, session keys, and delegation.
interface IValenceAccount {
    event SubaccountCreated(address indexed owner, bytes32 indexed subaccountId, uint32 subaccountIndex);
    event DelegateAuthorized(bytes32 indexed subaccountId, address indexed delegate, uint32 permissions);
    event DelegateRevoked(bytes32 indexed subaccountId, address indexed delegate);

    struct Subaccount {
        address owner;
        uint32 subaccountIndex;
        uint64 createdAt;
        bool isActive;
    }

    function createSubaccount(uint32 subaccountIndex) external returns (bytes32 subaccountId);
    function getSubaccount(bytes32 subaccountId) external view returns (Subaccount memory);
    function getSubaccountId(address owner, uint32 subaccountIndex) external pure returns (bytes32);
    function isOwnerOrDelegate(bytes32 subaccountId, address caller, uint32 requiredPermission) external view returns (bool);
}
