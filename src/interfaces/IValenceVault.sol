// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title IValenceVault
/// @notice Multi-asset custody vault supporting ERC-20 tokens, ERC-4626 yield assets, and debt accounting.
interface IValenceVault {
    event CollateralDeposited(bytes32 indexed subaccountId, address indexed asset, uint256 amount);
    event CollateralWithdrawn(bytes32 indexed subaccountId, address indexed asset, uint256 amount, address indexed recipient);
    event AssetWhitelisted(address indexed asset, uint16 riskTier, uint32 haircutFactor);
    event AssetDelisted(address indexed asset);

    struct AssetConfig {
        bool isWhitelisted;
        bool isYieldBearing;
        uint16 riskTier; // 1 = ultra-safe (e.g. USDC), 5 = high-beta volatile
        uint32 haircutFactor; // Haircut in basis points (e.g. 1000 = 10% haircut, 90% collateral value)
        uint256 maxDepositCap;
        uint256 totalDeposited;
    }

    function deposit(bytes32 subaccountId, address asset, uint256 amount) external;
    function withdraw(bytes32 subaccountId, address asset, uint256 amount, address recipient) external;
    function transferInternal(bytes32 fromSubaccount, bytes32 toSubaccount, address asset, uint256 amount) external;
    
    function getCollateralBalance(bytes32 subaccountId, address asset) external view returns (uint256);
    function getSubaccountCollateralValue(bytes32 subaccountId) external view returns (uint256 totalValueUsd, uint256 haircutValueUsd);
    function isWhitelistedAsset(address asset) external view returns (bool);
    function getAssetConfig(address asset) external view returns (AssetConfig memory);
}
