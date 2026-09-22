// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StakingVoter} from "./staking/StakingVoter.sol";
import {IValidatorRegistry} from "./interfaces/IValidatorRegistry.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @title ValidatorsVoter
/// @notice Creates validator submissions with an initialized staking vault and gauge.
contract ValidatorsVoter is StakingVoter, Initializable {
    IValidatorRegistry public registry;
    mapping(uint256 => address) public validatorToGauge;
    address public gaugeFactory;

    event ValidatorGaugeCreated(address indexed operator, address indexed gauge, address indexed beneficiary);

    error GaugeExistsForValidator();

    constructor(address forwarder_) StakingVoter(forwarder_) {
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
        __StakingVoter_init(ve_, factoryRegistry_, rewardToken_, controller_);
        if (registry_ == address(0) || controller_ == address(0) || gaugeFactory_ == address(0)) revert ZeroAddress();
        registry = IValidatorRegistry(registry_);
        gaugeFactory = gaugeFactory_;
    }

    function createValidator(
        bytes32 saltSeed,
        address expectedAuthAddress,
        bytes calldata payload,
        bytes calldata signedSecpMessage,
        bytes calldata signedBlsMessage
    ) external nonReentrant returns (uint256 requestId, address vault, address gauge) {
        requestId = registry.requestValidatorFor(_msgSender(), payload, signedSecpMessage, signedBlsMessage);
        (vault, gauge) = _deployValidator(requestId, _msgSender(), saltSeed, expectedAuthAddress);
    }

    function _deployValidator(uint256 requestId, address operator, bytes32 saltSeed, address expectedAuthAddress)
        private
        returns (address vault, address gauge)
    {
        gauge = _createValidatorGauge(requestId, operator, operator);
        vault = controller.deployVault(requestId, operator, saltSeed, expectedAuthAddress, gauge);
    }

    function _createValidatorGauge(uint256 requestId, address operator, address beneficiary)
        internal
        returns (address gauge)
    {
        if (validatorToGauge[requestId] != address(0)) revert GaugeExistsForValidator();

        gauge = _createGauge(gaugeFactory, beneficiary);
        validatorToGauge[requestId] = gauge;
        emit ValidatorGaugeCreated(operator, gauge, beneficiary);
    }
}
