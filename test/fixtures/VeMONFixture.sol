// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StakingControllerFixture} from "./StakingControllerFixture.sol";
import {ValidatorVoter} from "../../src/validators/ValidatorVoter.sol";

abstract contract VeMONFixture is StakingControllerFixture {
    ValidatorVoter internal voter;

    function setUp() public virtual override {
        super.setUp();
        voter = new ValidatorVoter(address(registry), address(controller), address(veMON));
        controller.setVoter(address(voter));
    }
}
