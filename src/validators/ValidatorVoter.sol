// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IValidatorRegistry} from "../interfaces/IValidatorRegistry.sol";
import {IValidatorVoter} from "../interfaces/IValidatorVoter.sol";
import {ValidatorGauge} from "./ValidatorGauge.sol";
import {StakingController} from "../staking/StakingController.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ValidatorVoter
/// @notice Creates and tracks validator vault/gauge pairs around a registry request.
/// @dev The registry owns all validator-request state. This voter only owns the
///      request-to-deployment index needed to cancel its own deployments.
contract ValidatorVoter is IValidatorVoter, Ownable {
    IValidatorRegistry public immutable registry;
    StakingController public immutable controller;
    IVotingEscrow public immutable escrow;

    mapping(uint256 requestId => ValidatorStack) private _stacks;
    mapping(address token => bool) public override isRewardTokenWhitelisted;
    mapping(uint256 requestId => mapping(uint256 cycle => bool accepted)) public override validatorAccepted;
    mapping(uint256 cycle => bool finalized) public cycleFinalized;
    mapping(uint256 tokenId => mapping(uint256 cycle => mapping(address gauge => uint256 weight))) private
        _voterWeights;
    mapping(address gauge => mapping(uint256 cycle => uint256 weight)) public override totalGaugeWeight;
    mapping(uint256 tokenId => mapping(uint256 cycle => address[] gauges)) private _votedGauges;
    mapping(uint256 tokenId => mapping(uint256 cycle => bool voted)) private _hasVoted;

    event ValidatorStackCancelled(uint256 indexed requestId, address indexed operator, address vault, address gauge);
    event RewardTokenWhitelistUpdated(address indexed token, bool whitelisted);
    event ValidatorAcceptanceUpdated(uint256 indexed requestId, uint256 indexed cycle, bool accepted);
    event CycleFinalized(uint256 indexed cycle, uint256 capacity, uint256 acceptedCount);

    error InvalidRegistry();
    error InvalidRewardToken();
    error NoStack();
    error InvalidVote();
    error NotPositionOwner();
    error VoteWindowClosed();
    error ValidatorNotAccepted();
    error CycleNotEnded();
    error CycleAlreadyFinalized();

    constructor(address registry_, address controller_, address escrow_) Ownable(msg.sender) {
        if (registry_ == address(0) || controller_ == address(0) || escrow_ == address(0)) revert InvalidRegistry();
        registry = IValidatorRegistry(registry_);
        controller = StakingController(payable(controller_));
        escrow = IVotingEscrow(escrow_);
    }

    function setRewardTokenWhitelisted(address token, bool whitelisted) external onlyOwner {
        if (token == address(0)) revert InvalidRewardToken();
        isRewardTokenWhitelisted[token] = whitelisted;
        emit RewardTokenWhitelistUpdated(token, whitelisted);
    }

    function setValidatorAccepted(uint256 requestId, uint256 cycle, bool accepted) external onlyOwner {
        if (_stacks[requestId].gauge == address(0)) revert NoStack();
        if (ProtocolTimeLibrary.currentCycle() != cycle) revert VoteWindowClosed();
        if (cycleFinalized[cycle]) revert CycleAlreadyFinalized();
        validatorAccepted[requestId][cycle] = accepted;
        emit ValidatorAcceptanceUpdated(requestId, cycle, accepted);
    }

    /// @notice Finalize this cycle's validator set by finalized vote weight,
    /// limited by the controller's current economic capacity.
    function finalizeCycle(uint256 cycle) external {
        if (ProtocolTimeLibrary.currentCycle() <= cycle) revert CycleNotEnded();
        if (cycleFinalized[cycle]) revert CycleAlreadyFinalized();
        cycleFinalized[cycle] = true;

        uint256 capacity = controller.maxAdmissibleValidators();
        uint256 end = registry.nextId();
        uint256 count = 0;
        for (uint256 id = 1; id < end; ++id) {
            ValidatorStack storage stack = _stacks[id];
            if (stack.gauge != address(0)) {
                IValidatorRegistry.Submission memory submission = registry.getSubmission(id);
                if (submission.status == IValidatorRegistry.Status.Submitted) ++count;
            }
        }

        uint256[] memory ids = new uint256[](count);
        uint256[] memory weights = new uint256[](count);
        uint256 cursor = 0;
        for (uint256 id = 1; id < end; ++id) {
            ValidatorStack storage stack = _stacks[id];
            if (stack.gauge == address(0)) continue;
            IValidatorRegistry.Submission memory submission = registry.getSubmission(id);
            if (submission.status != IValidatorRegistry.Status.Submitted) continue;
            uint256 weight = totalGaugeWeight[stack.gauge][cycle];
            uint256 at = cursor;
            while (at != 0 && weights[at - 1] < weight) {
                weights[at] = weights[at - 1];
                ids[at] = ids[at - 1];
                --at;
            }
            weights[at] = weight;
            ids[at] = id;
            ++cursor;
        }

        uint256 acceptedCount = capacity < count ? capacity : count;
        for (uint256 i; i < count; ++i) {
            bool accepted = i < acceptedCount;
            validatorAccepted[ids[i]][cycle] = accepted;
            emit ValidatorAcceptanceUpdated(ids[i], cycle, accepted);
        }
        emit CycleFinalized(cycle, capacity, acceptedCount);
    }

    /// @notice Requests a validator from the registry and deploys its vault and gauge.
    function createValidator(
        address expectedAuthAddress,
        bytes calldata secpPubkey,
        bytes calldata blsPubkey,
        bytes calldata signedSecpMessage,
        bytes calldata signedBlsMessage
    ) external returns (uint256 requestId, address vault, address gauge) {
        requestId = registry.requestValidatorFor(msg.sender, secpPubkey, blsPubkey, signedSecpMessage, signedBlsMessage);
        gauge =
            address(new ValidatorGauge(address(registry), expectedAuthAddress, msg.sender, requestId, address(this)));
        vault = controller.deployVault(requestId, msg.sender, expectedAuthAddress, gauge);
        _stacks[requestId] = ValidatorStack(vault, gauge, 0, msg.sender);
        emit ValidatorGaugeCreated(requestId, 0, msg.sender, vault, gauge);
    }

    /// @notice Cancels the registry request and removes this voter's deployment index.
    /// @dev Cancellation is available only before any weight is routed. The
    ///      controller clears its pool configuration before the registry request
    ///      is cancelled; a revert rolls back both actions.
    function cancel(uint256 requestId) external {
        ValidatorStack memory stack = _stacks[requestId];
        if (stack.vault == address(0)) revert NoStack();

        if (msg.sender != stack.operator) revert NotRequestOperator();

        controller.cancelVault(requestId);
        registry.cancel(requestId);
        delete _stacks[requestId];
        emit ValidatorStackCancelled(requestId, msg.sender, stack.vault, stack.gauge);
    }

    function stackByRequest(uint256 requestId) external view override returns (ValidatorStack memory) {
        return _stacks[requestId];
    }

    function vote(uint256 tokenId, address[] calldata gauges, uint256[] calldata weights) external override {
        _requirePositionAuthority(tokenId);
        uint256 cycle = _votingCycle();
        if (gauges.length == 0 || gauges.length != weights.length) revert InvalidVote();
        _clearVote(tokenId, cycle);

        uint256 totalInput;
        for (uint256 i; i < weights.length; ++i) {
            if (weights[i] == 0) revert InvalidVote();
            totalInput += weights[i];
        }
        uint256 power = escrow.votingPowerOf(tokenId);
        if (power == 0 || totalInput == 0) revert InvalidVote();

        uint256 allocated;
        for (uint256 i; i < gauges.length; ++i) {
            address gauge = gauges[i];
            uint256 requestId = ValidatorGauge(gauge).requestId();
            if (_stacks[requestId].gauge != gauge) revert UnknownStack();
            for (uint256 j; j < i; ++j) {
                if (gauges[j] == gauge) revert InvalidVote();
            }
            uint256 amount = i + 1 == gauges.length ? power - allocated : power * weights[i] / totalInput;
            allocated += amount;
            _voterWeights[tokenId][cycle][gauge] = amount;
            totalGaugeWeight[gauge][cycle] += amount;
            _votedGauges[tokenId][cycle].push(gauge);
            emit VoteCast(tokenId, cycle, gauge, amount);
        }
        _hasVoted[tokenId][cycle] = true;
    }

    function reset(uint256 tokenId) external override {
        _requirePositionAuthority(tokenId);
        uint256 cycle = _votingCycle();
        _clearVote(tokenId, cycle);
        emit VoteReset(tokenId, cycle);
    }

    function poke(uint256 tokenId) external override {
        uint256 cycle = _votingCycle();
        if (!_hasVoted[tokenId][cycle]) revert InvalidVote();
        address[] storage gauges = _votedGauges[tokenId][cycle];
        uint256 length = gauges.length;
        uint256[] memory oldWeights = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            oldWeights[i] = _voterWeights[tokenId][cycle][gauges[i]];
        }
        uint256 power = escrow.votingPowerOf(tokenId);
        uint256 oldTotal;
        for (uint256 i; i < length; ++i) {
            oldTotal += oldWeights[i];
        }
        if (oldTotal == 0) revert InvalidVote();
        uint256 allocated;
        for (uint256 i; i < length; ++i) {
            uint256 amount = i + 1 == length ? power - allocated : power * oldWeights[i] / oldTotal;
            allocated += amount;
            totalGaugeWeight[gauges[i]][cycle] = totalGaugeWeight[gauges[i]][cycle] - oldWeights[i] + amount;
            _voterWeights[tokenId][cycle][gauges[i]] = amount;
            emit VoteCast(tokenId, cycle, gauges[i], amount);
        }
    }

    function voterWeight(uint256 tokenId, address gauge, uint256 cycle) external view override returns (uint256) {
        return _voterWeights[tokenId][cycle][gauge];
    }

    function ve() external view override returns (address) {
        return address(escrow);
    }

    function isGaugeAccepted(address gauge, uint256 cycle) external view override returns (bool) {
        ValidatorStack memory stack = _stacks[ValidatorGauge(gauge).requestId()];
        return stack.gauge == gauge && validatorAccepted[ValidatorGauge(gauge).requestId()][cycle];
    }

    function _clearVote(uint256 tokenId, uint256 cycle) private {
        address[] storage gauges = _votedGauges[tokenId][cycle];
        for (uint256 i; i < gauges.length; ++i) {
            address gauge = gauges[i];
            uint256 amount = _voterWeights[tokenId][cycle][gauge];
            totalGaugeWeight[gauge][cycle] -= amount;
            delete _voterWeights[tokenId][cycle][gauge];
        }
        delete _votedGauges[tokenId][cycle];
        _hasVoted[tokenId][cycle] = false;
    }

    function _requirePositionAuthority(uint256 tokenId) private view {
        address tokenOwner = escrow.ownerOf(tokenId);
        if (
            msg.sender != tokenOwner && msg.sender != escrow.getApproved(tokenId)
                && !escrow.isApprovedForAll(tokenOwner, msg.sender)
        ) revert NotPositionOwner();
    }

    function _votingCycle() private returns (uint256 cycle) {
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        if (epoch < ProtocolTimeLibrary.cycleVoteStart(epoch) || epoch >= ProtocolTimeLibrary.cycleVoteEnd(epoch)) {
            revert VoteWindowClosed();
        }
        cycle = ProtocolTimeLibrary.cycleOf(epoch);
    }
}
