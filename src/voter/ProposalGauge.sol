// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IProposalGauge} from "../interfaces/IProposalGauge.sol";

/// @title ProposalGauge
/// @notice Identity for a registry proposal.
contract ProposalGauge is IProposalGauge {
    address public immutable override voter;
    uint256 public immutable override proposalId;
    address public immutable override proposer;

    uint64 public override validatorId;

    constructor(address voter_, uint256 proposalId_, address proposer_) {
        if (voter_ == address(0) || proposer_ == address(0) || proposalId_ == 0) revert ZeroAddress();

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
