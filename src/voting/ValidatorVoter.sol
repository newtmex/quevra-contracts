// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ValidatorGauge} from "./ValidatorGauge.sol";
import {IValidatorRegistry} from "../interfaces/IValidatorRegistry.sol";

/// @title ValidatorVoter
/// @notice Validator-to-gauge lifecycle and canonical voting-target registry.
/// @dev StakingController inherits this layer so validator admission, vault
///      setup, and gauge registration are atomic. Voting is added in a later stage.
abstract contract ValidatorVoter {
    IValidatorRegistry private immutable _validatorRegistry;

    mapping(uint256 requestId => address gauge) public validatorGaugeForRequest;
    mapping(address gauge => uint256 requestId) public requestForValidatorGauge;
    mapping(address gauge => address vault) public vaultForValidatorGauge;
    mapping(address gauge => uint64 validatorId) public validatorIdForGauge;
    mapping(uint64 validatorId => address gauge) public gaugeForValidatorId;
    mapping(address gauge => bool registered) public isValidatorGauge;
    address[] private _validatorGauges;

    error ValidatorGaugeAlreadyExists(uint256 requestId);
    error ValidatorAlreadyRegistered(uint64 validatorId);
    error InvalidValidatorGauge();
    error InvalidValidatorRequest();

    event ValidatorGaugeRegistered(
        uint256 indexed requestId, uint64 indexed validatorId, address indexed gauge, address vault, address operator
    );
    event ValidatorGaugeBound(uint256 indexed requestId, uint64 indexed validatorId, address indexed gauge);

    error InvalidValidatorRegistry();

    constructor(address validatorRegistry_) {
        if (validatorRegistry_ == address(0)) revert InvalidValidatorRegistry();
        _validatorRegistry = IValidatorRegistry(validatorRegistry_);
    }

    /// @dev Requests remain authoritative in the separately deployed registry.
    function _getValidatorSubmission(uint256 requestId) internal view returns (IValidatorRegistry.Submission memory) {
        return _validatorRegistry.getSubmission(requestId);
    }

    /// @notice Number of canonical Quevra validator gauges.
    function validatorGaugeCount() external view returns (uint256) {
        return _validatorGauges.length;
    }

    /// @notice Canonical validator gauge at `index`.
    function validatorGaugeAt(uint256 index) external view returns (address) {
        return _validatorGauges[index];
    }

    /// @notice Resolve a registered gauge to its request, vault, and current validator ID.
    /// @dev `validatorId` is zero until a new-validator request is activated by staking.
    function validatorForGauge(address gauge)
        external
        view
        returns (uint256 requestId, address vault, uint64 validatorId, address operator)
    {
        if (!isValidatorGauge[gauge]) revert InvalidValidatorGauge();
        requestId = requestForValidatorGauge[gauge];
        vault = vaultForValidatorGauge[gauge];
        validatorId = validatorIdForGauge[gauge];
        operator = ValidatorGauge(gauge).operator();
    }

    function _registerValidatorGauge(uint256 requestId, address operator, address vault, uint64 validatorId)
        internal
        returns (address gauge)
    {
        if (requestId == 0 || operator == address(0) || vault == address(0)) revert InvalidValidatorGauge();
        if (validatorGaugeForRequest[requestId] != address(0)) revert ValidatorGaugeAlreadyExists(requestId);
        if (validatorId != 0 && gaugeForValidatorId[validatorId] != address(0)) {
            revert ValidatorAlreadyRegistered(validatorId);
        }

        gauge = address(new ValidatorGauge(address(this), requestId, operator));
        validatorGaugeForRequest[requestId] = gauge;
        requestForValidatorGauge[gauge] = requestId;
        vaultForValidatorGauge[gauge] = vault;
        isValidatorGauge[gauge] = true;
        _validatorGauges.push(gauge);

        if (validatorId != 0) {
            validatorIdForGauge[gauge] = validatorId;
            gaugeForValidatorId[validatorId] = gauge;
        }

        emit ValidatorGaugeRegistered(requestId, validatorId, gauge, vault, operator);
    }

    /// @dev Called when the existing StakingVault lifecycle first activates a
    ///      request, binding its already-created gauge to the returned ID.
    function _bindValidatorGauge(address gauge, uint64 validatorId) internal {
        if (!isValidatorGauge[gauge] || validatorId == 0) revert InvalidValidatorGauge();
        uint64 currentId = validatorIdForGauge[gauge];
        if (currentId == validatorId) return;
        if (currentId != 0) revert InvalidValidatorGauge();
        if (gaugeForValidatorId[validatorId] != address(0)) revert ValidatorAlreadyRegistered(validatorId);

        validatorIdForGauge[gauge] = validatorId;
        gaugeForValidatorId[validatorId] = gauge;
        emit ValidatorGaugeBound(requestForValidatorGauge[gauge], validatorId, gauge);
    }
}
