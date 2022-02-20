// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title ValenceTimelock
/// @notice Decentralized timelock queuing controller for protocol parameter updates and governance actions.
/// @dev Enforces mandatory delay periods, execution deadlines, and cancellation mechanisms.
contract ValenceTimelock {
    address public admin;
    uint256 public constant MIN_DELAY = 1 days;
    uint256 public constant MAX_DELAY = 30 days;
    uint256 public constant GRACE_PERIOD = 14 days;

    mapping(bytes32 => bool) public queuedTransactions;

    event TransactionQueued(
        bytes32 indexed txHash,
        address indexed target,
        uint256 value,
        string signature,
        bytes data,
        uint256 eta
    );

    event TransactionExecuted(
        bytes32 indexed txHash,
        address indexed target,
        uint256 value,
        string signature,
        bytes data,
        uint256 eta
    );

    event TransactionCancelled(bytes32 indexed txHash);

    error ValenceTimelock__Unauthorized();
    error ValenceTimelock__DelayOutOfBounds();
    error ValenceTimelock__NotQueued();
    error ValenceTimelock__TimeNotMet();
    error ValenceTimelock__TransactionStale();
    error ValenceTimelock__ExecutionFailed();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert ValenceTimelock__Unauthorized();
        _;
    }

    constructor(address _admin) {
        require(_admin != address(0), "Zero address");
        admin = _admin;
    }

    function queueTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 eta
    ) external onlyAdmin returns (bytes32 txHash) {
        if (eta < block.timestamp + MIN_DELAY || eta > block.timestamp + MAX_DELAY) {
            revert ValenceTimelock__DelayOutOfBounds();
        }

        txHash = keccak256(abi.encode(target, value, signature, data, eta));
        queuedTransactions[txHash] = true;

        emit TransactionQueued(txHash, target, value, signature, data, eta);
    }

    function cancelTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 eta
    ) external onlyAdmin {
        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        if (!queuedTransactions[txHash]) revert ValenceTimelock__NotQueued();

        delete queuedTransactions[txHash];
        emit TransactionCancelled(txHash);
    }

    function executeTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 eta
    ) external payable onlyAdmin returns (bytes memory) {
        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        if (!queuedTransactions[txHash]) revert ValenceTimelock__NotQueued();
        if (block.timestamp < eta) revert ValenceTimelock__TimeNotMet();
        if (block.timestamp > eta + GRACE_PERIOD) revert ValenceTimelock__TransactionStale();

        delete queuedTransactions[txHash];

        bytes memory callData;
        if (bytes(signature).length == 0) {
            callData = data;
        } else {
            callData = abi.encodePacked(bytes4(keccak256(bytes(signature))), data);
        }

        (bool success, bytes memory returnData) = target.call{value: value}(callData);
        if (!success) revert ValenceTimelock__ExecutionFailed();

        emit TransactionExecuted(txHash, target, value, signature, data, eta);
        return returnData;
    }
}
