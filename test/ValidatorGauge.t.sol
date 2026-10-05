// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ValidatorGauge} from "../src/voting/ValidatorGauge.sol";
import {StakingVault} from "../src/staking/controlled/StakingVault.sol";
import {IValidatorRegistry} from "../src/interfaces/IValidatorRegistry.sol";
import {IStakingController} from "../src/interfaces/IStakingController.sol";
import {ValidatorGaugeFixture} from "./fixtures/ValidatorGaugeFixture.sol";
import {StakingAgent} from "../src/staking/controlled/StakingAgent.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

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

contract ValidatorGaugeRewardsTest is ValidatorGaugeFixture {
    ValidatorGauge private gauge;
    ERC20Mock private rewardA;
    ERC20Mock private rewardB;
    ERC20Mock private unlisted;
    uint256 private validatorNonce;

    function setUp() public override {
        super.setUp();
        gauge = _createExistingGauge();
        rewardA = new ERC20Mock();
        rewardB = new ERC20Mock();
        unlisted = new ERC20Mock();
        controller.setRewardTokenWhitelisted(address(rewardA), true);
        controller.setRewardTokenWhitelisted(address(rewardB), true);
        rewardA.mint(stranger, 1_000 ether);
        rewardB.mint(stranger, 1_000 ether);
        vm.startPrank(stranger);
        rewardA.approve(address(gauge), type(uint256).max);
        rewardB.approve(address(gauge), type(uint256).max);
        vm.stopPrank();
        assertEq(_lockAndStake(operator, 70 ether, gauge), 1);
        assertEq(_lockAndStake(executor, 30 ether, gauge), 2);
    }

    function test_whitelistedRewardTokenCanBeAddedToGauge() public {
        _notify(gauge, rewardA, 100 ether);
        assertTrue(gauge.isRewardToken(address(rewardA)));
        assertEq(gauge.rewardTokenCount(), 1);
        assertEq(gauge.rewardTokenAt(0), address(rewardA));
        assertEq(rewardA.balanceOf(address(gauge)), 100 ether);
    }

    function test_nonWhitelistedTokenIsRejectedAndWhitelistIsOwnerControlled() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        controller.setRewardTokenWhitelisted(address(unlisted), true);

        vm.expectRevert(ValidatorGauge.RewardTokenNotWhitelisted.selector);
        gauge.notifyRewardAmount(address(unlisted), 100 ether);

        controller.setRewardTokenWhitelisted(address(rewardA), false);
        vm.expectRevert(ValidatorGauge.RewardTokenNotWhitelisted.selector);
        _notify(gauge, rewardA, 100 ether);
        assertEq(gauge.rewardTokenCount(), 0);
    }

    function test_rewardDepositWithNoWeightReverts() public {
        ValidatorGauge emptyGauge = new ValidatorGauge(address(controller), 999, operator);
        rewardA.mint(stranger, 100 ether);
        vm.startPrank(stranger);
        rewardA.approve(address(emptyGauge), 100 ether);
        vm.expectRevert(ValidatorGauge.NoGaugeWeight.selector);
        emptyGauge.notifyRewardAmount(address(rewardA), 100 ether);
        vm.stopPrank();
        assertEq(rewardA.balanceOf(address(emptyGauge)), 0);
    }

    function test_twoTokenIdsReceiveRewardsInSeventyThirtyRatio() public {
        assertEq(gauge.weightOf(1) * 3, gauge.weightOf(2) * 7);
        _notify(gauge, rewardA, 100 ether);
        assertApproxEqAbs(gauge.earned(1, address(rewardA)), 70 ether, 1);
        assertApproxEqAbs(gauge.earned(2, address(rewardA)), 30 ether, 1);

        vm.prank(stranger);
        vm.expectRevert(ValidatorGauge.NotTokenOwner.selector);
        gauge.claimRewards(1);
        vm.prank(operator);
        gauge.claimRewards(1);
        vm.prank(executor);
        gauge.claimRewards(2);
        assertApproxEqAbs(rewardA.balanceOf(operator), 70 ether, 1);
        assertApproxEqAbs(rewardA.balanceOf(executor), 30 ether, 1);
    }

    function test_multipleRewardTokensAccountIndependently() public {
        _notify(gauge, rewardA, 100 ether);
        _notify(gauge, rewardB, 200 ether);
        assertEq(gauge.rewardTokenCount(), 2);
        assertApproxEqAbs(gauge.earned(1, address(rewardA)), 70 ether, 1);
        assertApproxEqAbs(gauge.earned(1, address(rewardB)), 140 ether, 1);
        assertApproxEqAbs(gauge.earned(2, address(rewardA)), 30 ether, 1);
        assertApproxEqAbs(gauge.earned(2, address(rewardB)), 60 ether, 1);

        vm.prank(operator);
        gauge.claimRewards(1);
        assertApproxEqAbs(rewardA.balanceOf(operator), 70 ether, 1);
        assertApproxEqAbs(rewardB.balanceOf(operator), 140 ether, 1);
    }

    function test_weightChangeCheckpointsPreviouslyEarnedRewards() public {
        _notify(gauge, rewardA, 100 ether);
        _setEpoch(5, false);
        _unstake(operator, 1, 40 ether, gauge);
        assertEq(gauge.weightOf(1), gauge.weightOf(2));
        assertApproxEqAbs(gauge.rewards(1, address(rewardA)), 70 ether, 1);

        _notify(gauge, rewardA, 100 ether);
        assertApproxEqAbs(gauge.earned(1, address(rewardA)), 120 ether, 1);
        assertApproxEqAbs(gauge.earned(2, address(rewardA)), 80 ether, 1);
    }

    function test_fullExitStillAllowsClaimOfEarlierRewards() public {
        _notify(gauge, rewardA, 100 ether);
        _setEpoch(5, false);
        _unstake(operator, 1, 70 ether, gauge);
        assertEq(gauge.weightOf(1), 0);
        _notify(gauge, rewardA, 30 ether);
        assertApproxEqAbs(gauge.earned(1, address(rewardA)), 70 ether, 1);
        vm.prank(operator);
        gauge.claimRewards(1);
        assertApproxEqAbs(rewardA.balanceOf(operator), 70 ether, 1);
        assertApproxEqAbs(gauge.earned(2, address(rewardA)), 60 ether, 1);
    }

    function test_laterVoterDoesNotReceiveEarlierDeposit() public {
        _notify(gauge, rewardA, 100 ether);
        assertEq(_lockAndStake(stranger, 10 ether, gauge), 3);
        assertEq(gauge.earned(3, address(rewardA)), 0);
        _notify(gauge, rewardA, 110 ether);
        assertApproxEqAbs(gauge.earned(3, address(rewardA)), 10 ether, 1);
    }

    function test_claimingOneRewardDoesNotTouchAnother() public {
        _notify(gauge, rewardA, 100 ether);
        _notify(gauge, rewardB, 200 ether);
        vm.prank(operator);
        gauge.claimReward(1, address(rewardA));
        assertApproxEqAbs(rewardA.balanceOf(operator), 70 ether, 1);
        assertEq(rewardB.balanceOf(operator), 0);
        assertApproxEqAbs(gauge.earned(1, address(rewardB)), 140 ether, 1);
        vm.prank(operator);
        gauge.claimRewards(1);
        assertApproxEqAbs(rewardB.balanceOf(operator), 140 ether, 1);
    }

    function test_multipleGaugesHaveIndependentAccounting() public {
        ValidatorGauge otherGauge = _createExistingGauge();
        vm.prank(stranger);
        rewardA.approve(address(otherGauge), type(uint256).max);
        assertEq(_lockAndStake(operator, 10 ether, otherGauge), 3);
        _notify(gauge, rewardA, 100 ether);
        _notify(otherGauge, rewardA, 50 ether);
        assertApproxEqAbs(gauge.earned(1, address(rewardA)), 70 ether, 1);
        assertEq(gauge.earned(3, address(rewardA)), 0);
        assertApproxEqAbs(otherGauge.earned(3, address(rewardA)), 50 ether, 1);
        assertEq(otherGauge.earned(1, address(rewardA)), 0);

        vm.prank(operator);
        gauge.claimRewards(1);
        assertApproxEqAbs(otherGauge.earned(3, address(rewardA)), 50 ether, 1);
    }

    function test_notifyCostDoesNotGrowWithBackingTokenIds() public {
        uint256 gasBefore = gasleft();
        _notify(gauge, rewardA, 100 ether);
        uint256 twoVoterGas = gasBefore - gasleft();

        for (uint256 i; i < 8; ++i) {
            address voter = makeAddr(string(abi.encodePacked("voter", vm.toString(i))));
            vm.deal(voter, 10 ether);
            _lockAndStake(voter, 1 ether, gauge);
        }
        gasBefore = gasleft();
        _notify(gauge, rewardB, 100 ether);
        uint256 tenVoterGas = gasBefore - gasleft();
        assertLt(tenVoterGas, twoVoterGas + 40_000);
    }

    function _createExistingGauge() private returns (ValidatorGauge created) {
        bytes memory validatorSecpPubkey;
        bytes memory validatorBlsPubkey;
        if (validatorNonce == 0) {
            validatorSecpPubkey = secpPubkey;
            validatorBlsPubkey = blsPubkey;
        } else {
            validatorSecpPubkey = hex"02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5";
            validatorBlsPubkey =
            hex"a572cbea904d67468808c8eb50a9450c9721db309128012543902d0ac358a62ae28f75bb8f1c7c42c39a8c5529bf0f4e";
        }
        bytes memory payload = abi.encodePacked(
            validatorSecpPubkey,
            validatorBlsPubkey,
            bytes20(address(uint160(0x1234 + validatorNonce++))),
            bytes32(validatorStake),
            bytes32(commission)
        );
        vm.prank(operator);
        uint64 validatorId = staking.addValidator{value: validatorStake}(payload, secpSig, blsSig);
        vm.prank(operator);
        uint256 requestId = registry.requestExistingValidator(validatorId);
        vm.prank(operator);
        (, address gaugeAddress) = controller.admitValidatorRequest(requestId, bytes32(requestId));
        created = ValidatorGauge(gaugeAddress);
    }

    function _lockAndStake(address voter, uint256 amount, ValidatorGauge target) private returns (uint256 tokenId) {
        vm.prank(voter);
        tokenId = veMON.createLock{value: amount}(amount, lockDuration);
        address[] memory gauges = new address[](1);
        gauges[0] = address(target);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        vm.prank(voter);
        controller.stake(tokenId, gauges, amounts);
    }

    function _unstake(address voter, uint256 tokenId, uint256 amount, ValidatorGauge target) private {
        address[] memory gauges = new address[](1);
        gauges[0] = address(target);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        vm.prank(voter);
        controller.unstake(tokenId, gauges, amounts);
    }

    function _notify(ValidatorGauge target, ERC20Mock token, uint256 amount) private {
        vm.prank(stranger);
        target.notifyRewardAmount(address(token), amount);
    }
}
