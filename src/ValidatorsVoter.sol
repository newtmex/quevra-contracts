// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NonStakingVoter} from "./NonStakingVoter.sol";
import {IValidatorRegistry} from "./interfaces/IValidatorRegistry.sol";
import {StakingController} from "./staking/StakingController.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @title ValidatorsVoter
/// @notice Creates validator submissions with an initialized staking vault and gauge.
contract ValidatorsVoter is NonStakingVoter, Initializable {
    IValidatorRegistry public registry;
    mapping(uint256 => address) public validatorToGauge;
    StakingController public controller;
    address public gaugeFactory;

    event ValidatorGaugeCreated(address indexed operator, address indexed gauge, address indexed beneficiary);
    event ValidatorLeft(address indexed operator, address indexed gauge);

    error GaugeExistsForValidator();
    error SubmissionCancelled();
    error NoSubmission();
    error NotSubmissionOperator();

    constructor(address forwarder_) NonStakingVoter(forwarder_) {
        _disableInitializers();
    }

    function initialize(
        address ve_,
        address factoryRegistry_,
        address rewardToken_,
        address registry_,
        address controller_,
        address gaugeFactory_
    ) external initializer {
        __NonStakingVoter_init(ve_, factoryRegistry_, rewardToken_);
        if (registry_ == address(0) || controller_ == address(0) || gaugeFactory_ == address(0)) revert ZeroAddress();
        registry = IValidatorRegistry(registry_);
        controller = StakingController(payable(controller_));
        gaugeFactory = gaugeFactory_;
    }

    function createValidator(
        address expectedAuthAddress,
        bytes calldata secpPubkey,
        bytes calldata blsPubkey,
        bytes calldata signedSecpMessage,
        bytes calldata signedBlsMessage
    ) external nonReentrant returns (uint256 requestId, address vault, address gauge) {
        requestId =
            registry.requestValidatorFor(_msgSender(), secpPubkey, blsPubkey, signedSecpMessage, signedBlsMessage);
        (vault, gauge) = _deployValidator(requestId, _msgSender(), expectedAuthAddress);
    }

    function _deployValidator(uint256 requestId, address operator, address expectedAuthAddress)
        private
        returns (address vault, address gauge)
    {
        gauge = _createValidatorGauge(requestId, operator, operator);
        vault = controller.deployVault(requestId, operator, expectedAuthAddress, gauge);
    }

    function notifyValidatorLeft(uint256 submissionId) external nonReentrant {
        _notifyValidatorLeft(submissionId);
    }

    function cancel(uint256 submissionId) external nonReentrant {
        if (validatorToGauge[submissionId] == address(0)) revert NoSubmission();
        IValidatorRegistry.Submission memory submission = registry.getSubmission(submissionId);
        address operator = submission.operator;
        if (operator == address(0)) revert NoSubmission();
        if (_msgSender() != operator) revert NotSubmissionOperator();

        controller.cancelVault(submissionId);
        registry.cancel(submissionId);
        _notifyValidatorLeft(submissionId);
    }

    function _notifyValidatorLeft(uint256 submissionId) private {
        address gauge = validatorToGauge[submissionId];
        if (!isGauge[gauge] || !isAlive[gauge]) return;

        if (registry.getSubmission(submissionId).status != IValidatorRegistry.Status.Cancelled) return;

        address operator = registry.getSubmission(submissionId).operator;
        delete validatorToGauge[submissionId];
        _onGaugeKilled(gauge);
        emit ValidatorLeft(operator, gauge);
    }

    function _createValidatorGauge(uint256 requestId, address operator, address beneficiary)
        internal
        returns (address gauge)
    {
        if (registry.getSubmission(requestId).status == IValidatorRegistry.Status.Cancelled) {
            revert SubmissionCancelled();
        }
        if (validatorToGauge[requestId] != address(0)) revert GaugeExistsForValidator();

        gauge = _createGauge(gaugeFactory, beneficiary);
        validatorToGauge[requestId] = gauge;
        emit ValidatorGaugeCreated(operator, gauge, beneficiary);
    }
}
