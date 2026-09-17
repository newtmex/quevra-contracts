// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {ValidatorRegistry} from "../src/ValidatorRegistry.sol";

contract DeployValidatorRegistry is Script {
    function run() public returns (ValidatorRegistry registry) {
        address owner_ = vm.envOr("REGISTRY_OWNER", msg.sender);
        address auth_ = vm.envAddress("AUTH_ADDRESS");
        uint256 amount_ = vm.envOr("AMOUNT", uint256(100_000 ether));
        uint256 commission_ = vm.envOr("COMMISSION", uint256(1e17));

        vm.startBroadcast();
        registry = new ValidatorRegistry(owner_, auth_, amount_, commission_);
        vm.stopBroadcast();
    }
}
