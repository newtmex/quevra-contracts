// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StakingController} from "../../src/staking/StakingController.sol";
import {VeMON} from "../../src/VeMON.sol";
import {VeValidatorFixture} from "./VeValidatorFixture.sol";

abstract contract StakingControllerFixture is VeValidatorFixture {
    StakingController internal controller;
    VeMON internal veMON;

    function setUp() public virtual override {
        super.setUp();
        controller = new StakingController(address(this), 0);
        veMON = new VeMON(address(controller), 4);
        controller.setVe(address(veMON));
        controller.setValidatorVe(address(validatorVe));
    }

    function _setCommission() internal {
        controller.setCommission(commission);
    }
}
