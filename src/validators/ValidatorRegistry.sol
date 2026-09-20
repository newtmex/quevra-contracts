// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";
import {IValidatorRegistry} from "../interfaces/IValidatorRegistry.sol";

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
    mapping(bytes32 secpKeyHash => uint256 id) public override idBySecpPubkey;
    mapping(bytes32 blsKeyHash => uint256 id) public override idByBlsPubkey;

    /// @notice Request validator registration.
    /// @dev The signed messages contain the validator's complete registration
    ///      payload, including authentication address, stake, and commission.
    function requestValidator(
        bytes calldata secpPubkey,
        bytes calldata blsPubkey,
        bytes calldata signedSecpMessage,
        bytes calldata signedBlsMessage
    ) external override returns (uint256 id) {
        return _requestValidator(msg.sender, secpPubkey, blsPubkey, signedSecpMessage, signedBlsMessage);
    }

    function requestValidatorFor(
        address operator,
        bytes calldata secpPubkey,
        bytes calldata blsPubkey,
        bytes calldata signedSecpMessage,
        bytes calldata signedBlsMessage
    ) external override returns (uint256 id) {
        if (operator == address(0)) revert InvalidValidatorData();
        return _requestValidator(operator, secpPubkey, blsPubkey, signedSecpMessage, signedBlsMessage);
    }

    function _requestValidator(
        address operator,
        bytes calldata secpPubkey,
        bytes calldata blsPubkey,
        bytes calldata signedSecpMessage,
        bytes calldata signedBlsMessage
    ) private returns (uint256 id) {
        if (
            secpPubkey.length != 33 || blsPubkey.length != 48 || signedSecpMessage.length == 0
                || signedBlsMessage.length == 0
        ) revert InvalidValidatorData();

        bytes32 secpKeyHash = keccak256(secpPubkey);
        bytes32 blsKeyHash = keccak256(blsPubkey);
        if (idBySecpPubkey[secpKeyHash] != 0 || idByBlsPubkey[blsKeyHash] != 0) {
            revert KeyAlreadyRegistered();
        }

        id = nextId++;
        idBySecpPubkey[secpKeyHash] = id;
        idByBlsPubkey[blsKeyHash] = id;

        Submission storage submission = _submissions[id];
        submission.secpPubkey = secpPubkey;
        submission.blsPubkey = blsPubkey;
        submission.signedSecpMessage = signedSecpMessage;
        submission.signedBlsMessage = signedBlsMessage;
        submission.operator = operator;
        submission.requester = msg.sender;
        submission.status = Status.Submitted;

        emit ValidatorRequested(id, operator, secpPubkey, blsPubkey);
    }

    /// @notice Submit a validator request to Monad's staking precompile.
    ///
    /// @param id Validator request identifier.
    /// @param commission Validator commission encoded in the signed message.
    ///
    /// The supplied values are not stored. They are used only to reconstruct
    /// the staking payload and forward it to the Monad staking precompile.
    function addValidator(uint256 id, uint256 commission) external payable override returns (uint64 validatorId) {
        Submission storage submission = _submitted(id);
        uint256 amount = msg.value;
        address authAddress = msg.sender;
        bytes memory payload = _payload(submission.secpPubkey, submission.blsPubkey, authAddress, amount, commission);

        submission.status = Status.Executed;
        submission.executor = msg.sender;
        validatorId =
            staking.addValidator{value: amount}(payload, submission.signedSecpMessage, submission.signedBlsMessage);
        if (validatorId == 0) revert InvalidValidatorId();

        submission.validatorId = validatorId;
        // forge-lint: disable-next-line(reentrancy-events)
        emit ValidatorAdded(id, msg.sender, validatorId, authAddress, amount, commission);
    }

    function cancel(uint256 id) external override {
        Submission storage submission = _submitted(id);
        if (msg.sender != submission.requester) revert NotOperator();

        submission.status = Status.Cancelled;
        delete idBySecpPubkey[keccak256(submission.secpPubkey)];
        delete idByBlsPubkey[keccak256(submission.blsPubkey)];
        emit ValidatorRequestCancelled(id);
    }

    function getSubmission(uint256 id) external view override returns (Submission memory submission) {
        submission = _submissions[id];
        if (submission.operator == address(0)) revert UnknownSubmission();
    }

    function stakingPayload(uint256 id, address authAddress, uint256 amount, uint256 commission)
        external
        view
        override
        returns (bytes memory)
    {
        Submission memory submission = _submitted(id);
        return _payload(submission.secpPubkey, submission.blsPubkey, authAddress, amount, commission);
    }

    function _submitted(uint256 id) private view returns (Submission storage submission) {
        submission = _submissions[id];
        if (submission.operator == address(0)) revert UnknownSubmission();
        if (submission.status != Status.Submitted) revert NotSubmitted();
    }

    function _payload(
        bytes memory secpPubkey,
        bytes memory blsPubkey,
        address authAddress,
        uint256 amount,
        uint256 commission
    ) private pure returns (bytes memory) {
        return bytes.concat(secpPubkey, blsPubkey, abi.encodePacked(authAddress, amount, commission));
    }
}
