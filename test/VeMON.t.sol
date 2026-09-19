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
}
