// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {StakingController} from "../src/staking/StakingController.sol";
import {StakingControllerFixture} from "./fixtures/StakingControllerFixture.sol";
import {IBaseVoter} from "../src/interfaces/IBaseVoter.sol";

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

        vm.expectRevert(StakingController.InvalidCommission.selector);
        controller.setCommission(controller.MAX_COMMISSION() + 1);
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
        vm.mockCall(address(veMON), abi.encodeWithSelector(IBaseVoter.ve.selector), abi.encode(address(veMON)));
        controller.setVoter(address(veMON));

        vm.prank(operator);
        (bool success,) = address(controller).call{value: validatorStake}("");
        assertFalse(success);

        vm.deal(address(veMON), validatorStake);
        vm.prank(address(veMON));
        (success,) = address(controller).call{value: validatorStake}("");
        assertTrue(success);
        assertEq(address(controller).balance, validatorStake);
    }
}
