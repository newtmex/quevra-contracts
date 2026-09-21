// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ValidatorsVoterFixture} from "./fixtures/ValidatorsVoterFixture.sol";
import {NonStakingGauge} from "../src/gauges/NonStakingGauge.sol";
import {StakingVault} from "../src/staking/StakingVault.sol";
import {IValidatorRegistry} from "../src/interfaces/IValidatorRegistry.sol";
import {IReward} from "../src/interfaces/IReward.sol";

contract ValidatorsVoterTest is ValidatorsVoterFixture {
    function test_createValidatorCreatesInitializedVaultAndWiredGauge() public {
        (uint256 requestId, address vault, address gauge) = _createValidator();

        assertEq(StakingVault(payable(vault)).requestId(), requestId);
        assertEq(controller.vaultByRequest(requestId), vault);
        assertEq(validatorsVoter.validatorToGauge(requestId), gauge);
        assertTrue(validatorsVoter.isGauge(gauge));
        assertTrue(validatorsVoter.isAlive(gauge));
        assertEq(NonStakingGauge(gauge).voter(), address(validatorsVoter));
        assertEq(NonStakingGauge(gauge).ve(), address(veMON));
        assertEq(NonStakingGauge(gauge).rewardsBeneficiary(), operator);
        assertTrue(validatorsVoter.gaugeToBribe(gauge) != address(0));
        IValidatorRegistry.Submission memory submission = registry.getSubmission(requestId);
        assertEq(uint256(submission.status), uint256(IValidatorRegistry.Status.Submitted));
        assertEq(submission.operator, operator);
        assertEq(submission.requester, address(validatorsVoter));
    }

    function test_createValidatorRevertsForUnexpectedAuthAddressAndRollsBackSubmission() public {
        bytes32 saltSeed = keccak256("validator-0");
        address expectedAuthAddress = controller.predictVaultAddress(operator, saltSeed);
        vm.prank(operator);
        vm.expectRevert();
        validatorsVoter.createValidator(
            saltSeed, address(uint160(expectedAuthAddress) + 1), validatorPayload, secpSig, blsSig
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
        bytes memory secondPayload = abi.encodePacked(
            bytes1(0x02),
            bytes32(uint256(2)),
            blsPubkey,
            bytes20(address(0x1234)),
            bytes32(validatorStake),
            bytes32(commission)
        );
        bytes32 secondSaltSeed = keccak256("validator-1");
        address secondAuthAddress = controller.predictVaultAddress(operator, secondSaltSeed);
        secondPayload = abi.encodePacked(
            bytes1(0x02),
            bytes32(uint256(2)),
            blsPubkey,
            bytes20(secondAuthAddress),
            bytes32(validatorStake),
            bytes32(commission)
        );

        vm.prank(operator);
        (uint256 secondId,, address secondGauge) =
            validatorsVoter.createValidator(secondSaltSeed, secondAuthAddress, secondPayload, secpSig, blsSig);

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

    function test_voteAllocatesProportionallyAndDepositsRewardWeight() public {
        (,, address gaugeA) = _createValidator();
        bytes memory payload2 = abi.encodePacked(
            bytes1(0x02),
            bytes32(uint256(2)),
            blsPubkey,
            bytes20(address(0x1234)),
            bytes32(validatorStake),
            bytes32(commission)
        );
        bytes32 secondSaltSeed = keccak256("validator-1");
        address auth2 = controller.predictVaultAddress(operator, secondSaltSeed);
        payload2 = abi.encodePacked(
            bytes1(0x02), bytes32(uint256(2)), blsPubkey, bytes20(auth2), bytes32(validatorStake), bytes32(commission)
        );
        vm.prank(operator);
        (,, address gaugeB) = validatorsVoter.createValidator(secondSaltSeed, auth2, payload2, secpSig, blsSig);

        uint256 power = 100 ether;
        uint256 tokenId;
        vm.prank(operator);
        tokenId = veMON.createLock{value: power}(power, lockDuration);
        vm.prank(operator);
        veMON.approve(address(validatorsVoter), tokenId);
        _setEpoch(6, false);
        address[] memory gauges = new address[](2);
        gauges[0] = gaugeA;
        gauges[1] = gaugeB;
        uint256[] memory weights_ = new uint256[](2);
        weights_[0] = 1;
        weights_[1] = 3;

        vm.prank(operator);
        validatorsVoter.vote(tokenId, gauges, weights_);

        assertEq(validatorsVoter.votes(tokenId, gaugeA), 25 ether);
        assertEq(validatorsVoter.votes(tokenId, gaugeB), 75 ether);
        assertEq(validatorsVoter.cycleWeights(5, gaugeA), 25 ether);
        assertEq(validatorsVoter.cycleWeights(5, gaugeB), 75 ether);
        assertEq(IReward(validatorsVoter.gaugeToBribe(gaugeA)).balanceOf(tokenId), 25 ether);
        assertEq(IReward(validatorsVoter.gaugeToBribe(gaugeB)).balanceOf(tokenId), 75 ether);
    }
}
