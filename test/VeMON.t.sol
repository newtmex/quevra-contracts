// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VeMON} from "../src/VeMON.sol";
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
        assertEq(veMON.balanceOfNFTAt(1, 10), validatorStake);
        assertEq(veMON.balanceOfNFTAt(1, 30), 0);
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

        assertEq(veMON.balanceOfNFT(1), validatorStake);
        assertEq(veMON.balanceOfNFTAt(1, 10), validatorStake / 2);
        assertEq(veMON.balanceOfNFTAt(1, 20), 0);
        assertEq(veMON.totalSupply(), validatorStake);

        _setEpoch(10, false);
        veMON.checkpoint();
        assertEq(veMON.balanceOfNFT(1), validatorStake / 2);
        assertEq(veMON.totalSupply(), validatorStake / 2);
    }

    function test_votingPowerCheckpointsPreserveHistoricalSupply() public {
        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);
        _setEpoch(5, false);
        veMON.checkpoint();

        vm.prank(stranger);
        veMON.createLock{value: 20 ether}(20 ether, lockDuration);

        assertEq(veMON.totalSupplyAt(4), validatorStake * 16 / 20);
        assertEq(veMON.totalSupplyAt(5), validatorStake * 15 / 20 + 20 ether);
        assertEq(veMON.balanceOfNFTAt(1, 5), validatorStake * 15 / 20);
        assertEq(veMON.balanceOfNFTAt(2, 5), 20 ether);
        assertEq(veMON.userPointEpoch(1), 1);
        assertEq(veMON.userPointEpoch(2), 1);
    }

    function test_transferKeepsPositionPowerAndAppliesSameBlockProtection() public {
        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);

        vm.prank(operator);
        veMON.transferFrom(operator, stranger, 1);
        assertEq(veMON.balanceOfNFT(1), 0);

        vm.roll(block.number + 1);
        assertEq(veMON.balanceOfNFT(1), validatorStake);
        assertEq(veMON.balanceOfNFTAt(1, 0), validatorStake);
    }
}
