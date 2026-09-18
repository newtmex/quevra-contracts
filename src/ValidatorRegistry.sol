// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";
import {IValidatorRegistry} from "./interfaces/IValidatorRegistry.sol";

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

    mapping(uint256 id => Proposal) private _proposals;
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
        proposal.operator = msg.sender;
        proposal.status = Status.Proposed;

        emit ValidatorRequested(id, msg.sender, secpPubkey, blsPubkey);
    }

    /// @notice Submit a validator request to Monad's staking precompile.
    ///
    /// @param id Validator request identifier.
    /// @param commission Validator commission encoded in the signed message.
    ///
    /// The supplied values are not stored. They are used only to reconstruct
    /// the staking payload and forward it to the Monad staking precompile.
    function addValidator(uint256 id, uint256 commission) external payable override returns (uint64 validatorId) {
        Proposal storage proposal = _proposed(id);
        uint256 amount = msg.value;
        address authAddress = msg.sender;

        bytes memory payload = _payload(proposal.secpPubkey, proposal.blsPubkey, authAddress, amount, commission);

        bytes memory signedSecpMessage = proposal.signedSecpMessage;
        bytes memory signedBlsMessage = proposal.signedBlsMessage;

        proposal.status = Status.Executed;
        proposal.executor = msg.sender;

        validatorId = staking.addValidator{value: amount}(payload, signedSecpMessage, signedBlsMessage);

        if (validatorId == 0) revert InvalidValidatorId();

        proposal.validatorId = validatorId;

        // forge-lint: disable-next-line(reentrancy-events)
        emit ValidatorAdded(id, msg.sender, validatorId, authAddress, amount, commission);
    }

    /// @notice Cancel a pending validator request.
    function cancel(uint256 id) external override {
        Proposal storage proposal = _proposed(id);

        if (msg.sender != proposal.operator) {
            revert NotOperator();
        }

        proposal.status = Status.Cancelled;

        delete idBySecpPubkey[keccak256(proposal.secpPubkey)];
        delete idByBlsPubkey[keccak256(proposal.blsPubkey)];

        emit ValidatorRequestCancelled(id);
    }

    function getProposal(uint256 id) external view override returns (Proposal memory proposal) {
        proposal = _proposals[id];
        if (proposal.operator == address(0)) revert UnknownProposal();

        return proposal;
    }

    /// @notice Reconstruct a request's staking payload.
    function stakingPayload(uint256 id, address authAddress, uint256 amount, uint256 commission)
        external
        view
        override
        returns (bytes memory)
    {
        Proposal memory proposal = _proposed(id);

        if (proposal.operator == address(0)) revert UnknownProposal();

        return _payload(proposal.secpPubkey, proposal.blsPubkey, authAddress, amount, commission);
    }

    function _proposed(uint256 id) private view returns (Proposal storage proposal) {
        proposal = _proposals[id];

        if (proposal.operator == address(0)) revert UnknownProposal();
        if (proposal.status != Status.Proposed) revert NotProposed();
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
