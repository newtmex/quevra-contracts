// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IValidatorGaugeFactory} from "../interfaces/factories/IValidatorGaugeFactory.sol";
import {ValidatorGauge} from "../gauges/ValidatorGauge.sol";

contract ValidatorGaugeFactory is IValidatorGaugeFactory {
    function createValidatorGauge(address forwarder) external returns (address) {
        return address(new ValidatorGauge(forwarder, msg.sender));
    }
}
