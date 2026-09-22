// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IValidatorRegistry
/// @notice Registry for opaque validator registration payloads and registry-owned delegation.
interface IValidatorRegistry {
    enum Status {
        Submitted
    }

    struct Submission {
        bytes payload;
        bytes signedSecpMessage;
        bytes signedBlsMessage;

        address operator;
        Status status;

        address requester;
    }

    event ValidatorRequested(uint256 indexed id, address indexed operator, bytes payload);

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

    function getSubmission(uint256 id) external view returns (Submission memory);
}
