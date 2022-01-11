// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title ValenceChainlinkAdapter
/// @notice Adapts Chainlink decentralized price feeds into 2^96 fixed point format with round validation.
contract ValenceChainlinkAdapter {
    address public immutable owner;

    struct FeedMetadata {
        address aggregator;
        uint8 decimals;
        bool isConfigured;
    }

    mapping(bytes32 => FeedMetadata) private _feeds;

    event ChainlinkFeedRegistered(bytes32 indexed marketId, address indexed aggregator, uint8 decimals);

    error ValenceChainlinkAdapter__Unauthorized();
    error ValenceChainlinkAdapter__MarketNotConfigured();
    error ValenceChainlinkAdapter__InvalidRoundData();
    error ValenceChainlinkAdapter__ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert ValenceChainlinkAdapter__Unauthorized();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function registerFeed(bytes32 marketId, address aggregator) external onlyOwner {
        if (aggregator == address(0)) revert ValenceChainlinkAdapter__ZeroAddress();
        uint8 dec = IAggregatorV3(aggregator).decimals();

        _feeds[marketId] = FeedMetadata({
            aggregator: aggregator,
            decimals: dec,
            isConfigured: true
        });

        emit ChainlinkFeedRegistered(marketId, aggregator, dec);
    }

    /// @notice Returns the validated price in 2^96 fixed point along with timestamp.
    function getPrice(bytes32 marketId) external view returns (uint256 priceX96, uint64 timestamp) {
        FeedMetadata memory meta = _feeds[marketId];
        if (!meta.isConfigured) revert ValenceChainlinkAdapter__MarketNotConfigured();

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IAggregatorV3(meta.aggregator).latestRoundData();

        if (answer <= 0 || updatedAt == 0 || answeredInRound < roundId) {
            revert ValenceChainlinkAdapter__InvalidRoundData();
        }

        uint256 rawAnswer = uint256(answer);
        timestamp = uint64(updatedAt);

        // Normalize rawAnswer to 2^96: (rawAnswer * 2^96) / 10^decimals
        priceX96 = (rawAnswer << 96) / (10 ** meta.decimals);
    }
}
