// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBaseVoter} from "./IBaseVoter.sol";

/// @title IBoostVoter
/// @notice Voter surface for allocating one ve collection's power to boost targets.
interface IBoostVoter is IBaseVoter {
    function boostableVe() external view returns (address);
    function boostableTokenIdToGauge(uint256 tokenId) external view returns (address);
    function boostableTokenIdToBribeVotingRewards(uint256 tokenId) external view returns (address);
    function createBoostGauge(uint256 boostableTokenId, address rewardToken) external returns (address gauge);
    function notifyGaugeReward(address gauge, uint256 amount) external;
    function vote(uint256 tokenId, address[] calldata targets, uint256[] calldata weights) external;
    function reset(uint256 tokenId) external;
    function pokeBoost(uint256 boostableTokenId) external;
    function pokeBoosts(uint256[] calldata boostableTokenIds) external;
    function poke(uint256 boostableTokenId) external;
    function pokeMany(uint256[] calldata boostableTokenIds) external;
    function getBoost(uint256 boostableTokenId) external view returns (uint256);
    function notifyBoostableBurned(uint256 boostableTokenId) external;
}
