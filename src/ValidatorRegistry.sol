// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMonadStaking} from "./interfaces/IMonadStaking.sol";
import {ConsensusKeyProof} from "./lib/ConsensusKeyProof.sol";

/// @title ValidatorRegistry
/// @notice Operators propose consensus keys with ownership proofs. Executors later
///         supply auth address, commission, and self-stake as `msg.value`.
contract ValidatorRegistry {
    uint256 public constant MIN_AUTH_ADDRESS_STAKE = 100_000 ether;
    uint256 public constant MAX_COMMISSION = 1e18;
    uint256 public constant SECP_PUBKEY_LENGTH = 33;
    uint256 public constant BLS_PUBKEY_LENGTH = 48;

    address public constant STAKING_PRECOMPILE = 0x0000000000000000000000000000000000001000;

    bytes32 public constant PROPOSAL_TYPEHASH =
        keccak256("ValidatorProposal(bytes32 secpPubkeyHash,bytes32 blsPubkeyHash)");
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256("Quevra ValidatorRegistry");
    bytes32 private constant VERSION_HASH = keccak256("1");

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

    uint256 public nextId = 1;
    mapping(uint256 id => Proposal) private _proposals;
    mapping(bytes32 secpKeyHash => uint256 id) public idBySecpPubkey;
    mapping(bytes32 blsKeyHash => uint256 id) public idByBlsPubkey;

    event ValidatorProposed(uint256 indexed id, address indexed proposer, bytes secpPubkey, bytes blsPubkey);
    event ValidatorExecuted(
        uint256 indexed id,
        address indexed executor,
        uint64 indexed validatorId,
        address authAddress,
        uint256 amount,
        uint256 commission
    );
    event ValidatorProposalCancelled(uint256 indexed id);

    error InvalidSecpPubkeyLength();
    error InvalidBlsPubkeyLength();
    error InvalidAuthAddress();
    error StakeTooLow();
    error CommissionTooHigh();
    error KeyAlreadyRegistered();
    error UnknownProposal();
    error NotProposed();
    error NotProposer();
    error InvalidValidatorId();

    /// @notice Propose consensus keys. Signatures must match those keys over `proposalDigest`.
    function propose(
        bytes calldata secpPubkey,
        bytes calldata blsPubkey,
        bytes calldata signedSecpMessage,
        bytes calldata signedBlsMessage
    ) external returns (uint256 id) {
        if (secpPubkey.length != SECP_PUBKEY_LENGTH) revert InvalidSecpPubkeyLength();
        if (blsPubkey.length != BLS_PUBKEY_LENGTH) revert InvalidBlsPubkeyLength();

        bytes32 digest = proposalDigest(secpPubkey, blsPubkey);
        ConsensusKeyProof.verifySecp(secpPubkey, digest, signedSecpMessage);
        ConsensusKeyProof.verifyBls(blsPubkey, signedBlsMessage);

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

        // forge-lint: disable-next-line(reentrancy-events)
        emit ValidatorProposed(id, msg.sender, secpPubkey, blsPubkey);
    }

    /// @notice Execute a proposal. Caller supplies auth address, commission, and self-stake as `msg.value`.
    /// @dev Forwards the signatures stored at propose time to `addValidator`.
    function execute(uint256 id, address authAddress, uint256 commission)
        external
        payable
        returns (uint64 validatorId)
    {
        Proposal storage proposal = _proposed(id);
        if (authAddress == address(0)) revert InvalidAuthAddress();
        if (msg.value < MIN_AUTH_ADDRESS_STAKE) revert StakeTooLow();
        if (commission > MAX_COMMISSION) revert CommissionTooHigh();

        bytes memory payload = _payload(proposal, authAddress, msg.value, commission);
        bytes memory signedSecpMessage = proposal.signedSecpMessage;
        bytes memory signedBlsMessage = proposal.signedBlsMessage;

        proposal.status = Status.Executed;
        proposal.authAddress = authAddress;
        proposal.amount = msg.value;
        proposal.commission = commission;
        proposal.executor = msg.sender;

        validatorId = IMonadStaking(STAKING_PRECOMPILE).addValidator{value: msg.value}(
            payload, signedSecpMessage, signedBlsMessage
        );
        if (validatorId == 0) revert InvalidValidatorId();

        proposal.validatorId = validatorId;
        // forge-lint: disable-next-line(reentrancy-events)
        emit ValidatorExecuted(id, msg.sender, validatorId, authAddress, msg.value, commission);
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

    function stakingPayload(uint256 id, address authAddress, uint256 amount, uint256 commission)
        external
        view
        returns (bytes memory)
    {
        if (_proposals[id].proposer == address(0)) revert UnknownProposal();
        return _payload(_proposals[id], authAddress, amount, commission);
    }

    function proposalDigest(bytes memory secpPubkey, bytes memory blsPubkey) public view returns (bytes32) {
        bytes32 domain = keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
        bytes32 structHash = keccak256(abi.encode(PROPOSAL_TYPEHASH, keccak256(secpPubkey), keccak256(blsPubkey)));
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _proposed(uint256 id) private view returns (Proposal storage proposal) {
        proposal = _proposals[id];
        if (proposal.proposer == address(0)) revert UnknownProposal();
        if (proposal.status != Status.Proposed) revert NotProposed();
    }

    function _payload(Proposal storage proposal, address authAddress, uint256 amount, uint256 commission)
        private
        view
        returns (bytes memory)
    {
        return bytes.concat(proposal.secpPubkey, proposal.blsPubkey, abi.encodePacked(authAddress, amount, commission));
    }
}
