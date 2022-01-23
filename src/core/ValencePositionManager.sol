// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IValencePortfolioMargin} from "../interfaces/IValencePortfolioMargin.sol";
import {IValenceOracleRelay} from "../interfaces/IValenceOracleRelay.sol";
import {IValenceFundingEngine} from "../interfaces/IValenceFundingEngine.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";
import {SafeCast} from "../libraries/SafeCast.sol";

/// @title ValencePositionManager
/// @notice Manages perpetual derivative position lifecycle, weighted entry prices, and realized PnL.
/// @dev Maintains subaccount positions, integrates continuous funding, and interfaces with portfolio margin.
contract ValencePositionManager {
    using FixedPointMath for uint256;
    using FixedPointMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;

    address public immutable owner;
    address public clearinghouse;
    IValenceOracleRelay public oracleRelay;
    IValenceFundingEngine public fundingEngine;

    struct Position {
        bytes32 marketId;
        int256 size;                      // Positive for long, negative for short (in WAD)
        uint256 entryPriceX96;            // Weighted average entry price in 2^96 format
        int256 lastFundingIndexWad;       // Cumulative funding index at last settlement
        uint64 lastTradeTimestamp;
    }

    // subaccountId => marketId => Position
    mapping(bytes32 => mapping(bytes32 => Position)) private _positions;

    // subaccountId => array of active marketIds
    mapping(bytes32 => bytes32[]) private _subaccountActiveMarkets;
    // subaccountId => marketId => isMarketActive
    mapping(bytes32 => mapping(bytes32 => bool)) private _isMarketActive;

    event PositionUpdated(
        bytes32 indexed subaccountId,
        bytes32 indexed marketId,
        int256 newSize,
        uint256 newEntryPriceX96,
        int256 realizedPnlUsd
    );

    error ValencePositionManager__Unauthorized();
    error ValencePositionManager__ZeroAddress();
    error ValencePositionManager__ZeroDelta();

    modifier onlyClearinghouse() {
        if (msg.sender != clearinghouse) revert ValencePositionManager__Unauthorized();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert ValencePositionManager__Unauthorized();
        _;
    }

    constructor(address _oracleRelay, address _fundingEngine) {
        if (_oracleRelay == address(0) || _fundingEngine == address(0)) {
            revert ValencePositionManager__ZeroAddress();
        }
        owner = msg.sender;
        oracleRelay = IValenceOracleRelay(_oracleRelay);
        fundingEngine = IValenceFundingEngine(_fundingEngine);
    }

    function setClearinghouse(address _clearinghouse) external onlyOwner {
        if (_clearinghouse == address(0)) revert ValencePositionManager__ZeroAddress();
        clearinghouse = _clearinghouse;
    }

    function setOracleRelay(address _oracleRelay) external onlyOwner {
        if (_oracleRelay == address(0)) revert ValencePositionManager__ZeroAddress();
        oracleRelay = IValenceOracleRelay(_oracleRelay);
    }

    function setFundingEngine(address _fundingEngine) external onlyOwner {
        if (_fundingEngine == address(0)) revert ValencePositionManager__ZeroAddress();
        fundingEngine = IValenceFundingEngine(_fundingEngine);
    }

    /// @notice Modifies a subaccount's perpetual position, calculating realized PnL on reductions.
    function modifyPosition(
        bytes32 subaccountId,
        bytes32 marketId,
        int256 sizeDelta,
        uint256 executionPriceX96
    ) external onlyClearinghouse returns (int256 realizedPnlUsd) {
        if (sizeDelta == 0) revert ValencePositionManager__ZeroDelta();

        Position storage pos = _positions[subaccountId][marketId];
        int256 currentSize = pos.size;
        uint256 currentEntry = pos.entryPriceX96;

        // First settle accumulated funding
        int256 accruedFunding = fundingEngine.getAccruedFunding(marketId, pos.lastFundingIndexWad, currentSize);
        pos.lastFundingIndexWad = fundingEngine.getFundingState(marketId).cumulativeFundingIndexWad;
        realizedPnlUsd += accruedFunding;

        int256 newSize = currentSize + sizeDelta;

        if (currentSize == 0) {
            // Opening fresh position
            pos.size = newSize;
            pos.entryPriceX96 = executionPriceX96;
            _addActiveMarket(subaccountId, marketId);
        } else if ((currentSize > 0 && sizeDelta > 0) || (currentSize < 0 && sizeDelta < 0)) {
            // Increasing existing position in same direction: compute weighted average entry price
            uint256 currentAbs = FixedPointMath.abs(currentSize);
            uint256 deltaAbs = FixedPointMath.abs(sizeDelta);
            uint256 newAbs = currentAbs + deltaAbs;

            uint256 weightedEntry = (currentEntry * currentAbs + executionPriceX96 * deltaAbs) / newAbs;
            pos.size = newSize;
            pos.entryPriceX96 = weightedEntry;
        } else {
            // Reducing or flipping position: realize PnL on reduced portion
            uint256 closeSizeAbs = FixedPointMath.min(FixedPointMath.abs(currentSize), FixedPointMath.abs(sizeDelta));

            int256 priceDiffWad = currentSize > 0
                ? int256((executionPriceX96 * FixedPointMath.WAD) >> 96) - int256((currentEntry * FixedPointMath.WAD) >> 96)
                : int256((currentEntry * FixedPointMath.WAD) >> 96) - int256((executionPriceX96 * FixedPointMath.WAD) >> 96);

            int256 pnl = (priceDiffWad * int256(closeSizeAbs)) / int256(FixedPointMath.WAD);
            realizedPnlUsd += pnl;

            if (newSize == 0) {
                // Completely closed
                pos.size = 0;
                pos.entryPriceX96 = 0;
                _removeActiveMarket(subaccountId, marketId);
            } else if ((currentSize > 0 && newSize > 0) || (currentSize < 0 && newSize < 0)) {
                // Partially closed, entry price remains unchanged
                pos.size = newSize;
            } else {
                // Position flipped: remaining size adopts execution price as new entry
                pos.size = newSize;
                pos.entryPriceX96 = executionPriceX96;
            }
        }

        pos.lastTradeTimestamp = uint64(block.timestamp);

        emit PositionUpdated(subaccountId, marketId, newSize, pos.entryPriceX96, realizedPnlUsd);
    }

    /// @notice Settles funding for a subaccount on a given market without changing position size.
    function settleFunding(bytes32 subaccountId, bytes32 marketId)
        external
        onlyClearinghouse
        returns (int256 fundingPayment)
    {
        Position storage pos = _positions[subaccountId][marketId];
        if (pos.size == 0) return 0;

        fundingPayment = fundingEngine.getAccruedFunding(marketId, pos.lastFundingIndexWad, pos.size);
        pos.lastFundingIndexWad = fundingEngine.getFundingState(marketId).cumulativeFundingIndexWad;
    }

    /// @notice Returns position summaries across all active markets for an account (used by Portfolio Margin).
    function getSubaccountPositions(bytes32 subaccountId)
        external
        view
        returns (IValencePortfolioMargin.PositionSummary[] memory summaries)
    {
        bytes32[] memory markets = _subaccountActiveMarkets[subaccountId];
        uint256 len = markets.length;

        summaries = new IValencePortfolioMargin.PositionSummary[](len);

        for (uint256 i = 0; i < len;) {
            bytes32 marketId = markets[i];
            Position memory pos = _positions[subaccountId][marketId];

            uint256 markPriceX96 = oracleRelay.getMarkPrice(marketId);
            uint256 absSize = FixedPointMath.abs(pos.size);
            uint256 notionalUsd = (absSize * markPriceX96) >> 96;

            int256 pnlWad = 0;
            if (pos.size != 0 && pos.entryPriceX96 != 0) {
                int256 markWad = int256((markPriceX96 * FixedPointMath.WAD) >> 96);
                int256 entryWad = int256((pos.entryPriceX96 * FixedPointMath.WAD) >> 96);
                int256 priceDelta = pos.size > 0 ? markWad - entryWad : entryWad - markWad;
                pnlWad = (priceDelta * int256(absSize)) / int256(FixedPointMath.WAD);
            }

            summaries[i] = IValencePortfolioMargin.PositionSummary({
                marketId: marketId,
                size: pos.size,
                entryPriceX96: pos.entryPriceX96,
                unrealizedPnl: pnlWad,
                notionalUsd: notionalUsd
            });

            unchecked {
                i++;
            }
        }
    }

    function getPosition(bytes32 subaccountId, bytes32 marketId) external view returns (Position memory) {
        return _positions[subaccountId][marketId];
    }

    function getSubaccountActiveMarkets(bytes32 subaccountId) external view returns (bytes32[] memory) {
        return _subaccountActiveMarkets[subaccountId];
    }

    // --- Private Market Tracking Helpers ---

    function _addActiveMarket(bytes32 subaccountId, bytes32 marketId) private {
        if (!_isMarketActive[subaccountId][marketId]) {
            _isMarketActive[subaccountId][marketId] = true;
            _subaccountActiveMarkets[subaccountId].push(marketId);
        }
    }

    function _removeActiveMarket(bytes32 subaccountId, bytes32 marketId) private {
        if (_isMarketActive[subaccountId][marketId]) {
            _isMarketActive[subaccountId][marketId] = false;
            bytes32[] storage list = _subaccountActiveMarkets[subaccountId];
            uint256 len = list.length;
            for (uint256 i = 0; i < len;) {
                if (list[i] == marketId) {
                    list[i] = list[len - 1];
                    list.pop();
                    break;
                }
                unchecked {
                    i++;
                }
            }
        }
    }
}
