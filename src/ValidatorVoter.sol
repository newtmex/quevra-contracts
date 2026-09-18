// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IValidatorRegistry} from "./interfaces/IValidatorRegistry.sol";
import {IValidatorVoter} from "./interfaces/IValidatorVoter.sol";
import {ValidatorGauge} from "./ValidatorGauge.sol";
import {StakingController} from "./StakingController.sol";

/// @title ValidatorVoter
/// @notice Creates and tracks validator vault/gauge pairs around a registry request.
/// @dev The registry owns all validator-request state. This voter only owns the
///      request-to-deployment index needed to cancel its own deployments.
contract ValidatorVoter is IValidatorVoter {
    IValidatorRegistry public immutable registry;
    StakingController public immutable controller;

    mapping(uint256 requestId => ValidatorStack) private _stacks;

    event ValidatorStackCancelled(uint256 indexed requestId, address indexed operator, address vault, address gauge);

    error InvalidRegistry();
    error NoStack();

    constructor(address registry_, address controller_) {
        if (registry_ == address(0) || controller_ == address(0)) revert InvalidRegistry();
        registry = IValidatorRegistry(registry_);
        controller = StakingController(payable(controller_));
    }

    /// @notice Requests a validator from the registry and deploys its vault and gauge.
    function createValidator(
        address expectedAuthAddress,
        bytes calldata secpPubkey,
        bytes calldata blsPubkey,
        bytes calldata signedSecpMessage,
        bytes calldata signedBlsMessage
    ) external returns (uint256 requestId, address vault, address gauge) {
        requestId = registry.requestValidator(secpPubkey, blsPubkey, signedSecpMessage, signedBlsMessage);
        gauge = address(new ValidatorGauge(address(registry), expectedAuthAddress, msg.sender, requestId));
        vault = controller.deployVault(requestId, msg.sender, expectedAuthAddress, gauge);
        _stacks[requestId] = ValidatorStack(vault, gauge, 0, msg.sender);
        emit ValidatorGaugeCreated(requestId, 0, msg.sender, vault, gauge);
    }

    /// @notice Cancels the registry request and removes this voter's deployment index.
    /// @dev The registry cannot physically destroy already-deployed contracts on
    ///      Cancun EVM; their code remains. The registry reservation and voter
    ///      index are removed atomically.
    function cancel(uint256 requestId) external {
        ValidatorStack memory stack = _stacks[requestId];
        if (stack.vault == address(0)) revert NoStack();

        if (msg.sender != stack.operator) revert NotRequestOperator();

        registry.cancel(requestId);
        delete _stacks[requestId];
        emit ValidatorStackCancelled(requestId, msg.sender, stack.vault, stack.gauge);
    }

    function stackByRequest(uint256 requestId) external view override returns (ValidatorStack memory) {
        return _stacks[requestId];
    }

}
