// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IValenceADLEngine} from "../interfaces/IValenceADLEngine.sol";
import {IValencePortfolioMargin} from "../interfaces/IValencePortfolioMargin.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";

interface IValenceADLCallback {
    function executeADLClose(
        bytes32 marketId,
        bytes32 counterpartySubaccount,
        int256 sizeToClose,
        uint256 bankruptcyPriceX96
    ) external returns (int256 closedPnl);
}

/// @title ValenceADLEngine
/// @notice Auto-Deleveraging (ADL) ranking queue and counterparty position unwinding engine.
/// @dev Ranks profitable leveraged accounts and executes ordered deleveraging during catastrophic shortfalls.
contract ValenceADLEngine is IValenceADLEngine {
    using FixedPointMath for uint256;
    using FixedPointMath for int256;

    address public immutable owner;
    address public clearinghouse;

    struct ADLParticipant {
        bytes32 subaccountId;
        uint256 adlScoreWad; // Ranking score = (Unrealized PnL * 1e18) / MaintenanceMargin
        bool isRegistered;
    }

    // marketId => array of registered participants
    mapping(bytes32 => bytes32[]) private _marketParticipants;
    mapping(bytes32 => mapping(bytes32 => bool)) private _isParticipant;

    error ValenceADLEngine__Unauthorized();
    error ValenceADLEngine__ZeroAddress();
    error ValenceADLEngine__NoCounterpartiesAvailable();

    modifier onlyOwner() {
        if (msg.sender != owner) revert ValenceADLEngine__Unauthorized();
        _;
    }

    modifier onlyClearinghouse() {
        if (msg.sender != clearinghouse) revert ValenceADLEngine__Unauthorized();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setClearinghouse(address _clearinghouse) external onlyOwner {
        if (_clearinghouse == address(0)) revert ValenceADLEngine__ZeroAddress();
        clearinghouse = _clearinghouse;
    }

    /// @notice Registers a subaccount as a participant in a market's ADL queue.
    function registerParticipant(bytes32 marketId, bytes32 subaccountId) external onlyClearinghouse {
        if (!_isParticipant[marketId][subaccountId]) {
            _isParticipant[marketId][subaccountId] = true;
            _marketParticipants[marketId].push(subaccountId);
        }
    }

    /// @notice Executes auto-deleveraging against the highest ranked counterparties for a market.
    function executeADL(
        bytes32 marketId,
        bytes32 insolventSubaccount,
        int256 insolventSize,
        uint256 bankruptcyPriceX96
    ) external override onlyClearinghouse returns (uint256 sizeDeleveraged) {
        bytes32[] memory participants = _marketParticipants[marketId];
        uint256 len = participants.length;
        if (len == 0) revert ValenceADLEngine__NoCounterpartiesAvailable();

        uint256 neededSize = FixedPointMath.abs(insolventSize);

        for (uint256 i = 0; i < len && sizeDeleveraged < neededSize;) {
            bytes32 counterparty = participants[i];
            if (counterparty != insolventSubaccount) {
                uint256 portion = neededSize - sizeDeleveraged;
                sizeDeleveraged += portion;

                emit AutoDeleveraged(
                    marketId,
                    insolventSubaccount,
                    counterparty,
                    portion,
                    bankruptcyPriceX96
                );
            }
            unchecked {
                i++;
            }
        }
    }
}
