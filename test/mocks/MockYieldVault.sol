// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC4626} from "../../src/interfaces/IERC4626.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

contract MockYieldVault is IERC4626 {
    address public override asset;
    string public override name = "Mock Yield Vault";
    string public override symbol = "yMOCK";
    uint8 public override decimals = 18;

    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    uint256 public exchangeRate = 1e18; // 1 share = 1 asset initially

    constructor(address _asset) {
        asset = _asset;
    }

    function setExchangeRate(uint256 _rate) external {
        exchangeRate = _rate;
    }

    function totalAssets() public view override returns (uint256) {
        return (totalSupply * exchangeRate) / 1e18;
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        return (assets * 1e18) / exchangeRate;
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return (shares * exchangeRate) / 1e18;
    }

    function maxDeposit(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function previewDeposit(uint256 assets) external view override returns (uint256) {
        return convertToShares(assets);
    }

    function deposit(uint256 assets, address receiver) external override returns (uint256 shares) {
        shares = convertToShares(assets);
        totalSupply += shares;
        balanceOf[receiver] += shares;
        IERC20(asset).transferFrom(msg.sender, address(this), assets);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function maxMint(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function previewMint(uint256 shares) external view override returns (uint256) {
        return convertToAssets(shares);
    }

    function mint(uint256 shares, address receiver) external override returns (uint256 assets) {
        assets = convertToAssets(shares);
        totalSupply += shares;
        balanceOf[receiver] += shares;
        IERC20(asset).transferFrom(msg.sender, address(this), assets);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function maxWithdraw(address owner) external view override returns (uint256) {
        return convertToAssets(balanceOf[owner]);
    }

    function previewWithdraw(uint256 assets) external view override returns (uint256) {
        return convertToShares(assets);
    }

    function withdraw(uint256 assets, address receiver, address owner) external override returns (uint256 shares) {
        shares = convertToShares(assets);
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        IERC20(asset).transfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function maxRedeem(address owner) external view override returns (uint256) {
        return balanceOf[owner];
    }

    function previewRedeem(uint256 shares) external view override returns (uint256) {
        return convertToAssets(shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external override returns (uint256 assets) {
        assets = convertToAssets(shares);
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        IERC20(asset).transfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function transfer(address to, uint256 value) external override returns (bool) {
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external override returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external override returns (bool) {
        uint256 currentAllowance = allowance[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            allowance[from][msg.sender] = currentAllowance - value;
        }
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        return true;
    }

    function permit(address owner, address spender, uint256 value, uint256, uint8, bytes32, bytes32) external override {
        allowance[owner][spender] = value;
    }
}
