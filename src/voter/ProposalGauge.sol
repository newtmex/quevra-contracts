// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IProposalGauge} from "../interfaces/IProposalGauge.sol";

/// @title ProposalGauge
/// @notice Cloneable identity for a registry proposal. Implementation constructor locks `initialized`.
contract ProposalGauge is IProposalGauge {
    address public override voter;
    uint256 public override proposalId;
    uint64 public override validatorId;
    address public override proposer;
    bool public override initialized;

    constructor() {
        initialized = true;
    }

    function initialize(address voter_, uint256 proposalId_, address proposer_) external override {
        if (initialized) revert AlreadyInitialized();
        if (voter_ == address(0) || proposer_ == address(0) || proposalId_ == 0) revert ZeroAddress();

        initialized = true;
        voter = voter_;
        proposalId = proposalId_;
        proposer = proposer_;
    }

    function setValidatorId(uint64 id) external override {
        if (msg.sender != voter) revert NotVoter();
        if (validatorId != 0) revert AlreadySet();
        if (id == 0) revert InvalidValidatorId();
        validatorId = id;
    }
}
