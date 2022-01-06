// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IValenceAccount} from "../interfaces/IValenceAccount.sol";
import {IValenceOracleRelay} from "../interfaces/IValenceOracleRelay.sol";
import {IValenceClearinghouse} from "../interfaces/IValenceClearinghouse.sol";

/// @title ValenceConditionalOrders
/// @notice On-chain conditional order registry supporting Stop-Loss, Take-Profit, and Trailing Stops.
/// @dev Monitored by decentralized keeper bots with automated trigger validation against Oracle Relay.
contract ValenceConditionalOrders {
    enum TriggerType { STOP_LOSS, TAKE_PROFIT, TRAILING_STOP }

    struct ConditionalOrder {
        bytes32 triggerId;
        bytes32 subaccountId;
        bytes32 marketId;
        TriggerType triggerType;
        bool isLong;
        int256 sizeDelta;
        uint256 triggerPriceX96;
        uint256 limitPriceX96;
        uint256 trailingDeltaX96;
        uint256 peakPriceX96;
        uint64 createdAt;
        bool isTriggered;
        bool isCancelled;
    }

    IValenceAccount public immutable accountManager;
    IValenceOracleRelay public oracleRelay;
    IValenceClearinghouse public clearinghouse;
    address public immutable owner;

    mapping(bytes32 => ConditionalOrder) public orders;
    bytes32[] private _activeOrderIds;
    uint256 private _triggerNonce;

    event ConditionalOrderCreated(
        bytes32 indexed triggerId,
        bytes32 indexed subaccountId,
        bytes32 indexed marketId,
        TriggerType triggerType,
        uint256 triggerPriceX96
    );

    event ConditionalOrderTriggered(
        bytes32 indexed triggerId,
        address indexed keeper,
        uint256 executedPriceX96
    );

    event ConditionalOrderCancelled(bytes32 indexed triggerId);

    error ValenceConditionalOrders__Unauthorized();
    error ValenceConditionalOrders__OrderInactive();
    error ValenceConditionalOrders__ConditionNotMet();
    error ValenceConditionalOrders__ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert ValenceConditionalOrders__Unauthorized();
        _;
    }

    constructor(address _accountManager, address _oracleRelay) {
        if (_accountManager == address(0) || _oracleRelay == address(0)) {
            revert ValenceConditionalOrders__ZeroAddress();
        }
        owner = msg.sender;
        accountManager = IValenceAccount(_accountManager);
        oracleRelay = IValenceOracleRelay(_oracleRelay);
    }

    function setClearinghouse(address _clearinghouse) external onlyOwner {
        if (_clearinghouse == address(0)) revert ValenceConditionalOrders__ZeroAddress();
        clearinghouse = IValenceClearinghouse(_clearinghouse);
    }

    function setOracleRelay(address _oracleRelay) external onlyOwner {
        if (_oracleRelay == address(0)) revert ValenceConditionalOrders__ZeroAddress();
        oracleRelay = IValenceOracleRelay(_oracleRelay);
    }

    /// @notice Registers a new conditional stop-loss or take-profit trigger.
    function createConditionalOrder(
        bytes32 subaccountId,
        bytes32 marketId,
        TriggerType triggerType,
        bool isLong,
        int256 sizeDelta,
        uint256 triggerPriceX96,
        uint256 limitPriceX96,
        uint256 trailingDeltaX96
    ) external returns (bytes32 triggerId) {
        if (!accountManager.isOwnerOrDelegate(subaccountId, msg.sender, 2)) {
            revert ValenceConditionalOrders__Unauthorized();
        }

        triggerId = keccak256(abi.encodePacked(subaccountId, marketId, block.timestamp, ++_triggerNonce));

        orders[triggerId] = ConditionalOrder({
            triggerId: triggerId,
            subaccountId: subaccountId,
            marketId: marketId,
            triggerType: triggerType,
            isLong: isLong,
            sizeDelta: sizeDelta,
            triggerPriceX96: triggerPriceX96,
            limitPriceX96: limitPriceX96,
            trailingDeltaX96: trailingDeltaX96,
            peakPriceX96: triggerPriceX96,
            createdAt: uint64(block.timestamp),
            isTriggered: false,
            isCancelled: false
        });

        _activeOrderIds.push(triggerId);

        emit ConditionalOrderCreated(triggerId, subaccountId, marketId, triggerType, triggerPriceX96);
    }

    /// @notice Cancels an active conditional order.
    function cancelConditionalOrder(bytes32 triggerId) external {
        ConditionalOrder storage order = orders[triggerId];
        if (order.isTriggered || order.isCancelled) revert ValenceConditionalOrders__OrderInactive();

        if (!accountManager.isOwnerOrDelegate(order.subaccountId, msg.sender, 4)) {
            revert ValenceConditionalOrders__Unauthorized();
        }

        order.isCancelled = true;
        emit ConditionalOrderCancelled(triggerId);
    }

    /// @notice Evaluates and executes a triggered conditional order via Clearinghouse.
    function executeConditionalOrder(bytes32 triggerId) external returns (uint256 executedPriceX96) {
        ConditionalOrder storage order = orders[triggerId];
        if (order.isTriggered || order.isCancelled) revert ValenceConditionalOrders__OrderInactive();

        uint256 currentMarkPrice = oracleRelay.getMarkPrice(order.marketId);

        // Evaluate trigger condition
        if (order.triggerType == TriggerType.STOP_LOSS) {
            if (order.isLong && currentMarkPrice > order.triggerPriceX96) revert ValenceConditionalOrders__ConditionNotMet();
            if (!order.isLong && currentMarkPrice < order.triggerPriceX96) revert ValenceConditionalOrders__ConditionNotMet();
        } else if (order.triggerType == TriggerType.TAKE_PROFIT) {
            if (order.isLong && currentMarkPrice < order.triggerPriceX96) revert ValenceConditionalOrders__ConditionNotMet();
            if (!order.isLong && currentMarkPrice > order.triggerPriceX96) revert ValenceConditionalOrders__ConditionNotMet();
        } else if (order.triggerType == TriggerType.TRAILING_STOP) {
            if (order.isLong) {
                if (currentMarkPrice > order.peakPriceX96) {
                    order.peakPriceX96 = currentMarkPrice;
                    revert ValenceConditionalOrders__ConditionNotMet();
                }
                if (currentMarkPrice + order.trailingDeltaX96 > order.peakPriceX96) {
                    revert ValenceConditionalOrders__ConditionNotMet();
                }
            } else {
                if (currentMarkPrice < order.peakPriceX96) {
                    order.peakPriceX96 = currentMarkPrice;
                    revert ValenceConditionalOrders__ConditionNotMet();
                }
                if (currentMarkPrice < order.peakPriceX96 + order.trailingDeltaX96) {
                    revert ValenceConditionalOrders__ConditionNotMet();
                }
            }
        }

        order.isTriggered = true;

        if (address(clearinghouse) != address(0)) {
            (executedPriceX96,) = clearinghouse.executeTrade(
                order.subaccountId,
                order.marketId,
                order.sizeDelta,
                order.limitPriceX96
            );
        } else {
            executedPriceX96 = currentMarkPrice;
        }

        emit ConditionalOrderTriggered(triggerId, msg.sender, executedPriceX96);
    }
}
