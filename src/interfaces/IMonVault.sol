// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMonVault
/// @notice Backing pool: unwraps locked WMON to native MON and executes registry proposals as `authAddress`.
interface IMonVault {
    event ProposalExecuted(uint256 indexed proposalId, uint64 indexed validatorId, uint256 amount);

    error ZeroAddress();
    error NotVe();
    error NotVoter();
    error InsufficientLiquidity();
    error NotProposed();

    function wmon() external view returns (address);
    function ve() external view returns (address);
    function voter() external view returns (address);
    function registry() external view returns (address);

    function onLock(uint256 amount) external;
    function onUnlock(address to, uint256 amount) external;
    function executeProposal(uint256 proposalId) external returns (uint64 validatorId);
}
