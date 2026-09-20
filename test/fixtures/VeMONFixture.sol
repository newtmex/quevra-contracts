// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StakingControllerFixture} from "./StakingControllerFixture.sol";
import {IBaseVoter} from "../../src/interfaces/IBaseVoter.sol";

abstract contract VeMONFixture is StakingControllerFixture {
    function setUp() public virtual override {
        super.setUp();
        vm.mockCall(address(veMON), abi.encodeWithSelector(IBaseVoter.ve.selector), abi.encode(address(veMON)));
        controller.setVoter(address(veMON));
    }
}
