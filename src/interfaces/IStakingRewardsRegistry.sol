// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Read API for the canonical validator stakingRewards registry.
interface IStakingRewardsRegistry {
    function stakingRewardsForRequest(uint256 requestId) external view returns (address stakingRewards);
    function requestForStakingRewards(address stakingRewards) external view returns (uint256 requestId);
    function vaultForStakingRewards(address stakingRewards) external view returns (address vault);
    function stakingRewardsForValidatorId(uint64 validatorId) external view returns (address stakingRewards);
    function isStakingRewards(address stakingRewards) external view returns (bool registered);
    function stakingRewardsCount() external view returns (uint256);
    function stakingRewardsAt(uint256 index) external view returns (address stakingRewards);
    function validatorForStakingRewards(address stakingRewards)
        external
        view
        returns (uint256 requestId, address vault, uint64 validatorId, address operator);
}
