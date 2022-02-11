// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC20} from "../interfaces/IERC20.sol";

/// @title ValenceFeeDistributor
/// @notice Streams trading fee revenue between insurance tranches, treasury, maker rebates, and referrers.
/// @dev Implements gas-efficient pull claims for passive liquidity makers and affiliate partners.
contract ValenceFeeDistributor {
    address public immutable owner;
    address public clearinghouse;
    address public treasury;
    address public insuranceFund;
    address public immutable feeToken;

    // Maker / Referrer accumulated claimable fees
    mapping(address => uint256) public claimableRebates;
    mapping(address => address) public referrers; // trader => referrer

    event FeeDistributed(
        uint256 totalFee,
        uint256 insuranceShare,
        uint256 treasuryShare,
        uint256 makerRebate,
        uint256 referrerShare
    );

    event RebateClaimed(address indexed recipient, uint256 amount);
    event ReferrerRegistered(address indexed trader, address indexed referrer);

    error ValenceFeeDistributor__Unauthorized();
    error ValenceFeeDistributor__ZeroAddress();
    error ValenceFeeDistributor__NoRebateAvailable();
    error ValenceFeeDistributor__TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert ValenceFeeDistributor__Unauthorized();
        _;
    }

    modifier onlyClearinghouse() {
        if (msg.sender != clearinghouse) revert ValenceFeeDistributor__Unauthorized();
        _;
    }

    constructor(
        address _feeToken,
        address _treasury,
        address _insuranceFund
    ) {
        if (_feeToken == address(0) || _treasury == address(0) || _insuranceFund == address(0)) {
            revert ValenceFeeDistributor__ZeroAddress();
        }
        owner = msg.sender;
        feeToken = _feeToken;
        treasury = _treasury;
        insuranceFund = _insuranceFund;
    }

    function setClearinghouse(address _clearinghouse) external onlyOwner {
        if (_clearinghouse == address(0)) revert ValenceFeeDistributor__ZeroAddress();
        clearinghouse = _clearinghouse;
    }

    function registerReferrer(address trader, address referrer) external {
        require(msg.sender == trader || msg.sender == owner, "Unauthorized");
        if (referrer == address(0) || referrer == trader) revert ValenceFeeDistributor__ZeroAddress();
        referrers[trader] = referrer;
        emit ReferrerRegistered(trader, referrer);
    }

    /// @notice Splits trading fees across protocol stakeholders.
    function distributeFee(
        uint256 feeAmount,
        address maker,
        address taker
    ) external onlyClearinghouse {
        if (feeAmount == 0) return;

        uint256 insuranceShare = (feeAmount * 5000) / 10000; // 50%
        uint256 treasuryShare = (feeAmount * 3000) / 10000;  // 30%
        uint256 makerRebate = (feeAmount * 1000) / 10000;    // 10%
        uint256 referrerShare = (feeAmount * 1000) / 10000;  // 10%

        if (maker != address(0)) {
            claimableRebates[maker] += makerRebate;
        } else {
            treasuryShare += makerRebate;
        }

        address ref = referrers[taker];
        if (ref != address(0)) {
            claimableRebates[ref] += referrerShare;
        } else {
            treasuryShare += referrerShare;
        }

        if (insuranceShare > 0) {
            _safeTransfer(feeToken, insuranceFund, insuranceShare);
        }
        if (treasuryShare > 0) {
            _safeTransfer(feeToken, treasury, treasuryShare);
        }

        emit FeeDistributed(feeAmount, insuranceShare, treasuryShare, makerRebate, referrerShare);
    }

    /// @notice Claims accrued maker rebates or referral commissions.
    function claimRebates() external returns (uint256 amount) {
        amount = claimableRebates[msg.sender];
        if (amount == 0) revert ValenceFeeDistributor__NoRebateAvailable();

        claimableRebates[msg.sender] = 0;
        _safeTransfer(feeToken, msg.sender, amount);

        emit RebateClaimed(msg.sender, amount);
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            revert ValenceFeeDistributor__TransferFailed();
        }
    }
}
