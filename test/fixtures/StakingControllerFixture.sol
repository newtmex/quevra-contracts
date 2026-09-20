// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StakingController} from "../../src/staking/StakingController.sol";
import {VeMON} from "../../src/VeMON.sol";
import {ValidatorRegistryFixture} from "./ValidatorRegistryFixture.sol";

abstract contract StakingControllerFixture is ValidatorRegistryFixture {
    StakingController internal controller;
    VeMON internal veMON;

    function setUp() public virtual override {
        super.setUp();
        controller = new StakingController(address(registry), address(this));
        veMON = new VeMON(address(controller), 4);
    }

    function _setValidatorConfig() internal {
        controller.setValidatorConfig(validatorStake, commission);
    }
}
