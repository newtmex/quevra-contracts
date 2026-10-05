// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IValidatorRegistry
/// @notice Registry for opaque validator registration payloads and registry-owned delegation.
interface IValidatorRegistry {
    enum Status {
        Submitted
    }

    enum RequestType {
        NewValidator,
        ExistingValidator
    }

    struct Submission {
        bytes payload;
        bytes signedSecpMessage;
        bytes signedBlsMessage;

        address operator;
        Status status;

        address requester;
        RequestType requestType;
        uint64 validatorId;
    }

    event ValidatorRequested(uint256 indexed id, address indexed operator, bytes payload);
    event ExistingValidatorRequested(uint256 indexed id, address indexed operator, uint64 indexed validatorId);

    error UnknownSubmission();
    error NotSubmitted();
    error NotOperator();
    error InvalidValidatorData();

    function nextId() external view returns (uint256);

    function requestValidator(bytes calldata payload, bytes calldata signedSecpMessage, bytes calldata signedBlsMessage)
        external
        returns (uint256 id);

    function requestValidatorFor(
        address operator,
        bytes calldata payload,
        bytes calldata signedSecpMessage,
        bytes calldata signedBlsMessage
    ) external returns (uint256 id);

    /// @notice Request to add Quevra staking support for an already-created Monad validator.
    /// @dev The controller validates the ID against Monad when admitting the request.
    function requestExistingValidator(uint64 validatorId) external returns (uint256 id);

    function getSubmission(uint256 id) external view returns (Submission memory);
}
