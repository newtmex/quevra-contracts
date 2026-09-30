// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IValidatorGaugeFactory {
    function createValidatorGauge(address forwarder) external returns (address);
}
