// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {ValidatorRegistry} from "../src/ValidatorRegistry.sol";
import {ValidatorVoter} from "../src/ValidatorVoter.sol";
import {StakingController} from "../src/StakingController.sol";

contract DeployValidatorRegistry is Script {
    function run() public returns (ValidatorRegistry registry, StakingController controller, ValidatorVoter voter) {
        vm.startBroadcast();
        registry = new ValidatorRegistry();
        address owner = msg.sender;
        controller = new StakingController(address(registry), owner);
        voter = new ValidatorVoter(address(registry), address(controller));
        controller.setVoter(address(voter));
        vm.stopBroadcast();
    }
}
