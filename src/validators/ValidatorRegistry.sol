// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";
import {IValidatorRegistry} from "../interfaces/IValidatorRegistry.sol";
import {ValidatorPayloadLibrary} from "../libraries/ValidatorPayloadLibrary.sol";

/// @title ValidatorRegistry
/// @notice Generic registry for validator registration requests.
///
/// Validator registration and validator delegation are intentionally separate:
/// - Operators request validator registration with signed consensus messages.
/// - Any supported executor may later submit the request to Monad staking,
///   supplying the validator economics required by the signed payload.
contract ValidatorRegistry is IValidatorRegistry {
    IMonadStaking public constant staking = IMonadStaking(0x0000000000000000000000000000000000001000);

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

    /// @notice Submit the already-signed payload to Monad's staking precompile.
    function addValidator(uint256 id) external payable override returns (uint64 validatorId) {
        Submission storage submission = _submitted(id);
        uint256 amount = msg.value;
        submission.status = Status.Executed;
        submission.executor = msg.sender;
        validatorId = staking.addValidator{value: amount}(
            submission.payload, submission.signedSecpMessage, submission.signedBlsMessage
        );
        if (validatorId == 0) revert InvalidValidatorId();

        submission.validatorId = validatorId;
        // forge-lint: disable-next-line(reentrancy-events)
        emit ValidatorAdded(
            id,
            msg.sender,
            validatorId,
            ValidatorPayloadLibrary.authAddress(submission.payload),
            amount,
            ValidatorPayloadLibrary.commission(submission.payload)
        );
    }

    function getSubmission(uint256 id) external view override returns (Submission memory submission) {
        submission = _submissions[id];
        if (submission.operator == address(0)) revert UnknownSubmission();
    }

    function stakingPayload(uint256 id) external view override returns (bytes memory) {
        Submission memory submission = _submitted(id);
        return submission.payload;
    }

    function _submitted(uint256 id) private view returns (Submission storage submission) {
        submission = _submissions[id];
        if (submission.operator == address(0)) revert UnknownSubmission();
        if (submission.status != Status.Submitted) revert NotSubmitted();
    }
}
