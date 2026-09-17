// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMonadStaking} from "./interfaces/IMonadStaking.sol";

/// @title ValidatorRegistry
/// @notice Operators propose consensus keys signed over the registry's current
///         `authAddress`, `amount`, and `commission`. Anyone can later execute a
///         proposal by paying `amount`; the stored signatures are forwarded to
///         `addValidator` at `0x1000`.
contract ValidatorRegistry {
    uint256 public constant MIN_AUTH_ADDRESS_STAKE = 100_000 ether;
    uint256 public constant MAX_COMMISSION = 1e18;
    uint256 public constant SECP_PUBKEY_LENGTH = 33;
    uint256 public constant BLS_PUBKEY_LENGTH = 48;
    uint256 public constant SECP_SIG_LENGTH = 64;
    uint256 public constant BLS_SIG_LENGTH = 96;

    address public constant STAKING_PRECOMPILE = 0x0000000000000000000000000000000000001000;

    enum Status {
        Proposed,
        Executed,
        Cancelled
    }

    struct Proposal {
        bytes secpPubkey;
        bytes blsPubkey;
        bytes signedSecpMessage;
        bytes signedBlsMessage;
        address proposer;
        Status status;
        address authAddress;
        uint256 amount;
        uint256 commission;
        address executor;
        uint64 validatorId;
    }

    address public owner;
    address public authAddress;
    uint256 public amount;
    uint256 public commission;

    uint256 public nextId = 1;
    mapping(uint256 id => Proposal) private _proposals;
    mapping(bytes32 secpKeyHash => uint256 id) public idBySecpPubkey;
    mapping(bytes32 blsKeyHash => uint256 id) public idByBlsPubkey;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ConfigUpdated(address authAddress, uint256 amount, uint256 commission);
    event ValidatorProposed(
        uint256 indexed id,
        address indexed proposer,
        bytes secpPubkey,
        bytes blsPubkey,
        address authAddress,
        uint256 amount,
        uint256 commission
    );
    event ValidatorExecuted(
        uint256 indexed id,
        address indexed executor,
        uint64 indexed validatorId,
        address authAddress,
        uint256 amount,
        uint256 commission
    );
    event ValidatorProposalCancelled(uint256 indexed id);

    error InvalidOwner();
    error NotOwner();
    error InvalidSecpPubkeyLength();
    error InvalidBlsPubkeyLength();
    error InvalidSecpSignatureLength();
    error InvalidBlsSignatureLength();
    error InvalidAuthAddress();
    error StakeTooLow();
    error StakeMismatch();
    error CommissionTooHigh();
    error ConfigChanged();
    error KeyAlreadyRegistered();
    error UnknownProposal();
    error NotProposed();
    error NotProposer();
    error InvalidValidatorId();

    constructor(address owner_, address authAddress_, uint256 amount_, uint256 commission_) {
        if (owner_ == address(0)) revert InvalidOwner();
        owner = owner_;
        _setConfig(authAddress_, amount_, commission_);
        emit OwnershipTransferred(address(0), owner_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Replace the account allowed to update auth address, amount, and commission.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidOwner();
        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }

    /// @notice Atomically update values proposers must sign into the `addValidator` payload.
    function setConfig(address authAddress_, uint256 amount_, uint256 commission_) external onlyOwner {
        _setConfig(authAddress_, amount_, commission_);
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
    ) external returns (uint256 id) {
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

        // forge-lint: disable-next-line(reentrancy-events)
        emit ValidatorProposed(id, msg.sender, secpPubkey, blsPubkey, authAddress, amount, commission);
    }

    /// @notice Execute a proposal. Caller pays the configured `amount` as `msg.value`.
    /// @dev Forwards the signatures stored at propose time to `addValidator`.
    function execute(uint256 id) external payable returns (uint64 validatorId) {
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
        // forge-lint: disable-next-line(reentrancy-events)
        emit ValidatorExecuted(id, msg.sender, validatorId, authAddress, amount, commission);
    }

    function cancel(uint256 id) external {
        Proposal storage proposal = _proposed(id);
        if (msg.sender != proposal.proposer) revert NotProposer();

        proposal.status = Status.Cancelled;
        delete idBySecpPubkey[keccak256(proposal.secpPubkey)];
        delete idByBlsPubkey[keccak256(proposal.blsPubkey)];

        emit ValidatorProposalCancelled(id);
    }

    function getProposal(uint256 id) external view returns (Proposal memory) {
        if (_proposals[id].proposer == address(0)) revert UnknownProposal();
        return _proposals[id];
    }

    /// @notice Packed `addValidator` payload for `secpPubkey`/`blsPubkey` and the current config.
    function stakingPayload(bytes calldata secpPubkey, bytes calldata blsPubkey) external view returns (bytes memory) {
        return _payload(secpPubkey, blsPubkey, authAddress, amount, commission);
    }

    /// @notice Packed `addValidator` payload snapshotted on the proposal at propose time.
    function stakingPayload(uint256 id) external view returns (bytes memory) {
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
