// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";
import {IValidatorRegistry} from "./interfaces/IValidatorRegistry.sol";

/// @title StakingVault
/// @notice MON vault bound to exactly one validator.
contract StakingVault is Ownable2Step, ReentrancyGuardTransient {
    IValidatorRegistry public immutable registry;
    IMonadStaking public immutable staking;

    /// @notice The only validator request this vault can execute.
    uint256 public immutable requestId;

    /// @notice Set after the request is successfully executed.
    uint64 public validatorId;

    error ValidatorAlreadyAdded();
    error ValidatorNotAdded();
    error InvalidRequest();
    error AddValidatorFailed();
    error DelegationFailed();

    constructor(address owner_, address registry_, uint256 requestId_) Ownable(owner_) {
        if (registry_ == address(0) || requestId_ == 0) {
            revert InvalidRequest();
        }

        registry = IValidatorRegistry(registry_);
        staking = registry.staking();
        requestId = requestId_;
    }

    /// @notice Add the vault's bound validator.
    function addValidator(uint256 commission)
        external
        payable
        nonReentrant
        onlyOwner
        returns (uint64 addedValidatorId)
    {
        if (validatorId != 0) {
            revert ValidatorAlreadyAdded();
        }

        addedValidatorId = registry.addValidator{value: msg.value}(requestId, commission);

        if (addedValidatorId == 0) {
            revert AddValidatorFailed();
        }

        validatorId = addedValidatorId;
    }

    /// @notice Delegate MON to this vault's validator.
    function delegate() external payable nonReentrant onlyOwner returns (bool success) {
        uint64 id = validatorId;

        if (id == 0) {
            revert ValidatorNotAdded();
        }

        success = staking.delegate{value: msg.value}(id);

        if (!success) {
            revert DelegationFailed();
        }
    }

    receive() external payable {}
}
