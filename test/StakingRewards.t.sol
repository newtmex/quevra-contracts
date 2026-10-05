// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StakingRewards} from "../src/rewards/StakingRewards.sol";
import {StakingVault} from "../src/staking/controlled/StakingVault.sol";
import {IValidatorRegistry} from "../src/interfaces/IValidatorRegistry.sol";
import {IStakingController} from "../src/interfaces/IStakingController.sol";
import {IReward} from "../src/interfaces/IReward.sol";
import {StakingRewardsFixture} from "./fixtures/StakingRewardsFixture.sol";
import {StakingAgent} from "../src/staking/controlled/StakingAgent.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract StakingRewardsTest is StakingRewardsFixture {
    function test_createValidatorSubmitsRequestAndCreatesVaultAndStakingRewardsAtomically() public {
        bytes32 saltSeed = keccak256("create-validator-entrypoint");
        address expectedAuthAddress = controller.predictVaultAddress(operator, saltSeed);
        bytes memory payload = abi.encodePacked(
            secpPubkey, blsPubkey, bytes20(expectedAuthAddress), bytes32(validatorStake), bytes32(commission)
        );

        vm.prank(operator);
        (uint256 requestId, address vaultAddress, address stakingRewardsAddress) =
            controller.createValidator(saltSeed, expectedAuthAddress, payload, secpSig, blsSig);

        IValidatorRegistry.Submission memory submission = registry.getSubmission(requestId);
        assertEq(submission.requester, address(controller));
        assertEq(submission.operator, operator);
        assertEq(controller.stakingRewardsForRequest(requestId), stakingRewardsAddress);
        assertEq(controller.vaultForStakingRewards(stakingRewardsAddress), vaultAddress);
        assertEq(controller.vaultByStakingRewards(stakingRewardsAddress), vaultAddress);
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

    function test_newRequestAdmissionCreatesOneCanonicalStakingRewardsAndVault() public {
        bytes32 saltSeed = keccak256("new-validator-stakingRewards");
        address expectedAuthAddress = controller.predictVaultAddress(operator, saltSeed);
        bytes memory payload = abi.encodePacked(
            secpPubkey, blsPubkey, bytes20(expectedAuthAddress), bytes32(validatorStake), bytes32(commission)
        );
        vm.prank(operator);
        uint256 requestId = registry.requestValidator(payload, secpSig, blsSig);

        vm.prank(operator);
        (address vaultAddress, address stakingRewardsAddress) = controller.admitValidatorRequest(requestId, saltSeed);

        assertTrue(controller.isStakingRewards(stakingRewardsAddress));
        assertEq(controller.stakingRewardsForRequest(requestId), stakingRewardsAddress);
        assertEq(controller.requestForStakingRewards(stakingRewardsAddress), requestId);
        assertEq(controller.vaultForStakingRewards(stakingRewardsAddress), vaultAddress);
        assertEq(controller.vaultByStakingRewards(stakingRewardsAddress), vaultAddress);
        assertEq(controller.stakingRewardsByVault(vaultAddress), stakingRewardsAddress);
        assertEq(StakingVault(payable(vaultAddress)).validatorId(), 0);
        assertEq(controller.stakingRewardsCount(), 1);
        assertEq(StakingRewards(stakingRewardsAddress).voter(), address(controller));
        assertEq(StakingRewards(stakingRewardsAddress).requestId(), requestId);
        assertEq(StakingRewards(stakingRewardsAddress).operator(), operator);
        assertEq(StakingVault(payable(vaultAddress)).requestId(), requestId);
        assertEq(StakingVault(payable(vaultAddress)).validatorId(), 0);
    }

    function test_newValidatorActivationBindsMonadIdToTheSameStakingRewards() public {
        bytes32 saltSeed = keccak256("activate-validator-stakingRewards");
        address expectedAuthAddress = controller.predictVaultAddress(operator, saltSeed);
        bytes memory payload = abi.encodePacked(
            secpPubkey, blsPubkey, bytes20(expectedAuthAddress), bytes32(validatorStake), bytes32(commission)
        );
        vm.prank(operator);
        uint256 requestId = registry.requestValidator(payload, secpSig, blsSig);

        vm.prank(operator);
        (address vaultAddress, address stakingRewardsAddress) = controller.admitValidatorRequest(requestId, saltSeed);

        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);
        address[] memory vaults = new address[](1);
        vaults[0] = vaultAddress;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = validatorStake;
        vm.prank(operator);
        controller.stake(1, vaults, amounts);

        uint64 validatorId = StakingVault(payable(vaultAddress)).validatorId();
        assertGt(validatorId, 0);
        assertEq(controller.stakingRewardsForRequest(requestId), stakingRewardsAddress);
        assertEq(StakingVault(payable(vaultAddress)).validatorId(), validatorId);
        assertEq(controller.stakingRewardsForValidatorId(validatorId), stakingRewardsAddress);
    }

    function test_existingMonadValidatorCanBeRequestedAndAdmitted() public {
        vm.prank(operator);
        uint64 validatorId = staking.addValidator{value: validatorStake}(validatorPayload, secpSig, blsSig);
        assertGt(validatorId, 0);

        vm.prank(operator);
        uint256 requestId = registry.requestExistingValidator(validatorId);
        bytes32 saltSeed = keccak256("existing-validator-stakingRewards");

        vm.prank(operator);
        (address vaultAddress, address stakingRewardsAddress) = controller.admitValidatorRequest(requestId, saltSeed);

        StakingVault vault = StakingVault(payable(vaultAddress));
        assertEq(vault.requestId(), requestId);
        assertEq(vault.validatorId(), validatorId);
        assertEq(controller.stakingRewardsForRequest(requestId), stakingRewardsAddress);
        assertEq(controller.stakingRewardsForValidatorId(validatorId), stakingRewardsAddress);
        assertEq(controller.vaultForStakingRewards(stakingRewardsAddress), vaultAddress);

        vm.prank(operator);
        veMON.createLock{value: delegationAmount}(delegationAmount, lockDuration);
        address[] memory vaults = new address[](1);
        vaults[0] = vaultAddress;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = delegationAmount;
        vm.prank(operator);
        controller.stake(1, vaults, amounts);
        StakingAgent agent = StakingAgent(payable(controller.agentByToken(1)));
        assertEq(agent.balanceOf(validatorId), delegationAmount);
    }

    function test_requestCannotCreateAnotherStakingRewardsAndUnknownAddressIsNotAStakingRewards() public {
        bytes32 saltSeed = keccak256("duplicate-validator-stakingRewards");
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

        address arbitraryStakingRewards = makeAddr("arbitrary-stakingRewards");
        assertFalse(controller.isStakingRewards(arbitraryStakingRewards));
        assertEq(controller.stakingRewardsForRequest(999), address(0));
        vm.expectRevert();
        controller.validatorForStakingRewards(arbitraryStakingRewards);
    }

    function test_existingValidatorRequestRejectsUnknownMonadId() public {
        vm.prank(operator);
        uint256 requestId = registry.requestExistingValidator(type(uint64).max);
        vm.prank(operator);
        vm.expectRevert(IStakingController.InvalidValidatorState.selector);
        controller.admitValidatorRequest(requestId, keccak256("unknown-validator"));
    }

    function test_requestAdmissionUsesOnlyItsCanonicalStakingRewardsAsStakingKey() public {
        bytes32 saltSeed = keccak256("canonical-validator-stakingRewards");
        address expectedAuthAddress = controller.predictVaultAddress(operator, saltSeed);
        bytes memory payload = abi.encodePacked(
            secpPubkey, blsPubkey, bytes20(expectedAuthAddress), bytes32(validatorStake), bytes32(commission)
        );
        vm.prank(operator);
        uint256 requestId = registry.requestValidator(payload, secpSig, blsSig);
        vm.prank(operator);
        (address vaultAddress, address canonicalStakingRewards) = controller.admitValidatorRequest(requestId, saltSeed);
        assertTrue(controller.isStakingRewards(canonicalStakingRewards));
        assertEq(controller.vaultByStakingRewards(canonicalStakingRewards), vaultAddress);
    }
}

