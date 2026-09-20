// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ValidatorsVoterFixture} from "./fixtures/ValidatorsVoterFixture.sol";
import {NonStakingGauge} from "../src/gauges/NonStakingGauge.sol";
import {StakingVault} from "../src/staking/StakingVault.sol";
import {IValidatorRegistry} from "../src/interfaces/IValidatorRegistry.sol";

contract ValidatorsVoterTest is ValidatorsVoterFixture {
    function test_createValidatorCreatesInitializedVaultAndWiredGauge() public {
        (uint256 requestId, address vault, address gauge) = _createValidator();

        assertEq(StakingVault(payable(vault)).requestId(), requestId);
        assertEq(controller.vaultByRequest(requestId), vault);
        assertEq(validatorsVoter.validatorToGauge(requestId), gauge);
        assertTrue(validatorsVoter.isGauge(gauge));
        assertTrue(validatorsVoter.isAlive(gauge));
        assertEq(NonStakingGauge(gauge).voter(), address(validatorsVoter));
        assertEq(NonStakingGauge(gauge).ve(), ve);
        assertEq(NonStakingGauge(gauge).rewardsBeneficiary(), operator);
        assertTrue(validatorsVoter.gaugeToBribe(gauge) != address(0));
        IValidatorRegistry.Submission memory submission = registry.getSubmission(requestId);
        assertEq(uint256(submission.status), uint256(IValidatorRegistry.Status.Submitted));
        assertEq(submission.operator, operator);
        assertEq(submission.requester, address(validatorsVoter));
    }

    function test_createValidatorRevertsForUnexpectedAuthAddressAndRollsBackSubmission() public {
        address expectedAuthAddress = controller.predictVaultAddress(operator, secpPubkey, blsPubkey);
        vm.prank(operator);
        vm.expectRevert();
        validatorsVoter.createValidator(
            address(uint160(expectedAuthAddress) + 1), secpPubkey, blsPubkey, secpSig, blsSig
        );
        assertEq(registry.nextId(), 1);
    }

    function test_notifyValidatorLeftKillsGaugeAfterSubmissionIsCancelled() public {
        (uint256 requestId,, address gauge) = _createValidator();

        vm.prank(operator);
        validatorsVoter.cancel(requestId);

        assertFalse(validatorsVoter.isAlive(gauge));
        assertEq(validatorsVoter.validatorToGauge(requestId), address(0));
        assertEq(controller.vaultByRequest(requestId), address(0));
        assertEq(uint256(registry.getSubmission(requestId).status), uint256(IValidatorRegistry.Status.Cancelled));
    }

    function test_operatorCanManageMultipleSubmissionsById() public {
        (uint256 firstId,, address firstGauge) = _createValidator();
        bytes memory secondSecpPubkey = abi.encodePacked(bytes1(0x02), bytes32(uint256(2)));
        bytes memory secondBlsPubkey = abi.encodePacked(bytes32(uint256(3)), bytes16(uint128(4)));
        address secondAuthAddress = controller.predictVaultAddress(operator, secondSecpPubkey, secondBlsPubkey);

        vm.prank(operator);
        (uint256 secondId,, address secondGauge) =
            validatorsVoter.createValidator(secondAuthAddress, secondSecpPubkey, secondBlsPubkey, secpSig, blsSig);

        assertTrue(firstId != secondId);
        assertEq(validatorsVoter.validatorToGauge(firstId), firstGauge);
        assertEq(validatorsVoter.validatorToGauge(secondId), secondGauge);

        vm.prank(operator);
        validatorsVoter.cancel(firstId);

        assertFalse(validatorsVoter.isAlive(firstGauge));
        assertTrue(validatorsVoter.isAlive(secondGauge));
        assertEq(validatorsVoter.validatorToGauge(secondId), secondGauge);
        validatorsVoter.notifyValidatorLeft(secondId);
        assertTrue(validatorsVoter.isAlive(secondGauge));
    }
}
