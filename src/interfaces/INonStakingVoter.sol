// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBaseVoter} from "./IBaseVoter.sol";

/// @title INonStakingVoter
/// @notice Shared read and mutation API for voters whose gauges do not stake.
interface INonStakingVoter is IBaseVoter {
    error AlreadyVotedOrDeposited();
    error GaugeDoesNotExist(address gauge);
    error GaugeExists();
    error NotApprovedOrOwner();
    error NotWhitelistedToken();
    error UnequalLengths();
    error ZeroAddress();
    error ZeroBalance();

    event Voted(address indexed voter, address indexed gauge, uint256 indexed tokenId, uint256 weight);
    event Abstained(address indexed voter, address indexed gauge, uint256 indexed tokenId, uint256 weight);
    event WhitelistToken(address indexed whitelister, address indexed token, bool indexed whitelisted);

    function isGauge(address gauge) external view returns (bool);
    function gaugeToBribe(address gauge) external view returns (address);
    function weights(address gauge) external view returns (uint256);
    function votes(uint256 tokenId, address gauge) external view returns (uint256);
    function gaugeVote(uint256 tokenId, uint256 index) external view returns (address);
    function usedWeights(uint256 tokenId) external view returns (uint256);
    function lastVoted(uint256 tokenId) external view returns (uint256);
    function whitelistToken(address token, bool whitelisted) external;
    function notifyGaugeReward(address gauge, uint256 amount) external;
    function vote(uint256 tokenId, address[] calldata targets, uint256[] calldata weights) external;
    function reset(uint256 tokenId) external;
}