contract StakingRewardsAccountingTest is StakingRewardsFixture {
    StakingRewards private stakingRewards;
    ERC20Mock private rewardA;
    ERC20Mock private rewardB;
    ERC20Mock private unlisted;
    uint256 private validatorNonce;

    function setUp() public override {
        super.setUp();
        stakingRewards = _createExistingRewards();
        rewardA = new ERC20Mock();
        rewardB = new ERC20Mock();
        unlisted = new ERC20Mock();
        controller.setRewardTokenWhitelisted(address(rewardA), true);
        controller.setRewardTokenWhitelisted(address(rewardB), true);
        rewardA.mint(stranger, 1_000 ether);
        rewardB.mint(stranger, 1_000 ether);
        vm.startPrank(stranger);
        rewardA.approve(address(stakingRewards), type(uint256).max);
        rewardB.approve(address(stakingRewards), type(uint256).max);
        vm.stopPrank();
        assertEq(_lockAndStake(operator, 70 ether, stakingRewards), 1);
        assertEq(_lockAndStake(executor, 30 ether, stakingRewards), 2);
    }

    function test_constructorDoesNotRegisterEscrowToken() public {
        assertEq(stakingRewards.rewardsListLength(), 0);
    }

    function test_whitelistedRewardTokenCanBeAddedToStakingRewards() public {
        _notify(stakingRewards, rewardA, 100 ether);
        assertTrue(stakingRewards.isReward(address(rewardA)));
        assertEq(stakingRewards.rewardsListLength(), 1);
        assertEq(stakingRewards.rewardTokens(0), address(rewardA));
        assertEq(stakingRewards.tokenRewardsPerCycle(address(rewardA), 0), 100 ether);
        assertEq(rewardA.balanceOf(address(stakingRewards)), 100 ether);
    }

    function test_nonWhitelistedTokenIsRejectedAndWhitelistIsOwnerControlled() public {
        vm.expectRevert();
        vm.prank(stranger);
        controller.setRewardTokenWhitelisted(address(unlisted), true);

        vm.expectRevert(IReward.NotWhitelisted.selector);
        stakingRewards.notifyRewardAmount(address(unlisted), 100 ether);

        controller.setRewardTokenWhitelisted(address(rewardA), false);
        vm.expectRevert(IReward.NotWhitelisted.selector);
        _notify(stakingRewards, rewardA, 100 ether);
        assertEq(stakingRewards.rewardsListLength(), 0);
    }

    function test_twoTokenIdsReceiveCycleRewardsInSeventyThirtyRatio() public {
        _notify(stakingRewards, rewardA, 100 ether);
        _setEpoch(5, false);
        assertApproxEqAbs(stakingRewards.earned(address(rewardA), 1), 70 ether, 1);
        assertApproxEqAbs(stakingRewards.earned(address(rewardA), 2), 30 ether, 1);

        vm.prank(stranger);
        vm.expectRevert(IReward.NotAuthorized.selector);
        stakingRewards.getReward(1, _oneToken(address(rewardA)));
        vm.prank(operator);
        stakingRewards.getReward(1, _oneToken(address(rewardA)));
        vm.prank(executor);
        stakingRewards.getReward(2, _oneToken(address(rewardA)));
        assertApproxEqAbs(rewardA.balanceOf(operator), 70 ether, 1);
        assertApproxEqAbs(rewardA.balanceOf(executor), 30 ether, 1);
    }

    function test_multipleRewardTokensAccountIndependentlyByCycle() public {
        _notify(stakingRewards, rewardA, 100 ether);
        _notify(stakingRewards, rewardB, 200 ether);
        _setEpoch(5, false);
        assertEq(stakingRewards.rewardsListLength(), 2);
        assertApproxEqAbs(stakingRewards.earned(address(rewardA), 1), 70 ether, 1);
        assertApproxEqAbs(stakingRewards.earned(address(rewardB), 1), 140 ether, 1);
        assertApproxEqAbs(stakingRewards.earned(address(rewardA), 2), 30 ether, 1);
        assertApproxEqAbs(stakingRewards.earned(address(rewardB), 2), 60 ether, 1);

        vm.prank(operator);
        stakingRewards.getReward(1, _rewardTokens());
        assertApproxEqAbs(rewardA.balanceOf(operator), 70 ether, 1);
        assertApproxEqAbs(rewardB.balanceOf(operator), 140 ether, 1);
    }

    function test_weightChangeCheckpointsPreviouslyEarnedRewards() public {
        _notify(stakingRewards, rewardA, 100 ether);
        _setEpoch(5, false);
        _unstake(operator, 1, 40 ether, controller.vaultForStakingRewards(address(stakingRewards)));
        assertEq(stakingRewards.balanceOf(1), stakingRewards.balanceOf(2));
        assertApproxEqAbs(stakingRewards.earned(address(rewardA), 1), 70 ether, 1);

        _notify(stakingRewards, rewardA, 100 ether);
        _setEpoch(10, false);
        assertApproxEqAbs(stakingRewards.earned(address(rewardA), 1), 120 ether, 1);
        assertApproxEqAbs(stakingRewards.earned(address(rewardA), 2), 80 ether, 1);
    }

    function _createExistingRewards() private returns (StakingRewards created) {
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
        (, address stakingRewardsAddress) = controller.admitValidatorRequest(requestId, bytes32(requestId));
        created = StakingRewards(stakingRewardsAddress);
    }

    function _lockAndStake(address voter, uint256 amount, StakingRewards target) private returns (uint256 tokenId) {
        vm.prank(voter);
        tokenId = veMON.createLock{value: amount}(amount, lockDuration);
        address[] memory vaults = new address[](1);
        vaults[0] = controller.vaultForStakingRewards(address(target));
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        vm.prank(voter);
        controller.stake(tokenId, vaults, amounts);
    }

    function _unstake(address voter, uint256 tokenId, uint256 amount, address vault) private {
        address[] memory vaults = new address[](1);
        vaults[0] = vault;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        vm.prank(voter);
        controller.unstake(tokenId, vaults, amounts);
    }

    function _notify(StakingRewards target, ERC20Mock token, uint256 amount) private {
        vm.prank(stranger);
        target.notifyRewardAmount(address(token), amount);
    }

    function _oneToken(address token) private pure returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = token;
    }

    function _rewardTokens() private view returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = address(rewardA);
        tokens[1] = address(rewardB);
    }
}
