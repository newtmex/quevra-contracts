// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VeMON} from "../src/VeMON.sol";
import {VotingEscrow} from "../src/VotingEscrow.sol";
import {IVotingEscrow} from "../src/interfaces/IVotingEscrow.sol";
import {ProtocolTimeLibrary} from "../src/libraries/ProtocolTimeLibrary.sol";
import {VeMONFixture} from "./fixtures/VeMONFixture.sol";

contract VeMONTest is VeMONFixture {
    function test_maxLockCyclesIsConfiguredAtDeployment() public view {
        assertEq(veMON.maxLockCycles(), 4);
        assertEq(veMON.maxLockEpochs(), 4 * ProtocolTimeLibrary.EPOCHS_PER_CYCLE);
    }

    function test_createLockMintsVeMONAndCustodiesMONInController() public {
        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);

        assertEq(address(controller).balance, validatorStake);
        assertEq(veMON.ownerOf(1), operator);
        assertEq(veMON.balanceOf(operator), 1);

        uint256 expectedEnd = lockDuration * ProtocolTimeLibrary.EPOCHS_PER_CYCLE;
        (int128 amount, uint256 end, bool permanent, uint256 boost) = veMON.locked(1);
        assertEq(int256(amount), int256(validatorStake));
        assertEq(end, expectedEnd);
        assertFalse(permanent);
        assertEq(boost, 0);
    }

    function test_createLockDuringCycleExpiresAfterFullRequestedCycles() public {
        _setEpoch(12, false);

        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);

        // Epoch 12 is inside cycle [10, 15); the lock ends at the fourth
        // future cycle boundary, epoch 30.
        (, uint256 end,,) = veMON.locked(1);
        assertEq(end, 30);
        assertEq(veMON.votingPowerOfAt(1, 12), 90_000 ether);
        assertEq(veMON.votingPowerOfAt(1, 30), 0);
    }

    function test_createLockAtCycleBoundaryUsesRequestedCycleCount() public {
        _setEpoch(15, false);

        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);

        (, uint256 end,,) = veMON.locked(1);
        assertEq(end, 35);
    }

    function test_controllerCreditsCompoundedRewardsToLockedAmount() public {
        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);

        _setEpoch(5, false);
        (int128 amountBefore,,,) = veMON.locked(1);
        assertEq(int256(amountBefore), int256(validatorStake));

        uint256 compoundedRewards = 20 ether;
        vm.prank(address(controller));
        veMON.increaseAmountFromController(1, compoundedRewards);

        (int128 amountAfter,,,) = veMON.locked(1);
        assertEq(int256(amountAfter), int256(validatorStake + compoundedRewards));
        assertEq(veMON.votingPowerOfAt(1, 4), 80_000 ether);
    }

    function test_onlyControllerCanCreditCompoundedRewards() public {
        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);

        vm.prank(stranger);
        vm.expectRevert(VeMON.NotController.selector);
        veMON.increaseAmountFromController(1, 1 ether);
    }

    function test_createLockRejectsZeroOrMismatchedValue() public {
        vm.expectRevert(VotingEscrow.InvalidAmount.selector);
        veMON.createLock(0, lockDuration);

        vm.expectRevert(VeMON.InvalidValue.selector);
        veMON.createLock{value: 1 ether}(2 ether, lockDuration);
    }

    function test_createLockRejectsInvalidLockDurations() public {
        vm.expectRevert(IVotingEscrow.LockDurationNotInFuture.selector);
        veMON.createLock{value: 1 ether}(1 ether, 0);

        uint256 maxLockCycles = veMON.maxLockCycles();
        vm.expectRevert(IVotingEscrow.LockDurationTooLong.selector);
        veMON.createLock{value: 1 ether}(1 ether, maxLockCycles + 1);
    }

    function test_votingPowerDecaysLinearlyAndExpiresAtUnlockEpoch() public {
        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);

        assertEq(veMON.votingPowerOf(1), validatorStake);
        assertEq(veMON.votingPowerOfAt(1, 10), 50_000 ether);
        assertEq(veMON.votingPowerOfAt(1, 20), 0);
        assertEq(veMON.totalVotingPower(), validatorStake);

        _setEpoch(10, false);
        veMON.checkpoint();
        assertEq(veMON.votingPowerOf(1), 50_000 ether);
        assertEq(veMON.totalVotingPower(), 50_000 ether);
    }

    function test_votingPowerCheckpointsPreserveHistoricalTotalVotingPower() public {
        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);
        assertEq(veMON.permanentLockBalance(), 0);
        _setEpoch(5, false);
        veMON.checkpoint();

        vm.prank(stranger);
        veMON.createLock{value: 20 ether}(20 ether, lockDuration);

        assertEq(veMON.totalVotingPowerAt(4), 80_000 ether);
        assertEq(veMON.totalVotingPowerAt(5), 75_020 ether);
        assertEq(veMON.votingPowerOfAt(1, 5), 75_000 ether);
        assertEq(veMON.votingPowerOfAt(2, 5), 20 ether);
        assertEq(veMON.userPointEpoch(1), 1);
        assertEq(veMON.userPointEpoch(2), 1);
    }

    function test_transferKeepsPositionPowerAndAppliesSameBlockProtection() public {
        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);

        vm.prank(operator);
        veMON.transferFrom(operator, stranger, 1);
        assertEq(veMON.votingPowerOf(1), 0);

        // ERC721 transfer protection is explicitly block-scoped, so this EVM block
        // advance isolates the subsequent read from same-block protection.
        vm.roll(block.number + 1);
        assertEq(veMON.votingPowerOf(1), validatorStake);
        assertEq(veMON.votingPowerOfAt(1, 0), validatorStake);
    }

    function test_permanentLockIsConstantAndCanReturnToCycleLockedPosition() public {
        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);
        _setEpoch(5, false);

        vm.prank(operator);
        veMON.lockPermanent(1);
        (int128 amount, uint256 end, bool permanent,) = veMON.locked(1);
        assertEq(int256(amount), int256(validatorStake));
        assertEq(end, 0);
        assertTrue(permanent);
        assertEq(veMON.permanentLockBalance(), validatorStake);
        assertEq(veMON.votingPowerOf(1), validatorStake);
        assertEq(veMON.votingPowerOfAt(1, 20), validatorStake);
        assertEq(veMON.totalVotingPowerAt(30), validatorStake);
        assertEq(veMON.totalVotingPower(), validatorStake);

        vm.prank(operator);
        veMON.unlockPermanent(1);
        (, end, permanent,) = veMON.locked(1);
        assertEq(end, 25);
        assertFalse(permanent);
        assertEq(veMON.permanentLockBalance(), 0);
        assertEq(veMON.votingPowerOfAt(1, 5), validatorStake);
        assertEq(veMON.votingPowerOfAt(1, 25), 0);
    }

    function test_invalidPermanentTransitionsRevert() public {
        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);

        vm.prank(stranger);
        vm.expectRevert(IVotingEscrow.NotApprovedOrOwner.selector);
        veMON.lockPermanent(1);
    }

    function test_withdrawRejectsUnexpiredLockBeforeCallingController() public {
        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);

        vm.prank(operator);
        vm.expectRevert(IVotingEscrow.LockNotExpired.selector);
        veMON.withdraw(1);

        assertEq(veMON.ownerOf(1), operator);
    }

    function test_withdrawRejectsPermanentLock() public {
        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);
        vm.prank(operator);
        veMON.lockPermanent(1);

        vm.prank(operator);
        vm.expectRevert(IVotingEscrow.PermanentLock.selector);
        veMON.withdraw(1);

        assertEq(veMON.ownerOf(1), operator);
    }
}
