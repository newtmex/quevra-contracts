// SPDX-License-Identifier: MIT
// Derived from Tigris INonStakingVoter.sol.
pragma solidity ^0.8.24;

import {IBaseVoter} from "./IBaseVoter.sol";

/// @title INonStakingVoter
/// @notice Shared read and mutation API for voters whose gauges do not stake.
interface INonStakingVoter is IBaseVoter {
    error GaugeDoesNotExist(address gauge);
    error GaugeExists();
    error NotApprovedOrOwner();
    error NotWhitelistedToken();
    error ZeroAddress();

    /// @notice An owner changed whether a token is approved as an incentive asset.
    event WhitelistToken(address indexed whitelister, address indexed token, bool indexed whitelisted);

    /// @notice Whether an address is a registered gauge.
    function isGauge(address gauge) external view returns (bool);
    /// @notice Bribe reward contract associated with a gauge.
    function gaugeToBribe(address gauge) external view returns (address);
    /// @notice Total current voting weight assigned to a gauge.
    function weights(address gauge) external view returns (uint256);
    /// @notice Voting weight assigned to a gauge by a token ID.
    function votes(uint256 tokenId, address gauge) external view returns (uint256);
    /// @notice Gauge at an index in a token ID's active vote list.
    function gaugeVote(uint256 tokenId, uint256 index) external view returns (address);
    /// @notice Sum of a token ID's current voting weights.
    function usedWeights(uint256 tokenId) external view returns (uint256);
    /// @notice Enables or disables a token as a supported reward asset; owner only.
    function whitelistToken(address token, bool whitelisted) external;
    /// @notice Routes a reward-token funding amount to the specified gauge.
    function notifyGaugeReward(address gauge, uint256 amount) external;
}
