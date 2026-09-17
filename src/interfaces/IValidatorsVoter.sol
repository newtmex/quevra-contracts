// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IValidatorsVoter
/// @notice veMON weight on one gauge per registry proposal. Vote clock is a ProtocolTimeLibrary cycle.
interface IValidatorsVoter {
    event GaugeCreated(address indexed gauge, uint256 indexed proposalId, address indexed proposer);
    event GaugeKilled(address indexed gauge, uint256 indexed proposalId);
    event Voted(
        address indexed voter, address indexed gauge, uint256 indexed tokenId, uint256 weight, uint256 gaugeWeight
    );
    event Abstained(
        address indexed voter, address indexed gauge, uint256 indexed tokenId, uint256 weight, uint256 gaugeWeight
    );
    event CycleFinalized(uint64 indexed cycle, uint256 globalWeight, uint256 gauges);
    event Allocated(uint256 indexed proposalId, address indexed gauge, uint64 validatorId);
    event AllocateSkipped(uint256 indexed proposalId, address indexed gauge);

    error ZeroAddress();
    error AlreadyVotedOrDeposited();
    error DistributeWindow();
    error NotApprovedOrOwner();
    error UnequalLengths();
    error ZeroLength();
    error TooManyGauges();
    error ZeroBalance();
    error GaugeDoesNotExist();
    error GaugeNotAlive();
    error GaugeExists();
    error NonZeroVotes();
    error NotWhitelistedNFT();
    error NotRegistry();
    error GaugeHasVotes();
    error AlreadyFinalized();
    error CycleNotOver();
    error CycleNotFinalized();
    error MaximumVotingNumberTooLow();
    error SameValue();
    error NotProposed();

    function ve() external view returns (address);
    function vault() external view returns (address);
    function registry() external view returns (address);
    function gaugeImplementation() external view returns (address);
    function proposalToGauge(uint256 proposalId) external view returns (address);
    function gaugeToProposal(address gauge) external view returns (uint256);
    function weights(address gauge) external view returns (uint256);
    function totalWeight() external view returns (uint256);
    function isAlive(address gauge) external view returns (bool);
    function isGauge(address gauge) external view returns (bool);
    function cycleWeights(uint64 cycle, address gauge) external view returns (uint256);
    function cycleGlobalWeight(uint64 cycle) external view returns (uint256);
    function cycleFinalized(uint64 cycle) external view returns (bool);
    /// @dev Last fully finished vote cycle. Not `view` (`getEpoch` is CALL-only).
    function spendCycle() external returns (uint64);
    function maxVotingNum() external view returns (uint256);
    function gaugesLength() external view returns (uint256);

    function vote(uint256 tokenId, address[] calldata gauges, uint256[] calldata weights_) external;
    function reset(uint256 tokenId) external;
    function poke(uint256 tokenId) external;

    function onProposalCreated(uint256 proposalId, address proposer) external;
    function onProposalCancelled(uint256 proposalId) external;
    function onOwnerCancelled(uint256 proposalId) external;
    function onProposalExecuted(uint256 proposalId, uint64 validatorId) external;
    function syncProposal(uint256 proposalId) external;

    function finalizeCycle(uint64 cycle) external;
    function allocate(uint256 maxItems) external;

    function whitelistNFT(uint256 tokenId, bool allowed) external;
    function setMaxVotingNum(uint256 n) external;
}
