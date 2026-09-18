// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IProposalGauge
/// @notice Identity handle for a registry proposal. Not a Mezo NonStakingGauge.
interface IProposalGauge {
    error AlreadySet();
    error NotVoter();
    error ZeroAddress();
    error InvalidValidatorId();

    function voter() external view returns (address);
    function proposalId() external view returns (uint256);
    function validatorId() external view returns (uint64);
    function proposer() external view returns (address);

    function setValidatorId(uint64 id) external;
}
