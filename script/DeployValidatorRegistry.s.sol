// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {ValidatorRegistry} from "../src/ValidatorRegistry.sol";

contract DeployValidatorRegistry is Script {
    function run() public returns (ValidatorRegistry registry) {
        vm.startBroadcast();
        registry = new ValidatorRegistry();
        vm.stopBroadcast();
    }
}
