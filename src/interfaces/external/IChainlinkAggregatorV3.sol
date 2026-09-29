// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IChainlinkAggregatorV3
/// @notice Minimal Chainlink AggregatorV3Interface (the read side of a price feed proxy), vendored because the
///         Chainlink contracts are not a dependency of this repository.
interface IChainlinkAggregatorV3 {
    /// @notice Number of decimals of `answer`.
    function decimals() external view returns (uint8);

    /// @notice Human-readable pair, for example "ETH / USD".
    function description() external view returns (string memory);

    /// @notice Latest round of the feed.
    /// @return roundId Round id.
    /// @return answer Price with `decimals()` decimals.
    /// @return startedAt Timestamp at which the round started.
    /// @return updatedAt Timestamp at which the answer was last written.
    /// @return answeredInRound Deprecated; equals `roundId` on current aggregators.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
