// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {StakingController} from "../src/StakingController.sol";
import {StakingControllerFixture} from "./fixtures/StakingControllerFixture.sol";

contract StakingControllerTest is StakingControllerFixture {
    function test_constructorDeploysVeMONAndVaultImplementation() public view {
        assertEq(address(controller.registry()), address(registry));
        assertEq(controller.owner(), address(this));
        assertEq(address(controller.veMON()), address(veMON));
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

    function test_onlyOwnerCanSetValidatorConfig() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        vm.prank(operator);
        controller.setValidatorConfig(validatorStake, commission);

        _setValidatorConfig();

        assertEq(controller.validatorAmount(), validatorStake);
        assertEq(controller.commission(), commission);
    }

    function test_receiveOnlyAcceptsMONFromVeMON() public {
        vm.prank(operator);
        (bool success,) = address(controller).call{value: validatorStake}("");
        assertFalse(success);
    }
}
