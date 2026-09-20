// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ValidatorsVoter} from "../../src/ValidatorsVoter.sol";
import {StakingControllerFixture} from "./StakingControllerFixture.sol";
import {GaugeFactory} from "../../src/factories/GaugeFactory.sol";
import {FactoryRegistry} from "../../src/factories/FactoryRegistry.sol";
import {VotingRewardsFactory} from "../../src/factories/VotingRewardsFactory.sol";

abstract contract ValidatorsVoterFixture is StakingControllerFixture {
    address internal forwarder = makeAddr("trusted-forwarder");
    address internal ve = makeAddr("veMON");
    address internal rewardToken = makeAddr("reward-token");

    FactoryRegistry internal factoryRegistry;
    GaugeFactory internal gaugeFactory;
    VotingRewardsFactory internal rewardsFactory;
    ValidatorsVoter internal validatorsVoter;

    function setUp() public virtual override {
        super.setUp();
        factoryRegistry = new FactoryRegistry();
        gaugeFactory = new GaugeFactory();
        rewardsFactory = new VotingRewardsFactory();
        factoryRegistry.approveGaugeFactory(address(gaugeFactory), address(rewardsFactory));

        ValidatorsVoter implementation = new ValidatorsVoter(forwarder);
        bytes memory init = abi.encodeCall(
            ValidatorsVoter.initialize,
            (ve, address(factoryRegistry), rewardToken, address(registry), address(controller), address(gaugeFactory))
        );
        validatorsVoter = ValidatorsVoter(address(new ERC1967Proxy(address(implementation), init)));
        controller.setVoter(address(validatorsVoter));
    }

    function _createValidator() internal returns (uint256 id, address vault, address gauge) {
        address expectedAuthAddress = controller.predictVaultAddress(operator, secpPubkey, blsPubkey);
        vm.prank(operator);
        return validatorsVoter.createValidator(expectedAuthAddress, secpPubkey, blsPubkey, secpSig, blsSig);
    }
}
