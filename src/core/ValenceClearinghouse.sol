// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IValenceClearinghouse} from "../interfaces/IValenceClearinghouse.sol";
import {IValenceVault} from "../interfaces/IValenceVault.sol";
import {IValenceAccount} from "../interfaces/IValenceAccount.sol";
import {IValencePortfolioMargin} from "../interfaces/IValencePortfolioMargin.sol";
import {IValenceOracleRelay} from "../interfaces/IValenceOracleRelay.sol";
import {IValenceFundingEngine} from "../interfaces/IValenceFundingEngine.sol";
import {IValenceLiquidationEngine} from "../interfaces/IValenceLiquidationEngine.sol";
import {ValencePositionManager} from "./ValencePositionManager.sol";
import {ValenceFeeDistributor} from "./ValenceFeeDistributor.sol";
import {ValenceCircuitBreaker} from "../oracle/ValenceCircuitBreaker.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";

/// @title ValenceClearinghouse
/// @notice Central clearinghouse coordinating portfolio margin, trade execution, and funding settlement.
/// @dev Enforces real-time solvency assertions, circuit breakers, and fee distribution across all trades.
contract ValenceClearinghouse is IValenceClearinghouse {
    using FixedPointMath for uint256;
    using FixedPointMath for int256;

    address public immutable owner;
    IValenceVault public vault;
    IValenceAccount public accountManager;
    IValencePortfolioMargin public portfolioMargin;
    IValenceOracleRelay public oracleRelay;
    IValenceFundingEngine public fundingEngine;
    IValenceLiquidationEngine public liquidationEngine;
    ValencePositionManager public positionManager;
    ValenceFeeDistributor public feeDistributor;
    ValenceCircuitBreaker public circuitBreaker;

    uint32 public baseFeeBps = 10; // 0.10% taker fee
    bool public isPaused;

    error ValenceClearinghouse__Unauthorized();
    error ValenceClearinghouse__Paused();
    error ValenceClearinghouse__CircuitBreakerTripped();
    error ValenceClearinghouse__InsolventAfterTrade();
    error ValenceClearinghouse__SlippageExceeded();
    error ValenceClearinghouse__ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert ValenceClearinghouse__Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (isPaused) revert ValenceClearinghouse__Paused();
        _;
    }

    constructor(
        address _vault,
        address _accountManager,
        address _portfolioMargin,
        address _oracleRelay,
        address _fundingEngine,
        address _positionManager
    ) {
        if (
            _vault == address(0) ||
            _accountManager == address(0) ||
            _portfolioMargin == address(0) ||
            _oracleRelay == address(0) ||
            _fundingEngine == address(0) ||
            _positionManager == address(0)
        ) {
            revert ValenceClearinghouse__ZeroAddress();
        }

        owner = msg.sender;
        vault = IValenceVault(_vault);
        accountManager = IValenceAccount(_accountManager);
        portfolioMargin = IValencePortfolioMargin(_portfolioMargin);
        oracleRelay = IValenceOracleRelay(_oracleRelay);
        fundingEngine = IValenceFundingEngine(_fundingEngine);
        positionManager = ValencePositionManager(_positionManager);
    }

    function setLiquidationEngine(address _liquidationEngine) external onlyOwner {
        if (_liquidationEngine == address(0)) revert ValenceClearinghouse__ZeroAddress();
        liquidationEngine = IValenceLiquidationEngine(_liquidationEngine);
    }

    function setFeeDistributor(address _feeDistributor) external onlyOwner {
        if (_feeDistributor == address(0)) revert ValenceClearinghouse__ZeroAddress();
        feeDistributor = ValenceFeeDistributor(_feeDistributor);
    }

    function setCircuitBreaker(address _circuitBreaker) external onlyOwner {
        if (_circuitBreaker == address(0)) revert ValenceClearinghouse__ZeroAddress();
        circuitBreaker = ValenceCircuitBreaker(_circuitBreaker);
    }

    function setPaused(bool _paused) external onlyOwner {
        isPaused = _paused;
    }

    function setBaseFeeBps(uint32 _baseFeeBps) external onlyOwner {
        require(_baseFeeBps <= 100, "Fee too high");
        baseFeeBps = _baseFeeBps;
    }

    /// @notice Executes a perpetual trade, updating position, funding, and asserting post-trade solvency.
    function executeTrade(
        bytes32 subaccountId,
        bytes32 marketId,
        int256 sizeDelta,
        uint256 acceptablePriceX96
    ) external override whenNotPaused returns (uint256 executedPriceX96, uint256 feeUsd) {
        // Assert trading permission
        if (!accountManager.isOwnerOrDelegate(subaccountId, msg.sender, 2)) {
            revert ValenceClearinghouse__Unauthorized();
        }

        // Validate circuit breaker
        if (address(circuitBreaker) != address(0)) {
            if (circuitBreaker.checkAndTrip(marketId)) {
                revert ValenceClearinghouse__CircuitBreakerTripped();
            }
        }

        // Fetch mark price from oracle relay
        executedPriceX96 = oracleRelay.getMarkPrice(marketId);

        // Slippage assertion
        if (acceptablePriceX96 != 0) {
            if (sizeDelta > 0 && executedPriceX96 > acceptablePriceX96) revert ValenceClearinghouse__SlippageExceeded();
            if (sizeDelta < 0 && executedPriceX96 < acceptablePriceX96) revert ValenceClearinghouse__SlippageExceeded();
        }

        // Update funding prior to trade execution
        fundingEngine.updateFunding(marketId);

        // Modify position
        int256 realizedPnl = positionManager.modifyPosition(subaccountId, marketId, sizeDelta, executedPriceX96);

        // Calculate and distribute fee
        uint256 notionalUsd = (FixedPointMath.abs(sizeDelta) * executedPriceX96) >> 96;
        feeUsd = (notionalUsd * baseFeeBps) / 10000;

        if (address(feeDistributor) != address(0) && feeUsd > 0) {
            feeDistributor.distributeFee(feeUsd, address(0), msg.sender);
        }

        // Verify post-trade portfolio solvency
        if (!portfolioMargin.checkSolvency(subaccountId)) {
            revert ValenceClearinghouse__InsolventAfterTrade();
        }

        if (sizeDelta > 0) {
            emit PositionOpened(subaccountId, marketId, sizeDelta, executedPriceX96, feeUsd);
        } else {
            emit PositionClosed(subaccountId, marketId, sizeDelta, realizedPnl, feeUsd);
        }
    }

    /// @notice Settles accumulated funding for an account on a specific market.
    function settleFunding(bytes32 subaccountId, bytes32 marketId)
        external
        override
        whenNotPaused
        returns (int256 fundingPayment)
    {
        fundingEngine.updateFunding(marketId);
        fundingPayment = positionManager.settleFunding(subaccountId, marketId);
    }

    /// @notice Triggers Dutch liquidation for an underwater account.
    function liquidateAccount(bytes32 subaccountId) external override whenNotPaused returns (bytes32 auctionId) {
        require(address(liquidationEngine) != address(0), "No liquidation engine");
        auctionId = liquidationEngine.initiateLiquidation(subaccountId);
    }
}
