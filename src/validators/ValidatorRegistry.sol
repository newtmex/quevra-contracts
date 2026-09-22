// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IValidatorRegistry} from "../interfaces/IValidatorRegistry.sol";

/// @title ValidatorRegistry
/// @notice Generic registry for validator registration requests.
///
/// Validator registration and validator delegation are intentionally separate:
/// - Operators request validator registration with signed consensus messages.
/// - Any supported executor may later submit the request to Monad staking,
///   supplying the validator economics required by the signed payload.
contract ValidatorRegistry is IValidatorRegistry {
    uint256 public override nextId = 1;

    mapping(uint256 id => Submission) private _submissions;

    /// @notice Request validator registration.
    /// @dev The signed messages authorize this complete payload.
    function requestValidator(bytes calldata payload, bytes calldata signedSecpMessage, bytes calldata signedBlsMessage)
        external
        override
        returns (uint256 id)
    {
        return _requestValidator(msg.sender, payload, signedSecpMessage, signedBlsMessage);
    }

    function requestValidatorFor(
        address operator,
        bytes calldata payload,
        bytes calldata signedSecpMessage,
        bytes calldata signedBlsMessage
    ) external override returns (uint256 id) {
        if (operator == address(0)) revert InvalidValidatorData();
        return _requestValidator(operator, payload, signedSecpMessage, signedBlsMessage);
    }

    function _requestValidator(
        address operator,
        bytes calldata payload,
        bytes calldata signedSecpMessage,
        bytes calldata signedBlsMessage
    ) private returns (uint256 id) {
        if (payload.length != 165 || signedSecpMessage.length == 0 || signedBlsMessage.length == 0) {
            revert InvalidValidatorData();
        }

        id = nextId++;
        Submission storage submission = _submissions[id];
        submission.payload = payload;
        submission.signedSecpMessage = signedSecpMessage;
        submission.signedBlsMessage = signedBlsMessage;
        submission.operator = operator;
        submission.requester = msg.sender;
        submission.status = Status.Submitted;

        emit ValidatorRequested(id, operator, payload);
    }

    function getSubmission(uint256 id) external view override returns (Submission memory submission) {
        submission = _submissions[id];
        if (submission.operator == address(0)) revert UnknownSubmission();
    }
}
