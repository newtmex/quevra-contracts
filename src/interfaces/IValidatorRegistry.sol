// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";

/// @title IValidatorRegistry
/// @notice Registry for opaque validator registration payloads and registry-owned delegation.
interface IValidatorRegistry {
    enum Status {
        Submitted,
        Executed,
        Cancelled
    }

    struct Submission {
        bytes payload;
        bytes signedSecpMessage;
        bytes signedBlsMessage;

        address operator;
        Status status;

        address executor;
        uint64 validatorId;
        address requester;
    }

    event ValidatorRequested(uint256 indexed id, address indexed operator, bytes payload);

    event ValidatorAdded(
        uint256 indexed id,
        address indexed executor,
        uint64 indexed validatorId,
        address authAddress,
        uint256 amount,
        uint256 commission
    );

    event ValidatorRequestCancelled(uint256 indexed id);

    error UnknownSubmission();
    error NotSubmitted();
    error NotOperator();
    error InvalidValidatorId();
    error InvalidValidatorData();

    function staking() external view returns (IMonadStaking);

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

    function addValidator(uint256 id) external payable returns (uint64 validatorId);

    function cancel(uint256 id) external;

    function getSubmission(uint256 id) external view returns (Submission memory);

    function stakingPayload(uint256 id) external view returns (bytes memory);
}
