// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ValidatorGauge} from "../src/voting/ValidatorGauge.sol";
import {StakingVault} from "../src/staking/controlled/StakingVault.sol";
import {IValidatorRegistry} from "../src/interfaces/IValidatorRegistry.sol";
import {IStakingController} from "../src/interfaces/IStakingController.sol";
import {ValidatorGaugeFixture} from "./fixtures/ValidatorGaugeFixture.sol";
import {StakingAgent} from "../src/staking/controlled/StakingAgent.sol";

contract ValidatorGaugeTest is ValidatorGaugeFixture {
    function test_createValidatorSubmitsRequestAndCreatesVaultAndGaugeAtomically() public {
        bytes32 saltSeed = keccak256("create-validator-entrypoint");
        address expectedAuthAddress = controller.predictVaultAddress(operator, saltSeed);
        bytes memory payload = abi.encodePacked(
            secpPubkey, blsPubkey, bytes20(expectedAuthAddress), bytes32(validatorStake), bytes32(commission)
        );

        vm.prank(operator);
        (uint256 requestId, address vaultAddress, address gaugeAddress) =
            controller.createValidator(saltSeed, expectedAuthAddress, payload, secpSig, blsSig);

        IValidatorRegistry.Submission memory submission = registry.getSubmission(requestId);
        assertEq(submission.requester, address(controller));
        assertEq(submission.operator, operator);
        assertEq(controller.validatorGaugeForRequest(requestId), gaugeAddress);
        assertEq(controller.vaultForValidatorGauge(gaugeAddress), vaultAddress);
        assertEq(controller.vaultByGauge(gaugeAddress), vaultAddress);
        assertEq(StakingVault(payable(vaultAddress)).requestId(), requestId);
    }

    function test_createValidatorRollsBackRegistryRequestOnInvalidAuthAddress() public {
        bytes32 saltSeed = keccak256("bad-create-validator");
        address expectedAuthAddress = controller.predictVaultAddress(operator, saltSeed);
        bytes memory payload = abi.encodePacked(
            secpPubkey, blsPubkey, bytes20(expectedAuthAddress), bytes32(validatorStake), bytes32(commission)
        );

        vm.prank(operator);
        vm.expectRevert(IStakingController.UnexpectedAuthAddress.selector);
        controller.createValidator(saltSeed, address(uint160(expectedAuthAddress) + 1), payload, secpSig, blsSig);

        assertEq(registry.nextId(), 1);
    }

    function test_newRequestAdmissionCreatesOneCanonicalGaugeAndVault() public {
        bytes32 saltSeed = keccak256("new-validator-gauge");
        address expectedAuthAddress = controller.predictVaultAddress(operator, saltSeed);
        bytes memory payload = abi.encodePacked(
            secpPubkey, blsPubkey, bytes20(expectedAuthAddress), bytes32(validatorStake), bytes32(commission)
        );
        vm.prank(operator);
        uint256 requestId = registry.requestValidator(payload, secpSig, blsSig);

        vm.prank(operator);
        (address vaultAddress, address gaugeAddress) = controller.admitValidatorRequest(requestId, saltSeed);

        assertTrue(controller.isValidatorGauge(gaugeAddress));
        assertEq(controller.validatorGaugeForRequest(requestId), gaugeAddress);
        assertEq(controller.requestForValidatorGauge(gaugeAddress), requestId);
        assertEq(controller.vaultForValidatorGauge(gaugeAddress), vaultAddress);
        assertEq(controller.vaultByGauge(gaugeAddress), vaultAddress);
        assertEq(controller.gaugeByVault(vaultAddress), gaugeAddress);
        assertEq(controller.validatorIdForGauge(gaugeAddress), 0);
        assertEq(controller.validatorGaugeCount(), 1);
        assertEq(ValidatorGauge(gaugeAddress).controller(), address(controller));
        assertEq(ValidatorGauge(gaugeAddress).requestId(), requestId);
        assertEq(ValidatorGauge(gaugeAddress).operator(), operator);
        assertEq(StakingVault(payable(vaultAddress)).requestId(), requestId);
        assertEq(StakingVault(payable(vaultAddress)).validatorId(), 0);
    }

    function test_newValidatorActivationBindsMonadIdToTheSameGauge() public {
        bytes32 saltSeed = keccak256("activate-validator-gauge");
        address expectedAuthAddress = controller.predictVaultAddress(operator, saltSeed);
        bytes memory payload = abi.encodePacked(
            secpPubkey, blsPubkey, bytes20(expectedAuthAddress), bytes32(validatorStake), bytes32(commission)
        );
        vm.prank(operator);
        uint256 requestId = registry.requestValidator(payload, secpSig, blsSig);

        vm.prank(operator);
        (address vaultAddress, address gaugeAddress) = controller.admitValidatorRequest(requestId, saltSeed);

        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);
        address[] memory gauges = new address[](1);
        gauges[0] = gaugeAddress;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = validatorStake;
        vm.prank(operator);
        controller.stake(1, gauges, amounts);

        uint64 validatorId = StakingVault(payable(vaultAddress)).validatorId();
        assertGt(validatorId, 0);
        assertEq(controller.validatorGaugeForRequest(requestId), gaugeAddress);
        assertEq(controller.validatorIdForGauge(gaugeAddress), validatorId);
        assertEq(controller.gaugeForValidatorId(validatorId), gaugeAddress);
    }

    function test_existingMonadValidatorCanBeRequestedAndAdmitted() public {
        vm.prank(operator);
        uint64 validatorId = staking.addValidator{value: validatorStake}(validatorPayload, secpSig, blsSig);
        assertGt(validatorId, 0);

        vm.prank(operator);
        uint256 requestId = registry.requestExistingValidator(validatorId);
        bytes32 saltSeed = keccak256("existing-validator-gauge");

        vm.prank(operator);
        (address vaultAddress, address gaugeAddress) = controller.admitValidatorRequest(requestId, saltSeed);

        StakingVault vault = StakingVault(payable(vaultAddress));
        assertEq(vault.requestId(), requestId);
        assertEq(vault.validatorId(), validatorId);
        assertEq(controller.validatorGaugeForRequest(requestId), gaugeAddress);
        assertEq(controller.gaugeForValidatorId(validatorId), gaugeAddress);
        assertEq(controller.vaultForValidatorGauge(gaugeAddress), vaultAddress);

        vm.prank(operator);
        veMON.createLock{value: delegationAmount}(delegationAmount, lockDuration);
        address[] memory gauges = new address[](1);
        gauges[0] = gaugeAddress;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = delegationAmount;
        vm.prank(operator);
        controller.stake(1, gauges, amounts);
        StakingAgent agent = StakingAgent(payable(controller.agentByToken(1)));
        assertEq(agent.balanceOf(validatorId), delegationAmount);
    }

    function test_requestCannotCreateAnotherGaugeAndUnknownAddressIsNotAValidatorGauge() public {
        bytes32 saltSeed = keccak256("duplicate-validator-gauge");
        address expectedAuthAddress = controller.predictVaultAddress(operator, saltSeed);
        bytes memory payload = abi.encodePacked(
            secpPubkey, blsPubkey, bytes20(expectedAuthAddress), bytes32(validatorStake), bytes32(commission)
        );
        vm.prank(operator);
        uint256 requestId = registry.requestValidator(payload, secpSig, blsSig);
        vm.prank(operator);
        controller.admitValidatorRequest(requestId, saltSeed);

        vm.prank(operator);
        vm.expectRevert(IStakingController.InvalidVault.selector);
        controller.admitValidatorRequest(requestId, saltSeed);

        address arbitraryGauge = makeAddr("arbitrary-gauge");
        assertFalse(controller.isValidatorGauge(arbitraryGauge));
        assertEq(controller.validatorGaugeForRequest(999), address(0));
        vm.expectRevert();
        controller.validatorForGauge(arbitraryGauge);
    }

    function test_existingValidatorRequestRejectsUnknownMonadId() public {
        vm.prank(operator);
        uint256 requestId = registry.requestExistingValidator(type(uint64).max);
        vm.prank(operator);
        vm.expectRevert(IStakingController.InvalidValidatorState.selector);
        controller.admitValidatorRequest(requestId, keccak256("unknown-validator"));
    }

    function test_requestAdmissionUsesOnlyItsCanonicalGaugeAsStakingKey() public {
        bytes32 saltSeed = keccak256("canonical-validator-gauge");
        address expectedAuthAddress = controller.predictVaultAddress(operator, saltSeed);
        bytes memory payload = abi.encodePacked(
            secpPubkey, blsPubkey, bytes20(expectedAuthAddress), bytes32(validatorStake), bytes32(commission)
        );
        vm.prank(operator);
        uint256 requestId = registry.requestValidator(payload, secpSig, blsSig);
        vm.prank(operator);
        (address vaultAddress, address canonicalGauge) = controller.admitValidatorRequest(requestId, saltSeed);
        assertTrue(controller.isValidatorGauge(canonicalGauge));
        assertEq(controller.vaultByGauge(canonicalGauge), vaultAddress);
    }
}
