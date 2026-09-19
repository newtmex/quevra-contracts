// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VeMON} from "../src/VeMON.sol";
import {IVotingEscrow} from "../src/interfaces/IVotingEscrow.sol";
import {ProtocolTimeLibrary} from "../src/libraries/ProtocolTimeLibrary.sol";
import {VeMONFixture} from "./fixtures/VeMONFixture.sol";

contract VeMONTest is VeMONFixture {
    function test_createLockMintsVeMONAndCustodiesMONInController() public {
        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);

        assertEq(address(controller).balance, validatorStake);
        assertEq(veMON.ownerOf(1), operator);
        assertEq(veMON.balanceOf(operator), 1);

        uint256 expectedEnd = lockDuration * ProtocolTimeLibrary.EPOCHS_PER_CYCLE;
        (int128 amount, uint256 end, bool permanent, uint256 boost) = veMON.locked(1);
        assertEq(amount, int128(int256(validatorStake)));
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
        assertEq(veMON.votingPowerOfAt(1, 12), validatorStake * 18 / 20);
        assertEq(veMON.votingPowerOfAt(1, 30), 0);
    }

    function test_createLockAtCycleBoundaryUsesRequestedCycleCount() public {
        _setEpoch(15, false);

        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);

        (, uint256 end,,) = veMON.locked(1);
        assertEq(end, 35);
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

    function test_votingPowerDecaysLinearlyAndExpiresAtUnlockEpoch() public {
        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);

        assertEq(veMON.votingPowerOf(1), validatorStake);
        assertEq(veMON.votingPowerOfAt(1, 10), validatorStake / 2);
        assertEq(veMON.votingPowerOfAt(1, 20), 0);
        assertEq(veMON.totalVotingPower(), validatorStake);

        _setEpoch(10, false);
        veMON.checkpoint();
        assertEq(veMON.votingPowerOf(1), validatorStake / 2);
        assertEq(veMON.totalVotingPower(), validatorStake / 2);
    }

    function test_votingPowerCheckpointsPreserveHistoricalTotalVotingPower() public {
        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);
        assertEq(veMON.permanentLockBalance(), 0);
        _setEpoch(5, false);
        veMON.checkpoint();

        vm.prank(stranger);
        veMON.createLock{value: 20 ether}(20 ether, lockDuration);

        assertEq(veMON.totalVotingPowerAt(4), validatorStake * 16 / 20);
        assertEq(veMON.totalVotingPowerAt(5), validatorStake * 15 / 20 + 20 ether);
        assertEq(veMON.votingPowerOfAt(1, 5), validatorStake * 15 / 20);
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
        assertEq(amount, int128(int256(validatorStake)));
        assertEq(end, 0);
        assertTrue(permanent);
        assertTrue(veMON.escrowType(1) == IVotingEscrow.EscrowType.NORMAL);
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

    function test_managedDepositAndWithdrawalPreservePrincipalAndVotingPower() public {
        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);
        _setEpoch(5, false);
        uint256 managedId = veMON.createManagedLock();
        uint256 controllerBalanceBefore = address(controller).balance;

        vm.prank(operator);
        veMON.depositManaged(1, managedId);
        assertTrue(veMON.escrowType(1) == IVotingEscrow.EscrowType.LOCKED);
        assertTrue(veMON.escrowType(managedId) == IVotingEscrow.EscrowType.MANAGED);
        assertEq(veMON.idToManaged(1), managedId);
        assertEq(veMON.weights(1, managedId), validatorStake);
        (int128 userAmount,,,) = veMON.locked(1);
        (int128 managedAmount,, bool managedPermanent,) = veMON.locked(managedId);
        assertEq(userAmount, 0);
        assertEq(managedAmount, int128(int256(validatorStake)));
        assertTrue(managedPermanent);
        assertEq(veMON.votingPowerOf(1), 0);
        assertEq(veMON.votingPowerOf(managedId), validatorStake);
        assertEq(veMON.totalVotingPower(), validatorStake);
        assertEq(address(controller).balance, controllerBalanceBefore);

        vm.prank(operator);
        vm.expectRevert(VeMON.ManagedPositionLocked.selector);
        veMON.transferFrom(operator, stranger, 1);

        _setEpoch(10, false);
        vm.prank(operator);
        veMON.withdrawManaged(1);
        assertTrue(veMON.escrowType(1) == IVotingEscrow.EscrowType.NORMAL);
        assertEq(veMON.idToManaged(1), 0);
        (int128 restoredAmount,,,) = veMON.locked(1);
        (int128 remainder,,,) = veMON.locked(managedId);
        assertEq(restoredAmount, int128(int256(validatorStake)));
        assertEq(remainder, 0);
        assertEq(veMON.votingPowerOf(1), validatorStake);
        assertEq(veMON.votingPowerOf(managedId), 0);
        assertEq(veMON.totalVotingPower(), validatorStake);
        assertEq(veMON.votingPowerOfAt(1, 30), 0);
        assertEq(veMON.totalVotingPowerAt(5), validatorStake);
    }

    function test_managedPositionAggregatesDepositedVotingPowerAndWithdrawRemovesIt() public {
        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);
        vm.prank(stranger);
        veMON.createLock{value: 20 ether}(20 ether, lockDuration);
        uint256 managedId = veMON.createManagedLock();

        vm.prank(operator);
        veMON.depositManaged(1, managedId);

        assertEq(veMON.votingPowerOf(managedId), validatorStake);
        assertEq(veMON.totalVotingPower(), validatorStake + 20 ether);

        vm.prank(operator);
        veMON.withdrawManaged(1);
        assertEq(veMON.votingPowerOf(1), validatorStake);
        assertEq(veMON.votingPowerOf(managedId), 0);
        assertEq(veMON.totalVotingPower(), validatorStake + 20 ether);
    }

    function test_invalidPermanentAndManagedTransitionsRevert() public {
        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);
        uint256 managedId = veMON.createManagedLock();

        vm.prank(stranger);
        vm.expectRevert(VeMON.NotApprovedOrOwner.selector);
        veMON.lockPermanent(1);

        vm.prank(operator);
        vm.expectRevert(VeMON.NotManagedNFT.selector);
        veMON.depositManaged(1, 1);

        vm.prank(operator);
        veMON.depositManaged(1, managedId);
        vm.prank(operator);
        vm.expectRevert(VeMON.NotNormalNFT.selector);
        veMON.lockPermanent(1);

        vm.prank(stranger);
        vm.expectRevert(VeMON.NotApprovedOrOwner.selector);
        veMON.withdrawManaged(1);
    }
}
