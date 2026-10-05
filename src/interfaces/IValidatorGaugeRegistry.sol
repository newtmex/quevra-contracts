// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Read API for the canonical validator gauge registry.
interface IValidatorGaugeRegistry {
    function validatorGaugeForRequest(uint256 requestId) external view returns (address gauge);
    function requestForValidatorGauge(address gauge) external view returns (uint256 requestId);
    function vaultForValidatorGauge(address gauge) external view returns (address vault);
    function validatorIdForGauge(address gauge) external view returns (uint64 validatorId);
    function gaugeForValidatorId(uint64 validatorId) external view returns (address gauge);
    function isValidatorGauge(address gauge) external view returns (bool registered);
    function validatorGaugeCount() external view returns (uint256);
    function validatorGaugeAt(uint256 index) external view returns (address gauge);
    function validatorForGauge(address gauge)
        external
        view
        returns (uint256 requestId, address vault, uint64 validatorId, address operator);
}
