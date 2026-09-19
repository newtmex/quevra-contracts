// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ValidatorGauge} from "../../src/ValidatorGauge.sol";
import {ValidatorVoterFixture} from "./ValidatorVoterFixture.sol";

abstract contract ValidatorGaugeFixture is ValidatorVoterFixture {
    ValidatorGauge internal gauge;
    address internal gaugeVault;
    uint256 internal gaugeRequestId;

    function setUp() public virtual override {
        super.setUp();
        address gaugeAddress;
        (gaugeRequestId, gaugeVault, gaugeAddress) = _createValidatorStack();
        gauge = ValidatorGauge(gaugeAddress);
    }
}
