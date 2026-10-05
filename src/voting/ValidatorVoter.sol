// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StakingRewards} from "../rewards/StakingRewards.sol";
import {StakingVault} from "../staking/controlled/StakingVault.sol";
import {IValidatorRegistry} from "../interfaces/IValidatorRegistry.sol";
import {IStakingController} from "../interfaces/IStakingController.sol";

/// @title ValidatorVoter
/// @notice Validator-to-stakingRewards lifecycle and canonical voting-target registry.
/// @dev StakingController inherits this layer so validator admission, vault
///      setup, stakingRewards registration, and stake-backed stakingRewards weight share one lifecycle.
///      veMON vote selection is added in a later stage.
abstract contract ValidatorVoter {
    IValidatorRegistry private immutable _validatorRegistry;

    mapping(uint256 requestId => address stakingRewards) public stakingRewardsForRequest;
    mapping(address stakingRewards => uint256 requestId) public requestForStakingRewards;
    mapping(address stakingRewards => address vault) public vaultForStakingRewards;
    mapping(address stakingRewards => bool registered) public isStakingRewards;
    address[] private _stakingRewards;

    constructor(address validatorRegistry_) {
        if (validatorRegistry_ == address(0)) revert IStakingController.InvalidValidatorRegistry();
        _validatorRegistry = IValidatorRegistry(validatorRegistry_);
    }

    /// @dev Requests remain authoritative in the separately deployed registry.
    function _getValidatorSubmission(uint256 requestId) internal view returns (IValidatorRegistry.Submission memory) {
        return _validatorRegistry.getSubmission(requestId);
    }

    /// @notice Number of canonical Quevra validator vaults.
    function stakingRewardsCount() external view returns (uint256) {
        return _stakingRewards.length;
    }

    /// @notice Canonical validator stakingRewards at `index`.
    function stakingRewardsAt(uint256 index) external view returns (address) {
        return _stakingRewards[index];
    }

    /// @notice Resolve a registered stakingRewards to its request, vault, and current validator ID.
    /// @dev `validatorId` is zero until a new-validator request is activated by staking.
    function validatorForStakingRewards(address stakingRewards)
        external
        view
        returns (uint256 requestId, address vault, uint64 validatorId, address operator)
    {
        if (!isStakingRewards[stakingRewards]) revert IStakingController.InvalidStakingRewards();
        requestId = requestForStakingRewards[stakingRewards];
        vault = vaultForStakingRewards[stakingRewards];
        validatorId = StakingVault(payable(vault)).validatorId();
        operator = StakingRewards(stakingRewards).operator();
    }

    function stakingRewardsForValidatorId(uint64 validatorId) public view returns (address stakingRewards) {
        if (validatorId == 0) return address(0);
        for (uint256 i; i < _stakingRewards.length; ++i) {
            address candidate = _stakingRewards[i];
            if (StakingVault(payable(vaultForStakingRewards[candidate])).validatorId() == validatorId) {
                return candidate;
            }
        }
    }

    function _registerStakingRewards(uint256 requestId, address operator, address vault, uint64 validatorId)
        internal
        returns (address stakingRewards)
    {
        if (requestId == 0 || operator == address(0) || vault == address(0)) {
            revert IStakingController.InvalidStakingRewards();
        }
        if (stakingRewardsForRequest[requestId] != address(0)) {
            revert IStakingController.StakingRewardsAlreadyExists(requestId);
        }
        if (validatorId != 0 && stakingRewardsForValidatorId(validatorId) != address(0)) {
            revert IStakingController.ValidatorAlreadyRegistered(validatorId);
        }

        stakingRewards = address(new StakingRewards(address(this), requestId, operator));
        stakingRewardsForRequest[requestId] = stakingRewards;
        requestForStakingRewards[stakingRewards] = requestId;
        vaultForStakingRewards[stakingRewards] = vault;
        isStakingRewards[stakingRewards] = true;
        _stakingRewards.push(stakingRewards);

        emit IStakingController.StakingRewardsRegistered(requestId, validatorId, stakingRewards, vault, operator);
    }

    function _increaseStakingRewardsWeight(address stakingRewards, uint256 tokenId, uint256 amount) internal {
        if (!isStakingRewards[stakingRewards]) revert IStakingController.InvalidStakingRewards();
        StakingRewards(stakingRewards)._deposit(amount, tokenId);
    }

    function _decreaseStakingRewardsWeight(address stakingRewards, uint256 tokenId, uint256 amount) internal {
        if (!isStakingRewards[stakingRewards]) revert IStakingController.InvalidStakingRewards();
        StakingRewards(stakingRewards)._withdraw(amount, tokenId);
    }
}
