// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IValidatorRegistry} from "../src/interfaces/IValidatorRegistry.sol";
import {IValidatorVoter} from "../src/interfaces/IValidatorVoter.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {ValidatorGauge} from "../src/ValidatorGauge.sol";
import {StakingController} from "../src/StakingController.sol";
import {ValidatorVoterFixture} from "./fixtures/ValidatorVoterFixture.sol";

contract ValidatorVoterTest is ValidatorVoterFixture {
    function test_createValidatorRequestsAndDeploysVaultAndGaugeAtomically() public {
        (uint256 id, address vaultAddress, address gaugeAddress) = _createValidatorStack();

        IValidatorVoter.ValidatorStack memory stack = voter.stackByRequest(id);
        assertEq(stack.vault, vaultAddress);
        assertEq(stack.gauge, gaugeAddress);
        assertEq(stack.validatorId, 0);
        assertEq(stack.operator, operator);

        StakingVault vault = StakingVault(payable(vaultAddress));
        ValidatorGauge gauge = ValidatorGauge(gaugeAddress);
        assertEq(vault.owner(), address(controller));
        assertEq(address(vault.registry()), address(registry));
        assertEq(vault.requestId(), id);
        assertEq(gauge.registry(), address(registry));
        assertEq(gauge.vault(), vaultAddress);
        assertEq(gauge.operator(), operator);
        assertEq(gauge.requestId(), id);
        assertEq(gauge.validatorId(), 0);
    }

    function test_createValidatorRejectsInvalidDataBeforeRequestOrDeployment() public {
        address invalidPrediction = controller.predictVaultAddress(operator, hex"01", blsPubkey);
        vm.prank(operator);
        vm.expectRevert(IValidatorRegistry.InvalidValidatorData.selector);
        voter.createValidator(invalidPrediction, hex"01", blsPubkey, secpSig, blsSig);

        assertEq(registry.nextId(), 1);
    }

    function test_onlyOperatorCanCancelThroughVoter() public {
        (uint256 id,,) = _createValidatorStack();

        vm.prank(address(this));
        vm.expectRevert(IValidatorVoter.NotRequestOperator.selector);
        voter.cancel(id);

        vm.prank(operator);
        voter.cancel(id);

        assertEq(uint256(registry.getProposal(id).status), uint256(IValidatorRegistry.Status.Cancelled));
        assertEq(voter.stackByRequest(id).vault, address(0));
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
        assertEq(voter.stackByRequest(1).vault, address(0));
        vm.clearMockedCalls();
    }

    function test_onlyOwnerCanUpdateRewardTokenWhitelist() public {
        address token = makeAddr("token");
        vm.prank(stranger);
        vm.expectRevert();
        voter.setRewardTokenWhitelisted(token, true);

        voter.setRewardTokenWhitelisted(token, true);
        assertTrue(voter.isRewardTokenWhitelisted(token));
        voter.setRewardTokenWhitelisted(token, false);
        assertFalse(voter.isRewardTokenWhitelisted(token));
    }

    function test_onlyOwnerCanSetValidatorAcceptance() public {
        (uint256 id,,) = _createValidatorStack();
        vm.prank(stranger);
        vm.expectRevert();
        voter.setValidatorAccepted(id, 1, true);

        voter.setValidatorAccepted(id, 1, true);
        assertTrue(voter.validatorAccepted(id, 1));
    }
}
