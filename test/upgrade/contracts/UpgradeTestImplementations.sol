// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StakingController} from "../../../src/staking/StakingController.sol";
import {StakingVault} from "../../../src/staking/controlled/StakingVault.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract StakingControllerV2 is StakingController {
    function implementationVersion() external pure returns (uint256) {
        return 2;
    }
}

/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract StakingVaultV2 is StakingVault {
    function implementationVersion() external pure returns (uint256) {
        return 2;
    }
}

contract NotAControllerImplementation {
    uint256 public incompatibleValue;
}

contract UpgradeableBeaconTestArtifact is UpgradeableBeacon {
    constructor(address implementation, address owner_) UpgradeableBeacon(implementation, owner_) {}
}

contract BeaconProxyTestArtifact is BeaconProxy {
    constructor(address beacon, bytes memory data) BeaconProxy(beacon, data) {}
}
