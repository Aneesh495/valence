// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IValenceAccount} from "../interfaces/IValenceAccount.sol";

/// @title ValenceAccount
/// @notice Subaccount registry with granular session key permissions and programmatic delegation.
/// @dev Each subaccount is identified deterministically via keccak256(owner, subaccountIndex).
contract ValenceAccount is IValenceAccount {
    struct DelegateInfo {
        uint32 permissions;
        uint64 expiryTimestamp;
        bool isActive;
    }

    // subaccountId => Subaccount
    mapping(bytes32 => Subaccount) private _subaccounts;

    // subaccountId => delegateAddress => DelegateInfo
    mapping(bytes32 => mapping(address => DelegateInfo)) private _delegates;

    // owner => array of subaccount IDs
    mapping(address => bytes32[]) private _ownerSubaccounts;

    error ValenceAccount__SubaccountAlreadyExists();
    error ValenceAccount__SubaccountNotFound();
    error ValenceAccount__Unauthorized();
    error ValenceAccount__ZeroAddress();
    error ValenceAccount__DelegateExpired();

    modifier onlySubaccountOwner(bytes32 subaccountId) {
        if (_subaccounts[subaccountId].owner != msg.sender) revert ValenceAccount__Unauthorized();
        _;
    }

    /// @notice Computes deterministic subaccount ID for an owner and index.
    function getSubaccountId(address owner, uint32 subaccountIndex) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, subaccountIndex));
    }

    /// @notice Creates a new subaccount under the caller's address.
    function createSubaccount(uint32 subaccountIndex) external returns (bytes32 subaccountId) {
        subaccountId = getSubaccountId(msg.sender, subaccountIndex);
        if (_subaccounts[subaccountId].isActive) revert ValenceAccount__SubaccountAlreadyExists();

        _subaccounts[subaccountId] = Subaccount({
            owner: msg.sender,
            subaccountIndex: subaccountIndex,
            createdAt: uint64(block.timestamp),
            isActive: true
        });

        _ownerSubaccounts[msg.sender].push(subaccountId);

        emit SubaccountCreated(msg.sender, subaccountId, subaccountIndex);
    }

    /// @notice Authorizes a delegate or session key for automated trading with specific permissions.
    /// @param subaccountId The subaccount ID
    /// @param delegate The delegated address (e.g. trading bot, session key)
    /// @param permissions Bitmask of allowed actions
    /// @param durationSeconds Validity duration of the session key
    function authorizeDelegate(
        bytes32 subaccountId,
        address delegate,
        uint32 permissions,
        uint64 durationSeconds
    ) external onlySubaccountOwner(subaccountId) {
        if (delegate == address(0)) revert ValenceAccount__ZeroAddress();

        uint64 expiry = uint64(block.timestamp) + durationSeconds;
        _delegates[subaccountId][delegate] = DelegateInfo({
            permissions: permissions,
            expiryTimestamp: expiry,
            isActive: true
        });

        emit DelegateAuthorized(subaccountId, delegate, permissions);
    }

    /// @notice Revokes a previously authorized delegate or session key.
    function revokeDelegate(bytes32 subaccountId, address delegate) external onlySubaccountOwner(subaccountId) {
        delete _delegates[subaccountId][delegate];
        emit DelegateRevoked(subaccountId, delegate);
    }

    /// @notice Validates whether a caller is authorized to perform an action on a subaccount.
    function isOwnerOrDelegate(
        bytes32 subaccountId,
        address caller,
        uint32 requiredPermission
    ) external view returns (bool) {
        Subaccount memory sub = _subaccounts[subaccountId];
        if (!sub.isActive) return false;
        if (caller == sub.owner) return true;

        DelegateInfo memory del = _delegates[subaccountId][caller];
        if (!del.isActive) return false;
        if (block.timestamp > del.expiryTimestamp) return false;

        return (del.permissions & requiredPermission) == requiredPermission;
    }

    function getSubaccount(bytes32 subaccountId) external view returns (Subaccount memory) {
        Subaccount memory sub = _subaccounts[subaccountId];
        if (!sub.isActive) revert ValenceAccount__SubaccountNotFound();
        return sub;
    }

    function getOwnerSubaccounts(address owner) external view returns (bytes32[] memory) {
        return _ownerSubaccounts[owner];
    }
}
