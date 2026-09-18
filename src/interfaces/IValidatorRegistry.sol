// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IValidatorRegistry
/// @notice Propose and execute Monad `addValidator` registrations.
interface IValidatorRegistry {
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
    error NotAuth();

    function authAddress() external view returns (address);
    function amount() external view returns (uint256);
    function commission() external view returns (uint256);
    function nextId() external view returns (uint256);
    function idBySecpPubkey(bytes32 secpKeyHash) external view returns (uint256 id);
    function idByBlsPubkey(bytes32 blsKeyHash) external view returns (uint256 id);
    function voter() external view returns (address);

    function setConfig(address authAddress_, uint256 amount_, uint256 commission_) external;
    function pause() external;
    function unpause() external;

    function propose(
        bytes calldata secpPubkey,
        bytes calldata blsPubkey,
        bytes calldata signedSecpMessage,
        bytes calldata signedBlsMessage
    ) external returns (uint256 id);

    function execute(uint256 id) external payable returns (uint64 validatorId);
    function cancel(uint256 id) external;
    function ownerCancel(uint256 id) external;
    function getProposal(uint256 id) external view returns (Proposal memory);
    function stakingPayload(bytes calldata secpPubkey, bytes calldata blsPubkey) external view returns (bytes memory);
    function stakingPayload(uint256 id) external view returns (bytes memory);
}
