// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StakingAgent} from "../../src/staking/controlled/StakingAgent.sol";
import {BaseTest} from "./BaseTest.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

abstract contract StakingAgentFixture is BaseTest {
    StakingAgent internal agent;
    uint256 internal tokenId = 42;
    uint64 internal validatorA = 11;
    uint64 internal validatorB = 22;

    function setUp() public virtual override {
        super.setUp();
        vm.deal(address(this), 100 ether);
        StakingAgent implementation = new StakingAgent();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(implementation), address(this));
        agent = StakingAgent(payable(address(new BeaconProxy(address(beacon), bytes("")))));
        agent.initialize(address(this), tokenId);
    }
}
