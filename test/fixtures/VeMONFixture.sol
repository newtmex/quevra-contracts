// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StakingControllerFixture} from "./StakingControllerFixture.sol";
import {ValidatorsVoter} from "../../src/ValidatorsVoter.sol";
import {FactoryRegistry} from "../../src/factories/FactoryRegistry.sol";
import {GaugeFactory} from "../../src/factories/GaugeFactory.sol";
import {VotingRewardsFactory} from "../../src/factories/VotingRewardsFactory.sol";

abstract contract VeMONFixture is StakingControllerFixture {
    ValidatorsVoter internal voter;

    function setUp() public virtual override {
        super.setUp();
        FactoryRegistry factoryRegistry = new FactoryRegistry();
        GaugeFactory gaugeFactory = new GaugeFactory();
        VotingRewardsFactory rewardsFactory = new VotingRewardsFactory();
        factoryRegistry.approveGaugeFactory(address(gaugeFactory), address(rewardsFactory));

        ValidatorsVoter implementation = new ValidatorsVoter(makeAddr("ve-mon-forwarder"));
        bytes memory init = abi.encodeCall(
            ValidatorsVoter.initialize,
            (
                address(veMON),
                address(factoryRegistry),
                address(0),
                address(registry),
                address(controller),
                address(gaugeFactory)
            )
        );
        voter = ValidatorsVoter(address(new ERC1967Proxy(address(implementation), init)));
        controller.setVoter(address(voter));
    }
}
