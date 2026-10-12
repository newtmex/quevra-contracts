// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {INonStakingVoter} from "./INonStakingVoter.sol";

/// @title IValidatorsVoter
/// @notice Voter surface for allocating one ve collection's power to boost targets.
interface IValidatorsVoter is INonStakingVoter {
    /// @notice A validator-linked gauge's vote weight was synchronized from stake allocation.
    event StakeVoteSynced(
        uint256 indexed tokenId, address indexed gauge, uint256 allocation, uint256 oldWeight, uint256 newWeight
    );

    /// @notice veValidator collection whose positions create validator gauges.
    function boostableVe() external view returns (address);
    /// @notice Binds the veValidator collection once; owner only.
    function setBoostableVe(address boostableVe_) external;
    /// @notice Validator gauge associated with a veValidator token ID.
    function boostableTokenIdToGauge(uint256 tokenId) external view returns (address);
    /// @notice Validator vault associated with a gauge.
    function gaugeToVault(address gauge) external view returns (address);
    /// @notice Creates a gauge and bribe rewards for a validator position.
    function createBoostGauge(uint256 boostableTokenId, address rewardToken) external returns (address gauge);
    /// @notice Creates a gauge and bribe rewards and binds them to a validator vault.
    function createBoostGauge(uint256 boostableTokenId, address rewardToken, address vault)
        external
        returns (address gauge);
    /// @notice Refreshes one veValidator position's stored boost.
    function pokeBoost(uint256 boostableTokenId) external;
    /// @notice Refreshes boosts for a list of veValidator positions.
    function pokeBoosts(uint256[] calldata boostableTokenIds) external;
    /// @notice Alias for refreshing one veValidator position's boost.
    function poke(uint256 boostableTokenId) external;
    /// @notice Alias for refreshing boosts for a list of positions.
    function pokeMany(uint256[] calldata boostableTokenIds) external;
    /// @notice Current calculated boost for a veValidator position.
    function getBoost(uint256 boostableTokenId) external view returns (uint256);
    /// @notice Removes a burned validator position's gauge; callable by veValidator.
    function notifyBoostableBurned(uint256 boostableTokenId) external;
    /// @notice Syncs the veMON vote and bribe balance for a vault from current physical MON allocation.
    function syncStakeAllocation(uint256 tokenId, address vault, uint256 allocation) external;
}
