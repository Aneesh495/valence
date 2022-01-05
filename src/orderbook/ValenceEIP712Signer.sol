// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IValenceAccount} from "../interfaces/IValenceAccount.sol";

/// @title ValenceEIP712Signer
/// @notice Off-chain signed order verification and word-aligned nonce cancellation bitmap engine.
/// @dev Implements EIP-712 domain separation, structured data digests, and batch order cancellation.
contract ValenceEIP712Signer {
    bytes32 public immutable DOMAIN_SEPARATOR;
    IValenceAccount public immutable accountManager;

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "SignedOrder(bytes32 subaccountId,bytes32 marketId,uint8 side,uint256 priceX96,uint256 quantity,uint256 nonce,uint256 deadline)"
    );

    // subaccountId => wordIndex => cancelled nonce bitmask
    mapping(bytes32 => mapping(uint256 => uint256)) private _cancelledNonces;

    event NonceCancelled(bytes32 indexed subaccountId, uint256 wordIndex, uint256 bitmask);
    event AllNoncesCancelledBefore(bytes32 indexed subaccountId, uint256 minNonce);

    // subaccountId => minValidNonce
    mapping(bytes32 => uint256) public minValidNonce;

    error ValenceEIP712Signer__SignatureExpired();
    error ValenceEIP712Signer__InvalidSignature();
    error ValenceEIP712Signer__NonceAlreadyCancelled();
    error ValenceEIP712Signer__Unauthorized();
    error ValenceEIP712Signer__ZeroAddress();

    struct SignedOrder {
        bytes32 subaccountId;
        bytes32 marketId;
        uint8 side; // 0 = Buy, 1 = Sell
        uint256 priceX96;
        uint256 quantity;
        uint256 nonce;
        uint256 deadline;
    }

    constructor(address _accountManager) {
        if (_accountManager == address(0)) revert ValenceEIP712Signer__ZeroAddress();
        accountManager = IValenceAccount(_accountManager);

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Valence")),
                keccak256(bytes("1.0")),
                block.chainid,
                address(this)
            )
        );
    }

    /// @notice Verifies an off-chain signed order and marks its nonce as filled/consumed.
    function verifyAndConsumeOrder(
        SignedOrder calldata order,
        bytes calldata signature
    ) external returns (bool) {
        if (block.timestamp > order.deadline) revert ValenceEIP712Signer__SignatureExpired();
        if (order.nonce < minValidNonce[order.subaccountId]) revert ValenceEIP712Signer__NonceAlreadyCancelled();

        uint256 wordIndex = order.nonce >> 8;
        uint256 bitPos = order.nonce % 256;
        uint256 mask = 1 << bitPos;

        if ((_cancelledNonces[order.subaccountId][wordIndex] & mask) != 0) {
            revert ValenceEIP712Signer__NonceAlreadyCancelled();
        }

        // Mark nonce as used
        _cancelledNonces[order.subaccountId][wordIndex] |= mask;

        // Hash struct
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.subaccountId,
                order.marketId,
                order.side,
                order.priceX96,
                order.quantity,
                order.nonce,
                order.deadline
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        address signer = _recoverSigner(digest, signature);

        // Verify signer is owner or delegate with trade permission
        if (!accountManager.isOwnerOrDelegate(order.subaccountId, signer, 2)) {
            revert ValenceEIP712Signer__InvalidSignature();
        }

        return true;
    }

    /// @notice Cancels a single nonce using bitmask manipulation.
    function cancelNonce(bytes32 subaccountId, uint256 nonce) external {
        if (!accountManager.isOwnerOrDelegate(subaccountId, msg.sender, 4)) {
            revert ValenceEIP712Signer__Unauthorized();
        }

        uint256 wordIndex = nonce >> 8;
        uint256 bitPos = nonce % 256;
        uint256 mask = 1 << bitPos;

        _cancelledNonces[subaccountId][wordIndex] |= mask;
        emit NonceCancelled(subaccountId, wordIndex, mask);
    }

    /// @notice Cancels all nonces strictly below a specified minimum nonce.
    function cancelAllNoncesBefore(bytes32 subaccountId, uint256 minNonce) external {
        if (!accountManager.isOwnerOrDelegate(subaccountId, msg.sender, 4)) {
            revert ValenceEIP712Signer__Unauthorized();
        }
        minValidNonce[subaccountId] = minNonce;
        emit AllNoncesCancelledBefore(subaccountId, minNonce);
    }

    /// @notice Checks if a nonce is cancelled or consumed.
    function isNonceCancelled(bytes32 subaccountId, uint256 nonce) external view returns (bool) {
        if (nonce < minValidNonce[subaccountId]) return true;
        uint256 wordIndex = nonce >> 8;
        uint256 bitPos = nonce % 256;
        return (_cancelledNonces[subaccountId][wordIndex] & (1 << bitPos)) != 0;
    }

    function _recoverSigner(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) revert ValenceEIP712Signer__InvalidSignature();

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }

        if (v < 27) v += 27;
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert ValenceEIP712Signer__InvalidSignature();

        return signer;
    }
}
