// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC721} from "../interfaces/IERC721.sol";
import {IValencePool} from "../interfaces/IValencePool.sol";
import {IValencePoolFactory} from "../interfaces/IValencePoolFactory.sol";
import {IValenceMintCallback} from "./ValencePool.sol";
import {IERC20} from "../interfaces/IERC20.sol";

/// @title ValencePositionNFT
/// @notice Tokenized ERC-721 wrapper for concentrated liquidity provider positions with on-chain metadata.
contract ValencePositionNFT is IERC721, IValenceMintCallback {
    string public name = "Valence Concentrated Liquidity Position";
    string public symbol = "VAL-POS";

    address public immutable factory;
    uint256 private _nextId = 1;

    struct PositionDetails {
        uint256 nonce;
        address operator;
        address pool;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    mapping(uint256 => PositionDetails) private _positions;
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    error ValencePositionNFT__NotOwnerOrApproved();
    error ValencePositionNFT__TokenDoesNotExist();
    error ValencePositionNFT__ZeroAddress();
    error ValencePositionNFT__TransferFailed();

    constructor(address _factory) {
        require(_factory != address(0), "Zero address");
        factory = _factory;
    }

    function balanceOf(address owner) external view override returns (uint256) {
        if (owner == address(0)) revert ValencePositionNFT__ZeroAddress();
        return _balances[owner];
    }

    function ownerOf(uint256 tokenId) public view override returns (address) {
        address owner = _owners[tokenId];
        if (owner == address(0)) revert ValencePositionNFT__TokenDoesNotExist();
        return owner;
    }

    function getApproved(uint256 tokenId) external view override returns (address) {
        return _tokenApprovals[tokenId];
    }

    function isApprovedForAll(address owner, address operator) external view override returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    function approve(address to, uint256 tokenId) external override {
        address owner = ownerOf(tokenId);
        if (msg.sender != owner && !_operatorApprovals[owner][msg.sender]) {
            revert ValencePositionNFT__NotOwnerOrApproved();
        }
        _tokenApprovals[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external override {
        if (operator == address(0)) revert ValencePositionNFT__ZeroAddress();
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 tokenId) public override {
        if (!_isApprovedOrOwner(msg.sender, tokenId)) revert ValencePositionNFT__NotOwnerOrApproved();
        if (to == address(0)) revert ValencePositionNFT__ZeroAddress();
        if (_owners[tokenId] != from) revert ValencePositionNFT__NotOwnerOrApproved();

        delete _tokenApprovals[tokenId];
        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[tokenId] = to;

        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external override {
        transferFrom(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata) external override {
        transferFrom(from, to, tokenId);
    }

    struct MintParams {
        address pool;
        int24 tickLower;
        int24 tickUpper;
        uint128 amount;
        uint256 amount0Max;
        uint256 amount1Max;
        address recipient;
    }

    /// @notice Mints a new concentrated liquidity position and wraps it into an ERC-721 NFT.
    function mint(MintParams calldata params)
        external
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        tokenId = _nextId++;
        _owners[tokenId] = params.recipient;
        _balances[params.recipient] += 1;

        (amount0, amount1) = IValencePool(params.pool).mint(
            address(this),
            params.tickLower,
            params.tickUpper,
            params.amount,
            abi.encode(msg.sender, params.pool)
        );

        _positions[tokenId] = PositionDetails({
            nonce: 0,
            operator: address(0),
            pool: params.pool,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: params.amount,
            feeGrowthInside0LastX128: 0,
            feeGrowthInside1LastX128: 0,
            tokensOwed0: 0,
            tokensOwed1: 0
        });

        liquidity = params.amount;
        emit Transfer(address(0), params.recipient, tokenId);
    }

    /// @notice Callback called by ValencePool during position mint.
    function valenceMintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external override {
        (address payer, address pool) = abi.decode(data, (address, address));
        require(msg.sender == pool, "Unauthorized callback");

        address token0 = IValencePool(pool).token0();
        address token1 = IValencePool(pool).token1();

        if (amount0Owed > 0) _pay(token0, payer, msg.sender, amount0Owed);
        if (amount1Owed > 0) _pay(token1, payer, msg.sender, amount1Owed);
    }

    function getPosition(uint256 tokenId) external view returns (PositionDetails memory) {
        if (_owners[tokenId] == address(0)) revert ValencePositionNFT__TokenDoesNotExist();
        return _positions[tokenId];
    }

    /// @notice Generates on-chain SVG data URI for position visualization.
    function tokenURI(uint256 tokenId) external view returns (string memory) {
        PositionDetails memory pos = _positions[tokenId];
        if (_owners[tokenId] == address(0)) revert ValencePositionNFT__TokenDoesNotExist();

        return string(
            abi.encodePacked(
                "data:application/json;utf8,{\"name\":\"Valence Position #",
                _toString(tokenId),
                "\",\"description\":\"Valence Concentrated Liquidity Position NFT\",\"attributes\":[{\"trait_type\":\"Liquidity\",\"value\":\"",
                _toString(pos.liquidity),
                "\"}]}"
            )
        );
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) private view returns (bool) {
        address owner = _owners[tokenId];
        return (spender == owner || _tokenApprovals[tokenId] == spender || _operatorApprovals[owner][spender]);
    }

    function _pay(address token, address payer, address recipient, uint256 value) private {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, payer, recipient, value)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            revert ValencePositionNFT__TransferFailed();
        }
    }

    function _toString(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
