// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {IValidatorsVoter} from "../interfaces/IValidatorsVoter.sol";
import {IProposalGauge} from "../interfaces/IProposalGauge.sol";
import {IVeMON} from "../interfaces/IVeMON.sol";
import {IMonVault} from "../interfaces/IMonVault.sol";
import {IValidatorRegistry} from "../interfaces/IValidatorRegistry.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";
import {ProposalGauge} from "./ProposalGauge.sol";

/// @title ValidatorsVoter
/// @notice veMON votes on registry proposal gauges. Vote clock is a ProtocolTimeLibrary cycle.
contract ValidatorsVoter is Ownable2Step, ReentrancyGuardTransient, IValidatorsVoter {
    uint256 public constant MIN_CANCEL_WEIGHT = 1e18;
    uint256 public constant MAX_GAUGES = 64;
    uint256 public constant MIN_MAX_VOTING_NUM = 10;

    address public immutable override ve;
    address public immutable override vault;
    address public immutable override registry;
    address public immutable override gaugeImplementation;

    uint256 public override totalWeight;
    uint256 public override maxVotingNum = 30;

    address[] internal _gauges;

    mapping(uint256 proposalId => address gauge) public override proposalToGauge;
    mapping(address gauge => uint256 proposalId) public override gaugeToProposal;
    mapping(address gauge => uint256) public override weights;
    mapping(address gauge => bool) public override isGauge;
    mapping(address gauge => bool) public override isAlive;
    mapping(uint64 cycle => mapping(address gauge => uint256)) public override cycleWeights;
    mapping(uint64 cycle => uint256) public override cycleGlobalWeight;
    mapping(uint64 cycle => bool) public override cycleFinalized;
    mapping(uint64 cycle => uint256) public allocateCursor;

    mapping(uint256 tokenId => mapping(address gauge => uint256)) public votes;
    mapping(uint256 tokenId => address[]) internal _gaugeVotes;
    mapping(uint256 tokenId => uint256) public usedWeights;
    /// @dev Cycle+1 of last vote/reset. 0 means never voted.
    mapping(uint256 tokenId => uint64) public lastVoted;
    mapping(uint256 tokenId => bool) public isWhitelistedNFT;

    constructor(address owner_, address ve_, address vault_, address registry_) Ownable(owner_) {
        if (ve_ == address(0) || vault_ == address(0) || registry_ == address(0)) revert ZeroAddress();

        ve = ve_;
        vault = vault_;
        registry = registry_;
        gaugeImplementation = address(new ProposalGauge());
    }

    function renounceOwnership() public pure override {
        revert OwnableInvalidOwner(address(0));
    }

    modifier onlyRegistry() {
        if (msg.sender != registry) revert NotRegistry();
        _;
    }

    modifier onlyNewCycle(uint256 tokenId) {
        uint64 cycle = ProtocolTimeLibrary.currentCycle();
        if (lastVoted[tokenId] == cycle + 1) revert AlreadyVotedOrDeposited();
        _;
    }

    function gaugesLength() external view override returns (uint256) {
        return _gauges.length;
    }

    function gauges(uint256 i) external view returns (address) {
        return _gauges[i];
    }

    function spendCycle() public override returns (uint64) {
        uint64 cycle = ProtocolTimeLibrary.currentCycle();
        if (cycle == 0) return 0;
        return cycle - 1;
    }

    function vote(uint256 tokenId, address[] calldata gaugeVote, uint256[] calldata weights_)
        external
        override
        nonReentrant
        onlyNewCycle(tokenId)
    {
        if (!IVeMON(ve).isApprovedOrOwner(msg.sender, tokenId)) revert NotApprovedOrOwner();
        if (gaugeVote.length != weights_.length) revert UnequalLengths();
        if (gaugeVote.length == 0) revert ZeroLength();
        if (gaugeVote.length > maxVotingNum) revert TooManyGauges();

        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        if (ProtocolTimeLibrary.inDistributeWindow(epoch)) revert DistributeWindow();
        if (ProtocolTimeLibrary.inWhitelistWindow(epoch) && !isWhitelistedNFT[tokenId]) revert NotWhitelistedNFT();

        lastVoted[tokenId] = ProtocolTimeLibrary.cycleOf(epoch) + 1;
        uint256 weight = IVeMON(ve).votingPowerOfNFT(tokenId);
        _vote(tokenId, weight, gaugeVote, weights_);
    }

    function reset(uint256 tokenId) external override nonReentrant onlyNewCycle(tokenId) {
        if (!IVeMON(ve).isApprovedOrOwner(msg.sender, tokenId)) revert NotApprovedOrOwner();
        lastVoted[tokenId] = ProtocolTimeLibrary.currentCycle() + 1;
        _reset(tokenId);
    }

    function poke(uint256 tokenId) external override nonReentrant {
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        if (ProtocolTimeLibrary.inDistributeWindow(epoch)) revert DistributeWindow();

        address[] storage votedGauges = _gaugeVotes[tokenId];
        uint256 n = votedGauges.length;
        if (n == 0) return;

        address[] memory gs = new address[](n);
        uint256[] memory ws = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            gs[i] = votedGauges[i];
            ws[i] = votes[tokenId][gs[i]];
        }
        uint256 weight = IVeMON(ve).votingPowerOfNFT(tokenId);
        _vote(tokenId, weight, gs, ws);
    }

    function onProposalCreated(uint256 proposalId, address proposer) external override nonReentrant onlyRegistry {
        _createGauge(proposalId, proposer);
    }

    function onProposalCancelled(uint256 proposalId) external override nonReentrant onlyRegistry {
        address gauge = proposalToGauge[proposalId];
        if (gauge == address(0)) return;
        if (_cancelWeight(gauge) >= MIN_CANCEL_WEIGHT) revert GaugeHasVotes();
        _killGauge(gauge);
    }

    function onOwnerCancelled(uint256 proposalId) external override nonReentrant onlyRegistry {
        address gauge = proposalToGauge[proposalId];
        if (gauge == address(0)) return;
        _killGauge(gauge);
    }

    function onProposalExecuted(uint256 proposalId, uint64 validatorId) external override onlyRegistry {
        address gauge = proposalToGauge[proposalId];
        if (gauge == address(0)) return;
        IProposalGauge(gauge).setValidatorId(validatorId);
    }

    function syncProposal(uint256 proposalId) external override onlyOwner {
        IValidatorRegistry.Proposal memory proposal = IValidatorRegistry(registry).getProposal(proposalId);
        if (proposal.status != IValidatorRegistry.Status.Proposed) revert NotProposed();
        _createGauge(proposalId, proposal.proposer);
    }

    function finalizeCycle(uint64 cycle) external override nonReentrant {
        uint64 current = ProtocolTimeLibrary.currentCycle();
        if (current <= cycle) revert CycleNotOver();
        if (cycleFinalized[cycle]) revert AlreadyFinalized();

        uint256 n = _gauges.length;
        uint256 global = 0;
        for (uint256 i; i < n; ++i) {
            address gauge = _gauges[i];
            uint256 w = weights[gauge];
            cycleWeights[cycle][gauge] = w;
            global += w;
        }

        cycleGlobalWeight[cycle] = global;
        cycleFinalized[cycle] = true;
        emit CycleFinalized(cycle, global, n);
    }

    function allocate(uint256 maxItems) external override nonReentrant {
        if (maxItems == 0) revert ZeroLength();
        uint64 cycle = spendCycle();
        if (!cycleFinalized[cycle]) revert CycleNotFinalized();

        uint256 n = _gauges.length;
        uint256 cursor = allocateCursor[cycle];
        uint256 end = cursor + maxItems;
        if (end > n) end = n;

        for (uint256 i = cursor; i < end; ++i) {
            address gauge = _gauges[i];
            uint256 proposalId = gaugeToProposal[gauge];
            if (!isAlive[gauge] || cycleWeights[cycle][gauge] == 0) {
                emit AllocateSkipped(proposalId, gauge);
                continue;
            }

            IValidatorRegistry.Proposal memory proposal = IValidatorRegistry(registry).getProposal(proposalId);
            if (proposal.status != IValidatorRegistry.Status.Proposed) {
                emit AllocateSkipped(proposalId, gauge);
                continue;
            }

            try IMonVault(vault).executeProposal(proposalId) returns (uint64 validatorId) {
                emit Allocated(proposalId, gauge, validatorId);
            } catch {
                emit AllocateSkipped(proposalId, gauge);
            }
        }

        allocateCursor[cycle] = end;
    }

    function whitelistNFT(uint256 tokenId, bool allowed) external override onlyOwner {
        isWhitelistedNFT[tokenId] = allowed;
    }

    function setMaxVotingNum(uint256 n) external override onlyOwner {
        if (n < MIN_MAX_VOTING_NUM) revert MaximumVotingNumberTooLow();
        if (n == maxVotingNum) revert SameValue();
        maxVotingNum = n;
    }

    function _createGauge(uint256 proposalId, address proposer) internal {
        if (proposalToGauge[proposalId] != address(0)) revert GaugeExists();
        if (_gauges.length >= MAX_GAUGES) revert TooManyGauges();

        address gauge = Clones.clone(gaugeImplementation);
        IProposalGauge(gauge).initialize(address(this), proposalId, proposer);

        proposalToGauge[proposalId] = gauge;
        gaugeToProposal[gauge] = proposalId;
        isGauge[gauge] = true;
        isAlive[gauge] = true;
        _gauges.push(gauge);

        emit GaugeCreated(gauge, proposalId, proposer);
    }

    function _killGauge(address gauge) internal {
        if (!isGauge[gauge]) revert GaugeDoesNotExist();
        if (!isAlive[gauge]) return;
        isAlive[gauge] = false;
        emit GaugeKilled(gauge, gaugeToProposal[gauge]);
    }

    function _cancelWeight(address gauge) internal returns (uint256 w) {
        w = weights[gauge];
        uint64 cycle = ProtocolTimeLibrary.currentCycle();
        if (cycle > 0) {
            uint256 spend = cycleWeights[cycle - 1][gauge];
            if (spend > w) w = spend;
        }
    }

    function _reset(uint256 tokenId) internal {
        address[] storage votedGauges = _gaugeVotes[tokenId];
        uint256 n = votedGauges.length;
        uint256 total = 0;

        for (uint256 i; i < n; ++i) {
            address gauge = votedGauges[i];
            uint256 v = votes[tokenId][gauge];
            if (v != 0) {
                weights[gauge] -= v;
                delete votes[tokenId][gauge];
                total += v;
                emit Abstained(msg.sender, gauge, tokenId, v, weights[gauge]);
            }
        }

        IVeMON(ve).voting(tokenId, false);
        totalWeight -= total;
        usedWeights[tokenId] = 0;
        delete _gaugeVotes[tokenId];
    }

    function _vote(uint256 tokenId, uint256 weight, address[] memory gaugeVote, uint256[] memory weights_) internal {
        _reset(tokenId);

        uint256 n = gaugeVote.length;
        uint256 totalVoteWeight = 0;
        for (uint256 i; i < n; ++i) {
            totalVoteWeight += weights_[i];
        }
        if (weight == 0 || totalVoteWeight == 0) revert ZeroBalance();

        uint256 used = 0;
        for (uint256 i; i < n; ++i) {
            address gauge = gaugeVote[i];
            if (!isGauge[gauge]) revert GaugeDoesNotExist();
            if (!isAlive[gauge]) revert GaugeNotAlive();

            uint256 gaugeWeight = weight * weights_[i] / totalVoteWeight;
            if (votes[tokenId][gauge] != 0) revert NonZeroVotes();
            if (gaugeWeight == 0) revert ZeroBalance();

            _gaugeVotes[tokenId].push(gauge);
            weights[gauge] += gaugeWeight;
            votes[tokenId][gauge] = gaugeWeight;
            used += gaugeWeight;
            emit Voted(msg.sender, gauge, tokenId, gaugeWeight, weights[gauge]);
        }

        IVeMON(ve).voting(tokenId, true);
        totalWeight += used;
        usedWeights[tokenId] = used;
    }
}
