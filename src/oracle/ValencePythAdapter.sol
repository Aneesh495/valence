// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title ValencePythAdapter
/// @notice Decodes low-latency Pyth Network price feeds and normalizes them into 2^96 fixed point format.
contract ValencePythAdapter {
    address public immutable owner;

    struct PythPriceFeed {
        bytes32 priceFeedId;
        int64 price;
        uint64 conf;
        int32 expo;
        uint64 publishTime;
    }

    mapping(bytes32 => PythPriceFeed) private _feeds;
    mapping(bytes32 => bool) public isSupportedMarket;

    event PythFeedUpdated(bytes32 indexed marketId, int64 price, int32 expo, uint64 publishTime);

    error ValencePythAdapter__Unauthorized();
    error ValencePythAdapter__MarketNotSupported();
    error ValencePythAdapter__InvalidPrice();

    modifier onlyOwner() {
        if (msg.sender != owner) revert ValencePythAdapter__Unauthorized();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function registerMarket(bytes32 marketId, bytes32 priceFeedId) external onlyOwner {
        isSupportedMarket[marketId] = true;
        _feeds[marketId].priceFeedId = priceFeedId;
    }

    /// @notice Updates the stored Pyth feed observation (simulates Pyth contract update).
    function updateFeed(
        bytes32 marketId,
        int64 price,
        uint64 conf,
        int32 expo,
        uint64 publishTime
    ) external onlyOwner {
        if (!isSupportedMarket[marketId]) revert ValencePythAdapter__MarketNotSupported();
        if (price <= 0) revert ValencePythAdapter__InvalidPrice();

        _feeds[marketId] = PythPriceFeed({
            priceFeedId: _feeds[marketId].priceFeedId,
            price: price,
            conf: conf,
            expo: expo,
            publishTime: publishTime
        });

        emit PythFeedUpdated(marketId, price, expo, publishTime);
    }

    /// @notice Returns price normalized to 2^96 fixed point along with publication timestamp.
    function getPrice(bytes32 marketId) external view returns (uint256 priceX96, uint64 timestamp) {
        if (!isSupportedMarket[marketId]) revert ValencePythAdapter__MarketNotSupported();
        PythPriceFeed memory feed = _feeds[marketId];
        if (feed.price <= 0) revert ValencePythAdapter__InvalidPrice();

        uint256 rawPrice = uint256(uint64(feed.price));
        timestamp = feed.publishTime;

        // Normalize exponent to 2^96
        // priceX96 = price * 10^expo * 2^96
        if (feed.expo >= 0) {
            priceX96 = (rawPrice * (10 ** uint32(feed.expo))) << 96;
        } else {
            uint32 negExpo = uint32(-feed.expo);
            priceX96 = (rawPrice << 96) / (10 ** negExpo);
        }
    }
}
