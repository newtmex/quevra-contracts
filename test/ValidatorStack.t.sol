// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MonadVm} from "monad-std/MonadVm.sol";

import {IValidatorRegistry} from "../src/interfaces/IValidatorRegistry.sol";
import {IValidatorVoter} from "../src/interfaces/IValidatorVoter.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {ValidatorGauge} from "../src/ValidatorGauge.sol";
import {ValidatorRegistry} from "../src/ValidatorRegistry.sol";
import {ValidatorVoter} from "../src/ValidatorVoter.sol";
import {StakingController} from "../src/StakingController.sol";
import {VeMON} from "../src/VeMON.sol";

contract ValidatorStackTest is Test {
    MonadVm internal constant monadVm = MonadVm(0xc0FFeeCD43A10e1C2b0De63c6CDCFe5B7d0e0CEA);
    ValidatorRegistry internal registry;
    ValidatorVoter internal voter;
    StakingController internal controller;
    VeMON internal veMON;

    address internal initialVault;
    address internal operator = makeAddr("operator");
    address internal stranger = makeAddr("stranger");
    bytes internal secpPubkey = hex"0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
    bytes internal blsPubkey =
        hex"97f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb";
    bytes internal secpSig = hex"1111";
    bytes internal blsSig = bytes.concat(bytes1(0x80), new bytes(95));
    uint256 internal stake = 100_000 ether;
    uint256 internal commission = 1e17;
    uint256 internal lockDuration = 52 weeks;

    function setUp() public {
        registry = new ValidatorRegistry();
        controller = new StakingController(address(registry), address(this));
        veMON = controller.veMON();
        voter = new ValidatorVoter(address(registry), address(controller));
        controller.setVoter(address(voter));
        initialVault = controller.predictVaultAddress(operator, secpPubkey, blsPubkey);
        monadVm.setEpoch(0, false);
        vm.deal(operator, 1_000_000 ether);
        vm.deal(stranger, 1_000_000 ether);
    }

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
        assertEq(uint256(registry.getProposal(requestId).status), uint256(IValidatorRegistry.Status.Proposed));
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
        assertEq(uint256(registry.getProposal(requestId).status), uint256(IValidatorRegistry.Status.Cancelled));
        assertEq(voter.stackByRequest(requestId).vault, address(0));
    }

    function test_createLockMintsVeMONAndCustodiesMONInController() public {
        controller.setValidatorConfig(stake, commission);
        (address predicted,,) = controller.signingConfigFor(operator, secpPubkey, blsPubkey);
        assertEq(predicted.code.length, 0);
        vm.prank(operator);
        (uint256 requestId,,) = voter.createValidator(predicted, secpPubkey, blsPubkey, secpSig, blsSig);
        assertEq(voter.stackByRequest(requestId).vault, predicted);

        controller.setValidatorConfig(stake, commission);
        (address authAddress, uint256 configuredCommission, uint256 configuredAmount) =
            controller.signingConfig(requestId);
        assertEq(authAddress, voter.stackByRequest(requestId).vault);
        assertEq(configuredCommission, commission);
        assertEq(configuredAmount, stake);
        assertEq(
            registry.stakingPayload(requestId, predicted, stake, commission),
            bytes.concat(secpPubkey, blsPubkey, abi.encodePacked(predicted, stake, commission))
        );

        vm.prank(operator);
        veMON.createLock{value: stake}(stake, lockDuration);

        vm.prank(stranger);
        veMON.createLock{value: 10 ether}(10 ether, lockDuration);

        assertEq(ValidatorGauge(voter.stackByRequest(requestId).gauge).validatorId(), 0);
        assertEq(uint256(registry.getProposal(requestId).status), uint256(IValidatorRegistry.Status.Proposed));
        assertEq(registry.getProposal(requestId).executor, address(0));
        assertEq(address(controller).balance, stake + 10 ether);
        assertEq(veMON.ownerOf(1), operator);
        assertEq(veMON.ownerOf(2), stranger);
        assertEq(veMON.balanceOf(operator), 1);
        assertEq(veMON.balanceOf(stranger), 1);
        (uint256 operatorAmount, uint256 operatorDuration) = veMON.locks(1);
        (uint256 strangerAmount, uint256 strangerDuration) = veMON.locks(2);
        assertEq(operatorAmount, stake);
        assertEq(strangerAmount, 10 ether);
        assertEq(operatorDuration, lockDuration);
        assertEq(strangerDuration, lockDuration);
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
        controller.setValidatorConfig(stake, commission);
    }

    function test_createLockRejectsZeroOrMismatchedValue() public {
        vm.expectRevert(VeMON.InvalidAmount.selector);
        veMON.createLock(0, lockDuration);

        vm.expectRevert(VeMON.InvalidValue.selector);
        veMON.createLock{value: 1 ether}(2 ether, lockDuration);
    }

    function test_controllerReceiveOnlyAcceptsMONFromVeMON() public {
        vm.prank(operator);
        (bool success,) = address(controller).call{value: stake}("");
        assertFalse(success);
    }

    function test_unrelatedRequestsDoNotChangePrediction() public {
        controller.setValidatorConfig(stake, commission);
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
        controller.setValidatorConfig(stake, commission);

        vm.prank(operator);
        voter.cancel(requestId);

        assertEq(controller.vaultByRequest(requestId), address(0));
        assertEq(controller.commission(), commission);
        assertEq(controller.validatorAmount(), stake);
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
