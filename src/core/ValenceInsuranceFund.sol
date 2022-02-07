// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IValenceInsuranceFund} from "../interfaces/IValenceInsuranceFund.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";

/// @title ValenceInsuranceFund
/// @notice Dual-tranche insurance reserve absorbing systemic bad debt deficits with junior/senior waterfalls.
/// @dev Implements first-loss junior absorption, senior principal protection, and deficit socialization.
contract ValenceInsuranceFund is IValenceInsuranceFund {
    using FixedPointMath for uint256;

    address public immutable owner;
    address public clearinghouse;
    address public immutable settlementToken;

    uint256 public seniorReserves;
    uint256 public juniorReserves;

    uint256 public seniorTotalShares;
    uint256 public juniorTotalShares;

    mapping(address => uint256) public seniorShares;
    mapping(address => uint256) public juniorShares;

    error ValenceInsuranceFund__Unauthorized();
    error ValenceInsuranceFund__ZeroAddress();
    error ValenceInsuranceFund__ZeroAmount();
    error ValenceInsuranceFund__InsufficientReserves();
    error ValenceInsuranceFund__TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert ValenceInsuranceFund__Unauthorized();
        _;
    }

    modifier onlyClearinghouse() {
        if (msg.sender != clearinghouse) revert ValenceInsuranceFund__Unauthorized();
        _;
    }

    constructor(address _settlementToken) {
        if (_settlementToken == address(0)) revert ValenceInsuranceFund__ZeroAddress();
        owner = msg.sender;
        settlementToken = _settlementToken;
    }

    function setClearinghouse(address _clearinghouse) external onlyOwner {
        if (_clearinghouse == address(0)) revert ValenceInsuranceFund__ZeroAddress();
        clearinghouse = _clearinghouse;
    }

    /// @notice Deposits capital into either senior or junior insurance tranche.
    function depositTranche(bool isSenior, uint256 amount) external returns (uint256 shares) {
        if (amount == 0) revert ValenceInsuranceFund__ZeroAmount();

        if (isSenior) {
            shares = seniorTotalShares == 0 ? amount : (amount * seniorTotalShares) / seniorReserves;
            seniorShares[msg.sender] += shares;
            seniorTotalShares += shares;
            seniorReserves += amount;
        } else {
            shares = juniorTotalShares == 0 ? amount : (amount * juniorTotalShares) / juniorReserves;
            juniorShares[msg.sender] += shares;
            juniorTotalShares += shares;
            juniorReserves += amount;
        }

        _safeTransferFrom(settlementToken, msg.sender, address(this), amount);

        emit TrancheDeposited(msg.sender, isSenior, amount, shares);
    }

    /// @notice Withdraws capital and accrued yields from an insurance tranche.
    function withdrawTranche(bool isSenior, uint256 shares) external returns (uint256 amount) {
        if (shares == 0) revert ValenceInsuranceFund__ZeroAmount();

        if (isSenior) {
            require(seniorShares[msg.sender] >= shares, "Insufficient shares");
            amount = (shares * seniorReserves) / seniorTotalShares;
            seniorShares[msg.sender] -= shares;
            seniorTotalShares -= shares;
            seniorReserves -= amount;
        } else {
            require(juniorShares[msg.sender] >= shares, "Insufficient shares");
            amount = (shares * juniorReserves) / juniorTotalShares;
            juniorShares[msg.sender] -= shares;
            juniorTotalShares -= shares;
            juniorReserves -= amount;
        }

        _safeTransfer(settlementToken, msg.sender, amount);

        emit TrancheWithdrawn(msg.sender, isSenior, amount, shares);
    }

    /// @notice Covers a bad debt deficit using junior tranche first, then senior tranche.
    function coverDeficit(bytes32 marketId, uint256 deficitUsd)
        external
        override
        onlyClearinghouse
        returns (uint256 coveredAmountUsd)
    {
        uint256 juniorPaid = 0;
        uint256 seniorPaid = 0;

        if (juniorReserves > 0) {
            juniorPaid = deficitUsd <= juniorReserves ? deficitUsd : juniorReserves;
            juniorReserves -= juniorPaid;
            coveredAmountUsd += juniorPaid;
        }

        uint256 remainingDeficit = deficitUsd - juniorPaid;
        if (remainingDeficit > 0 && seniorReserves > 0) {
            seniorPaid = remainingDeficit <= seniorReserves ? remainingDeficit : seniorReserves;
            seniorReserves -= seniorPaid;
            coveredAmountUsd += seniorPaid;
        }

        emit DeficitCovered(marketId, deficitUsd, seniorPaid, juniorPaid);
    }

    function getAvailableReserves() external view override returns (uint256, uint256) {
        return (seniorReserves, juniorReserves);
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            revert ValenceInsuranceFund__TransferFailed();
        }
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            revert ValenceInsuranceFund__TransferFailed();
        }
    }
}
