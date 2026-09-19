// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IValidatorRegistry} from "./interfaces/IValidatorRegistry.sol";
import {IValidatorVoter} from "./interfaces/IValidatorVoter.sol";
import {ValidatorGauge} from "./ValidatorGauge.sol";
import {StakingController} from "./StakingController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ValidatorVoter
/// @notice Creates and tracks validator vault/gauge pairs around a registry request.
/// @dev The registry owns all validator-request state. This voter only owns the
///      request-to-deployment index needed to cancel its own deployments.
contract ValidatorVoter is IValidatorVoter, Ownable {
    IValidatorRegistry public immutable registry;
    StakingController public immutable controller;

    mapping(uint256 requestId => ValidatorStack) private _stacks;
    mapping(address token => bool) public override isRewardTokenWhitelisted;
    mapping(uint256 requestId => mapping(uint256 cycle => bool accepted)) public override validatorAccepted;

    event ValidatorStackCancelled(uint256 indexed requestId, address indexed operator, address vault, address gauge);
    event RewardTokenWhitelistUpdated(address indexed token, bool whitelisted);
    event ValidatorAcceptanceUpdated(uint256 indexed requestId, uint256 indexed cycle, bool accepted);

    error InvalidRegistry();
    error InvalidRewardToken();
    error NoStack();

    constructor(address registry_, address controller_) Ownable(msg.sender) {
        if (registry_ == address(0) || controller_ == address(0)) revert InvalidRegistry();
        registry = IValidatorRegistry(registry_);
        controller = StakingController(payable(controller_));
    }

    function setRewardTokenWhitelisted(address token, bool whitelisted) external onlyOwner {
        if (token == address(0)) revert InvalidRewardToken();
        isRewardTokenWhitelisted[token] = whitelisted;
        emit RewardTokenWhitelistUpdated(token, whitelisted);
    }

    function setValidatorAccepted(uint256 requestId, uint256 cycle, bool accepted) external onlyOwner {
        if (_stacks[requestId].gauge == address(0)) revert NoStack();
        validatorAccepted[requestId][cycle] = accepted;
        emit ValidatorAcceptanceUpdated(requestId, cycle, accepted);
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
        gauge =
            address(new ValidatorGauge(address(registry), expectedAuthAddress, msg.sender, requestId, address(this)));
        vault = controller.deployVault(requestId, msg.sender, expectedAuthAddress, gauge);
        _stacks[requestId] = ValidatorStack(vault, gauge, 0, msg.sender);
        emit ValidatorGaugeCreated(requestId, 0, msg.sender, vault, gauge);
    }

    /// @notice Cancels the registry request and removes this voter's deployment index.
    /// @dev Cancellation is available only before any weight is routed. The
    ///      controller clears its pool configuration before the registry request
    ///      is cancelled; a revert rolls back both actions.
    function cancel(uint256 requestId) external {
        ValidatorStack memory stack = _stacks[requestId];
        if (stack.vault == address(0)) revert NoStack();

        if (msg.sender != stack.operator) revert NotRequestOperator();

        controller.cancelVault(requestId);
        registry.cancel(requestId);
        delete _stacks[requestId];
        emit ValidatorStackCancelled(requestId, msg.sender, stack.vault, stack.gauge);
    }

    function stackByRequest(uint256 requestId) external view override returns (ValidatorStack memory) {
        return _stacks[requestId];
    }
}
