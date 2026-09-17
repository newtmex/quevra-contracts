// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {IMonVault} from "../interfaces/IMonVault.sol";
import {IWMON} from "../interfaces/IWMON.sol";
import {IValidatorRegistry} from "../interfaces/IValidatorRegistry.sol";

/// @title MonVault
/// @notice Unwraps veMON principal to native MON and executes registry proposals as `authAddress`.
contract MonVault is Ownable2Step, ReentrancyGuardTransient, IMonVault {
    address public immutable override wmon;

    address public override ve;
    address public override voter;
    address public override registry;

    constructor(address owner_, address wmon_) Ownable(owner_) {
        if (wmon_ == address(0)) revert ZeroAddress();
        wmon = wmon_;
    }

    receive() external payable {}

    function renounceOwnership() public pure override {
        revert OwnableInvalidOwner(address(0));
    }

    function setVe(address ve_) external override onlyOwner {
        if (ve_ == address(0)) revert ZeroAddress();
        if (ve != address(0)) revert AlreadySet();
        ve = ve_;
        emit VeSet(ve_);
    }

    function setVoter(address voter_) external override onlyOwner {
        if (voter_ == address(0)) revert ZeroAddress();
        if (voter != address(0)) revert AlreadySet();
        voter = voter_;
        emit VoterSet(voter_);
    }

    function setRegistry(address registry_) external override onlyOwner {
        if (registry_ == address(0)) revert ZeroAddress();
        if (registry != address(0)) revert AlreadySet();
        registry = registry_;
        emit RegistrySet(registry_);
    }

    function onLock(uint256 amount) external override nonReentrant {
        if (msg.sender != ve) revert NotVe();
        IWMON(wmon).withdraw(amount);
    }

    function onUnlock(address to, uint256 amount) external override nonReentrant {
        if (msg.sender != ve) revert NotVe();
        if (address(this).balance < amount) revert InsufficientLiquidity();
        Address.sendValue(payable(to), amount);
    }

    function executeProposal(uint256 proposalId) external override nonReentrant returns (uint64 validatorId) {
        if (msg.sender != voter) revert NotVoter();

        IValidatorRegistry.Proposal memory proposal = IValidatorRegistry(registry).getProposal(proposalId);
        if (proposal.status != IValidatorRegistry.Status.Proposed) revert NotProposed();
        if (address(this).balance < proposal.amount) revert InsufficientLiquidity();

        validatorId = IValidatorRegistry(registry).execute{value: proposal.amount}(proposalId);
        emit ProposalExecuted(proposalId, validatorId, proposal.amount);
    }
}
