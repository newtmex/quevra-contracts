// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ValidatorsVoter} from "../src/ValidatorsVoter.sol";
import {FactoryRegistry} from "../src/factories/FactoryRegistry.sol";
import {GaugeFactory} from "../src/factories/GaugeFactory.sol";
import {VotingRewardsFactory} from "../src/factories/VotingRewardsFactory.sol";

import {StakingController} from "../src/staking/StakingController.sol";
import {StakingControllerFixture} from "./fixtures/StakingControllerFixture.sol";

contract StakingControllerTest is StakingControllerFixture {
    function test_constructorSetsRegistryAndVaultImplementation() public view {
        assertEq(address(controller.registry()), address(registry));
        assertEq(controller.owner(), address(this));
        assertTrue(address(veMON) != address(controller));
        assertTrue(controller.vaultImplementation() != address(0));
    }

    function test_voterIsOwnerSetOnce() public {
        address voter = makeAddr("voter");
        address replacement = makeAddr("replacement-voter");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        vm.prank(operator);
        controller.setVoter(voter);

        controller.setVoter(voter);

        vm.expectRevert(StakingController.VoterAlreadySet.selector);
        controller.setVoter(replacement);
    }

    function test_onlyOwnerCanSetCommission() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        vm.prank(operator);
        controller.setCommission(commission);

        vm.expectEmit(false, false, false, true);
        emit StakingController.ValidatorCommissionSet(commission);
        _setCommission();

        assertEq(controller.commission(), commission);
    }

    function test_setCommissionEnforcesPrecompileMaximum() public {
        controller.setCommission(controller.MAX_COMMISSION());
        assertEq(controller.commission(), controller.MAX_COMMISSION());

        uint256 invalidCommission = controller.MAX_COMMISSION() + 1;
        vm.expectRevert(StakingController.InvalidCommission.selector);
        controller.setCommission(invalidCommission);
    }

    function test_signingConfigForUsesFixedStakeAmount() public {
        controller.setVoter(makeAddr("voter"));
        (address authAddress, uint256 configuredCommission, uint256 amount) =
            controller.signingConfigFor(operator, secpPubkey, blsPubkey);

        assertEq(authAddress, controller.predictVaultAddress(operator, secpPubkey, blsPubkey));
        assertEq(configuredCommission, 0);
        assertEq(amount, controller.VALIDATOR_STAKE_AMOUNT());
    }

    function test_receiveOnlyAcceptsMONFromVeMON() public {
        FactoryRegistry factoryRegistry = new FactoryRegistry();
        GaugeFactory gaugeFactory = new GaugeFactory();
        VotingRewardsFactory rewardsFactory = new VotingRewardsFactory();
        factoryRegistry.approveGaugeFactory(address(gaugeFactory), address(rewardsFactory));
        address forwarder = makeAddr("controller-test-forwarder");
        ValidatorsVoter implementation = new ValidatorsVoter(forwarder);
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
        ValidatorsVoter voter = ValidatorsVoter(address(new ERC1967Proxy(address(implementation), init)));
        controller.setVoter(address(voter));

        vm.prank(operator);
        (bool success,) = address(controller).call{value: validatorStake}("");
        assertFalse(success);

        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);
        assertEq(address(controller).balance, validatorStake);
    }
}
