// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IMonadStaking} from "./interfaces/IMonadStaking.sol";
import {IValidatorRegistry} from "./interfaces/IValidatorRegistry.sol";
import {IValidatorsVoter} from "./interfaces/IValidatorsVoter.sol";

/// @title ValidatorRegistry
/// @notice Operators propose consensus keys signed over the registry's current
///         `authAddress`, `amount`, and `commission`. If `voter == 0`, anyone can
///         execute by paying `amount`. If a voter is wired, only `authAddress`
///         (MonVault) may execute. Signatures are forwarded to `addValidator` at `0x1000`.
contract ValidatorRegistry is Ownable2Step, Pausable, ReentrancyGuardTransient, IValidatorRegistry {
    uint256 public constant MIN_AUTH_ADDRESS_STAKE = 100_000 ether;
    uint256 public constant MAX_COMMISSION = 1e18;
    uint256 public constant SECP_PUBKEY_LENGTH = 33;
    uint256 public constant BLS_PUBKEY_LENGTH = 48;
    uint256 public constant SECP_SIG_LENGTH = 64;
    uint256 public constant BLS_SIG_LENGTH = 96;

    address public constant STAKING_PRECOMPILE = 0x0000000000000000000000000000000000001000;

    address public override authAddress;
    uint256 public override amount;
    uint256 public override commission;
    address public override voter;

    uint256 public override nextId = 1;
    mapping(uint256 id => Proposal) private _proposals;
    mapping(bytes32 secpKeyHash => uint256 id) public override idBySecpPubkey;
    mapping(bytes32 blsKeyHash => uint256 id) public override idByBlsPubkey;

    constructor(address owner_, address authAddress_, uint256 amount_, uint256 commission_) Ownable(owner_) {
        _setConfig(authAddress_, amount_, commission_);
    }

    /// @dev Config updates must remain available for the lifetime of the registry.
    function renounceOwnership() public pure override {
        revert OwnableInvalidOwner(address(0));
    }

    /// @notice Halt proposals and executions. Cancellation stays available so keys can be freed.
    function pause() external override onlyOwner {
        _pause();
    }

    /// @notice Resume proposals and executions.
    function unpause() external override onlyOwner {
        _unpause();
    }

    /// @notice Atomically update values proposers must sign into the `addValidator` payload.
    function setConfig(address authAddress_, uint256 amount_, uint256 commission_) external override onlyOwner {
        _setConfig(authAddress_, amount_, commission_);
    }

    /// @notice Wire (or clear) the veMON voter. `address(0)` keeps anyone-pays `execute`.
    function setVoter(address voter_) external override onlyOwner {
        // Zero is the solo-mode flag, not an unset mistake.
        // forge-lint: disable-next-line(missing-zero-check)
        voter = voter_;
        emit VoterSet(voter_);
    }

    /// @notice Propose consensus keys. Signatures must be Monad `addValidator` signatures
    ///         over `stakingPayload(secpPubkey, blsPubkey)` at the current config.
    /// @dev The registry checks sizes and economics. The staking precompile checks
    ///      payload binding (blake3 secp + BLS PoP) at execute.
    function propose(
        bytes calldata secpPubkey,
        bytes calldata blsPubkey,
        bytes calldata signedSecpMessage,
        bytes calldata signedBlsMessage
    ) external override nonReentrant whenNotPaused returns (uint256 id) {
        if (secpPubkey.length != SECP_PUBKEY_LENGTH) revert InvalidSecpPubkeyLength();
        if (blsPubkey.length != BLS_PUBKEY_LENGTH) revert InvalidBlsPubkeyLength();
        if (signedSecpMessage.length != SECP_SIG_LENGTH) revert InvalidSecpSignatureLength();
        if (signedBlsMessage.length != BLS_SIG_LENGTH) revert InvalidBlsSignatureLength();

        bytes32 secpKeyHash = keccak256(secpPubkey);
        bytes32 blsKeyHash = keccak256(blsPubkey);
        if (idBySecpPubkey[secpKeyHash] != 0 || idByBlsPubkey[blsKeyHash] != 0) {
            revert KeyAlreadyRegistered();
        }

        id = nextId++;
        idBySecpPubkey[secpKeyHash] = id;
        idByBlsPubkey[blsKeyHash] = id;

        Proposal storage proposal = _proposals[id];
        proposal.secpPubkey = secpPubkey;
        proposal.blsPubkey = blsPubkey;
        proposal.signedSecpMessage = signedSecpMessage;
        proposal.signedBlsMessage = signedBlsMessage;
        proposal.proposer = msg.sender;
        proposal.status = Status.Proposed;
        proposal.authAddress = authAddress;
        proposal.amount = amount;
        proposal.commission = commission;

        emit ValidatorProposed(id, msg.sender, secpPubkey, blsPubkey, authAddress, amount, commission);

        if (voter != address(0)) {
            IValidatorsVoter(voter).onProposalCreated(id, msg.sender);
        }
    }

    /// @notice Execute a proposal. Caller pays the configured `amount` as `msg.value`.
    /// @dev If a voter is set, only `authAddress` may execute; otherwise anyone-pays as today.
    function execute(uint256 id) external payable override nonReentrant whenNotPaused returns (uint64 validatorId) {
        if (voter != address(0) && msg.sender != authAddress) revert NotAuth();

        Proposal storage proposal = _proposed(id);
        if (proposal.authAddress != authAddress || proposal.amount != amount || proposal.commission != commission) {
            revert ConfigChanged();
        }
        if (msg.value != amount) revert StakeMismatch();

        bytes memory payload = _payload(proposal.secpPubkey, proposal.blsPubkey, authAddress, amount, commission);
        bytes memory signedSecpMessage = proposal.signedSecpMessage;
        bytes memory signedBlsMessage = proposal.signedBlsMessage;

        proposal.status = Status.Executed;
        proposal.executor = msg.sender;

        validatorId = IMonadStaking(STAKING_PRECOMPILE).addValidator{value: msg.value}(
            payload, signedSecpMessage, signedBlsMessage
        );
        if (validatorId == 0) revert InvalidValidatorId();

        proposal.validatorId = validatorId;
        if (voter != address(0)) {
            IValidatorsVoter(voter).onProposalExecuted(id, validatorId);
        }
        // forge-lint: disable-next-line(reentrancy-events)
        emit ValidatorExecuted(id, msg.sender, validatorId, authAddress, amount, commission);
    }

    /// @notice Cancel a still-pending proposal and free its consensus keys.
    /// @dev Voter hook runs first so `GaugeHasVotes` reverts the whole tx.
    function cancel(uint256 id) external override nonReentrant {
        Proposal storage proposal = _proposed(id);
        if (msg.sender != proposal.proposer) revert NotProposer();

        if (voter != address(0)) {
            IValidatorsVoter(voter).onProposalCancelled(id);
        }

        proposal.status = Status.Cancelled;
        delete idBySecpPubkey[keccak256(proposal.secpPubkey)];
        delete idByBlsPubkey[keccak256(proposal.blsPubkey)];

        // forge-lint: disable-next-line(reentrancy-events)
        emit ValidatorProposalCancelled(id);
    }

    /// @notice Owner bypass: cancel a still-pending proposal and kill its gauge without a vote check.
    function ownerCancel(uint256 id) external override nonReentrant onlyOwner {
        Proposal storage proposal = _proposed(id);

        proposal.status = Status.Cancelled;
        delete idBySecpPubkey[keccak256(proposal.secpPubkey)];
        delete idByBlsPubkey[keccak256(proposal.blsPubkey)];

        if (voter != address(0)) {
            IValidatorsVoter(voter).onOwnerCancelled(id);
        }

        // forge-lint: disable-next-line(reentrancy-events)
        emit ValidatorProposalCancelled(id);
    }

    function getProposal(uint256 id) external view override returns (Proposal memory) {
        if (_proposals[id].proposer == address(0)) revert UnknownProposal();
        return _proposals[id];
    }

    /// @notice Packed `addValidator` payload for `secpPubkey`/`blsPubkey` and the current config.
    function stakingPayload(bytes calldata secpPubkey, bytes calldata blsPubkey)
        external
        view
        override
        returns (bytes memory)
    {
        return _payload(secpPubkey, blsPubkey, authAddress, amount, commission);
    }

    /// @notice Packed `addValidator` payload snapshotted on the proposal at propose time.
    function stakingPayload(uint256 id) external view override returns (bytes memory) {
        if (_proposals[id].proposer == address(0)) revert UnknownProposal();
        Proposal storage proposal = _proposals[id];
        return
            _payload(
                proposal.secpPubkey, proposal.blsPubkey, proposal.authAddress, proposal.amount, proposal.commission
            );
    }

    function _setConfig(address authAddress_, uint256 amount_, uint256 commission_) private {
        if (authAddress_ == address(0)) revert InvalidAuthAddress();
        if (amount_ < MIN_AUTH_ADDRESS_STAKE) revert StakeTooLow();
        if (commission_ > MAX_COMMISSION) revert CommissionTooHigh();

        authAddress = authAddress_;
        amount = amount_;
        commission = commission_;
        emit ConfigUpdated(authAddress_, amount_, commission_);
    }

    function _proposed(uint256 id) private view returns (Proposal storage proposal) {
        proposal = _proposals[id];
        if (proposal.proposer == address(0)) revert UnknownProposal();
        if (proposal.status != Status.Proposed) revert NotProposed();
    }

    function _payload(
        bytes memory secpPubkey,
        bytes memory blsPubkey,
        address authAddress_,
        uint256 amount_,
        uint256 commission_
    ) private pure returns (bytes memory) {
        return bytes.concat(secpPubkey, blsPubkey, abi.encodePacked(authAddress_, amount_, commission_));
    }
}
