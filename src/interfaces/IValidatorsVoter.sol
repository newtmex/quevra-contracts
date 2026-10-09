// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {INonStakingVoter} from "./INonStakingVoter.sol";

/// @title IValidatorsVoter
/// @notice Voter surface for allocating one ve collection's power to boost targets.
interface IValidatorsVoter is INonStakingVoter {
    function boostableVe() external view returns (address);
    function setBoostableVe(address boostableVe_) external;
    function boostableTokenIdToGauge(uint256 tokenId) external view returns (address);
    function gaugeToVault(address gauge) external view returns (address);
    function createBoostGauge(uint256 boostableTokenId, address rewardToken) external returns (address gauge);
    function createBoostGauge(uint256 boostableTokenId, address rewardToken, address vault)
        external
        returns (address gauge);
    function pokeBoost(uint256 boostableTokenId) external;
    function pokeBoosts(uint256[] calldata boostableTokenIds) external;
    function poke(uint256 boostableTokenId) external;
    function pokeMany(uint256[] calldata boostableTokenIds) external;
    function getBoost(uint256 boostableTokenId) external view returns (uint256);
    function notifyBoostableBurned(uint256 boostableTokenId) external;
    function syncStakeWeight(uint256 tokenId, address vault) external;
}
