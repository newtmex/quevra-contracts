// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IValidatorRegistry} from "../../src/interfaces/IValidatorRegistry.sol";
import {IValidatorVoter} from "../../src/interfaces/IValidatorVoter.sol";
import {StakingVault} from "../../src/staking/StakingVault.sol";
import {ValidatorGauge} from "../../src/validators/ValidatorGauge.sol";
import {ValidatorVoter} from "../../src/validators/ValidatorVoter.sol";
import {StakingController} from "../../src/staking/StakingController.sol";
import {VeMON} from "../../src/VeMON.sol";
import {ProtocolTimeLibrary} from "../../src/libraries/ProtocolTimeLibrary.sol";
import {ValidatorVoterFixture} from "../fixtures/ValidatorVoterFixture.sol";

contract ValidatorStackTest is ValidatorVoterFixture {
    function test_createValidatorRequestsAndDeploysVaultAndGaugeAtomically() public {
        vm.prank(operator);
        (uint256 requestId, address vaultAddress, address gaugeAddress) =
            voter.createValidator(initialVault, secpPubkey, blsPubkey, secpSig, blsSig);

        IValidatorVoter.ValidatorStack memory stack = voter.stackByRequest(requestId);
        assertEq(stack.vault, vaultAddress);
        assertEq(stack.gauge, gaugeAddress);
        assertEq(stack.validatorId, 0);

        StakingVault vault = StakingVault(payable(vaultAddress));
        ValidatorGauge gauge = ValidatorGauge(gaugeAddress);
        assertEq(vault.owner(), address(controller));
        assertEq(address(vault.registry()), address(registry));
        assertEq(vault.requestId(), requestId);
        assertEq(gauge.registry(), address(registry));
        assertEq(gauge.vault(), vaultAddress);
        assertEq(gauge.operator(), operator);
        assertEq(gauge.requestId(), requestId);
        assertEq(gauge.validatorId(), 0);
        assertEq(uint256(registry.getSubmission(requestId).status), uint256(IValidatorRegistry.Status.Submitted));
    }

    function test_createValidatorRejectsInvalidDataBeforeRequestOrDeployment() public {
        address invalidPrediction = controller.predictVaultAddress(operator, hex"01", blsPubkey);
        vm.prank(operator);
        vm.expectRevert(IValidatorRegistry.InvalidValidatorData.selector);
        voter.createValidator(invalidPrediction, hex"01", blsPubkey, secpSig, blsSig);

        assertEq(registry.nextId(), 1);
    }

    function test_duplicateValidatorCannotCreateSecondVaultOrGauge() public {
        vm.prank(operator);
        voter.createValidator(initialVault, secpPubkey, blsPubkey, secpSig, blsSig);

        address freshPrediction = controller.predictVaultAddress(operator, secpPubkey, blsPubkey);
        vm.prank(operator);
        vm.expectRevert(IValidatorRegistry.KeyAlreadyRegistered.selector);
        voter.createValidator(freshPrediction, secpPubkey, blsPubkey, secpSig, blsSig);
        assertEq(registry.nextId(), 2);
    }

    function test_createValidatorFailureRollsBackRequestAndDeployments() public {
        // Invalid data reverts before the registry request or CREATE operations,
        // so no request, vault, or gauge state can be left behind.
        address invalidPrediction = controller.predictVaultAddress(operator, secpPubkey, new bytes(0));
        vm.prank(operator);
        vm.expectRevert(IValidatorRegistry.InvalidValidatorData.selector);
        voter.createValidator(invalidPrediction, secpPubkey, new bytes(0), secpSig, blsSig);

        assertEq(registry.nextId(), 1);
        IValidatorVoter.ValidatorStack memory stack = voter.stackByRequest(1);
        assertEq(stack.vault, address(0));
    }

    function test_onlyOperatorCanCancelThroughVoterAndDirectRegistryCancelIsBlocked() public {
        vm.prank(operator);
        (uint256 requestId,,) = voter.createValidator(initialVault, secpPubkey, blsPubkey, secpSig, blsSig);

        vm.prank(operator);
        vm.expectRevert(IValidatorRegistry.NotOperator.selector);
        registry.cancel(requestId);

        vm.prank(address(this));
        vm.expectRevert(IValidatorVoter.NotRequestOperator.selector);
        voter.cancel(requestId);

        vm.prank(operator);
        voter.cancel(requestId);
        assertEq(uint256(registry.getSubmission(requestId).status), uint256(IValidatorRegistry.Status.Cancelled));
        assertEq(voter.stackByRequest(requestId).vault, address(0));
    }

    function test_createLockMintsVeMONAndCustodiesMONInController() public {
        controller.setValidatorConfig(validatorStake, commission);
        (address predicted,,) = controller.signingConfigFor(operator, secpPubkey, blsPubkey);
        assertEq(predicted.code.length, 0);
        vm.prank(operator);
        (uint256 requestId,,) = voter.createValidator(predicted, secpPubkey, blsPubkey, secpSig, blsSig);
        assertEq(voter.stackByRequest(requestId).vault, predicted);

        controller.setValidatorConfig(validatorStake, commission);
        (address authAddress, uint256 configuredCommission, uint256 configuredAmount) =
            controller.signingConfig(requestId);
        assertEq(authAddress, voter.stackByRequest(requestId).vault);
        assertEq(configuredCommission, commission);
        assertEq(configuredAmount, validatorStake);
        assertEq(
            registry.stakingPayload(requestId, predicted, validatorStake, commission),
            bytes.concat(secpPubkey, blsPubkey, abi.encodePacked(predicted, validatorStake, commission))
        );

        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);

        vm.prank(stranger);
        veMON.createLock{value: 10 ether}(10 ether, lockDuration);

        assertEq(ValidatorGauge(voter.stackByRequest(requestId).gauge).validatorId(), 0);
        assertEq(uint256(registry.getSubmission(requestId).status), uint256(IValidatorRegistry.Status.Submitted));
        assertEq(registry.getSubmission(requestId).executor, address(0));
        assertEq(address(controller).balance, validatorStake + 10 ether);
        assertEq(veMON.ownerOf(1), operator);
        assertEq(veMON.ownerOf(2), stranger);
        assertEq(veMON.balanceOf(operator), 1);
        assertEq(veMON.balanceOf(stranger), 1);
        uint256 expectedEnd = lockDuration * ProtocolTimeLibrary.EPOCHS_PER_CYCLE;
        (int128 operatorAmount, uint256 operatorEnd, bool operatorPermanent, uint256 operatorBoost) = veMON.locked(1);
        (int128 strangerAmount, uint256 strangerEnd, bool strangerPermanent, uint256 strangerBoost) = veMON.locked(2);
        assertEq(operatorAmount, int128(int256(validatorStake)));
        assertEq(strangerAmount, int128(int256(10 ether)));
        assertEq(operatorEnd, expectedEnd);
        assertEq(strangerEnd, expectedEnd);
        assertFalse(operatorPermanent);
        assertFalse(strangerPermanent);
        assertEq(operatorBoost, 0);
        assertEq(strangerBoost, 0);
    }

    function test_controllerVoterIsOwnerSetOnce() public {
        address replacement = makeAddr("replacement-voter");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        vm.prank(operator);
        controller.setVoter(replacement);

        vm.expectRevert(StakingController.VoterAlreadySet.selector);
        controller.setVoter(replacement);
    }

    function test_onlyOwnerCanSetValidatorConfig() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        vm.prank(operator);
        controller.setValidatorConfig(validatorStake, commission);
    }

    function test_createLockRejectsZeroOrMismatchedValue() public {
        vm.expectRevert(VeMON.InvalidAmount.selector);
        veMON.createLock(0, lockDuration);

        vm.expectRevert(VeMON.InvalidValue.selector);
        veMON.createLock{value: 1 ether}(2 ether, lockDuration);
    }

    function test_createLockRejectsInvalidLockDurations() public {
        vm.expectRevert(VeMON.LockDurationNotInFuture.selector);
        veMON.createLock{value: 1 ether}(1 ether, 0);

        uint256 maxLockCycles = veMON.MAX_LOCK_CYCLES();
        vm.expectRevert(VeMON.LockDurationTooLong.selector);
        veMON.createLock{value: 1 ether}(1 ether, maxLockCycles + 1);
    }

    function test_controllerReceiveOnlyAcceptsMONFromVeMON() public {
        vm.prank(operator);
        (bool success,) = address(controller).call{value: validatorStake}("");
        assertFalse(success);
    }

    function test_unrelatedRequestsDoNotChangePrediction() public {
        controller.setValidatorConfig(validatorStake, commission);
        (address predicted,,) = controller.signingConfigFor(operator, secpPubkey, blsPubkey);
        registry.requestValidator(new bytes(33), new bytes(48), secpSig, blsSig);
        (address unchangedVault,,) = controller.signingConfigFor(operator, secpPubkey, blsPubkey);
        assertEq(unchangedVault, predicted);
        vm.prank(operator);
        (uint256 id, address deployed,) = voter.createValidator(predicted, secpPubkey, blsPubkey, secpSig, blsSig);
        assertEq(id, 2);
        assertEq(deployed, predicted);
        assertEq(StakingVault(payable(deployed)).requestId(), 2);
        vm.prank(operator);
        voter.cancel(id);
        vm.prank(operator);
        vm.expectRevert(StakingController.UnexpectedAuthAddress.selector);
        voter.createValidator(predicted, secpPubkey, blsPubkey, secpSig, blsSig);
    }

    function test_predictionBindsRequesterAndKeys() public view {
        address predicted = controller.predictVaultAddress(operator, secpPubkey, blsPubkey);
        assertTrue(predicted != controller.predictVaultAddress(stranger, secpPubkey, blsPubkey));
        assertTrue(predicted != controller.predictVaultAddress(operator, new bytes(33), blsPubkey));
        assertTrue(predicted != controller.predictVaultAddress(operator, secpPubkey, new bytes(48)));
    }

    function test_wrongAuthAddressRollsBackRequestAndGauge() public {
        address predictedGauge = vm.computeCreateAddress(address(voter), vm.getNonce(address(voter)));
        vm.prank(stranger);
        vm.expectRevert(StakingController.UnexpectedAuthAddress.selector);
        voter.createValidator(initialVault, secpPubkey, blsPubkey, secpSig, blsSig);
        assertEq(registry.nextId(), 1);
        assertEq(registry.idBySecpPubkey(keccak256(secpPubkey)), 0);
        assertEq(initialVault.code.length, 0);
        assertEq(predictedGauge.code.length, 0);
        assertEq(controller.predictVaultAddress(operator, secpPubkey, blsPubkey), initialVault);
    }

    function test_registrationFailureRollsBackCreate2AndRegistry() public {
        StakingController unbound = new StakingController(address(registry), address(this));
        ValidatorVoter unboundVoter = new ValidatorVoter(address(registry), address(unbound));
        address predicted = unbound.predictVaultAddress(operator, secpPubkey, blsPubkey);
        vm.prank(operator);
        vm.expectRevert(StakingController.NotVoter.selector);
        unboundVoter.createValidator(predicted, secpPubkey, blsPubkey, secpSig, blsSig);
        assertEq(registry.nextId(), 1);
        assertEq(predicted.code.length, 0);
        assertEq(registry.idBySecpPubkey(keccak256(secpPubkey)), 0);
        assertEq(unboundVoter.stackByRequest(1).vault, address(0));
    }

    function test_cancelClearsControllerVaultButPreservesGlobalConfiguration() public {
        vm.prank(operator);
        (uint256 requestId,,) = voter.createValidator(initialVault, secpPubkey, blsPubkey, secpSig, blsSig);
        controller.setValidatorConfig(validatorStake, commission);

        vm.prank(operator);
        voter.cancel(requestId);

        assertEq(controller.vaultByRequest(requestId), address(0));
        assertEq(controller.commission(), commission);
        assertEq(controller.validatorAmount(), validatorStake);
        address freshPrediction = controller.predictVaultAddress(operator, secpPubkey, blsPubkey);
        vm.prank(operator);
        (, address freshVault,) = voter.createValidator(freshPrediction, secpPubkey, blsPubkey, secpSig, blsSig);
        assertEq(freshVault, freshPrediction);
    }

    function test_onlyVoterCanDeployClones() public {
        vm.prank(stranger);
        vm.expectRevert(StakingController.NotVoter.selector);
        controller.deployVault(1, operator, initialVault, address(1));
    }

    function test_controllerFailureRollsBackGaugeAndRegistry() public {
        address predicted = controller.predictVaultAddress(operator, secpPubkey, blsPubkey);
        address predictedGauge = vm.computeCreateAddress(address(voter), vm.getNonce(address(voter)));
        vm.mockCallRevert(
            address(controller), abi.encodeWithSelector(StakingController.deployVault.selector), hex"12345678"
        );
        vm.prank(operator);
        vm.expectRevert(bytes4(hex"12345678"));
        voter.createValidator(initialVault, secpPubkey, blsPubkey, secpSig, blsSig);
        assertEq(predicted.code.length, 0);
        assertEq(predictedGauge.code.length, 0);
        assertEq(registry.nextId(), 1);
        assertEq(controller.vaultByRequest(1), address(0));
        assertEq(voter.stackByRequest(1).vault, address(0));
        vm.clearMockedCalls();
        vm.prank(operator);
        (, address deployed, address gauge) =
            voter.createValidator(initialVault, secpPubkey, blsPubkey, secpSig, blsSig);
        assertEq(deployed, predicted);
        assertEq(gauge, predictedGauge);
    }
}
