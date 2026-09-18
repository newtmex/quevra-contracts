// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IValidatorVoter {
    struct ValidatorStack {
        address vault;
        address gauge;
        uint64 validatorId;
        address operator;
    }

    event ValidatorGaugeCreated(
        uint256 indexed requestId, uint64 indexed validatorId, address indexed operator, address vault, address gauge
    );

    error GaugeExistsForValidator();
    error NotRequestOperator();
    error UnknownStack();

    function stackByRequest(uint256 requestId) external view returns (ValidatorStack memory);
}
