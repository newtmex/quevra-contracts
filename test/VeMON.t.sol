// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IVeMON} from "../src/interfaces/IVeMON.sol";
import {MonVault} from "../src/vault/MonVault.sol";
import {VeMON} from "../src/ve/VeMON.sol";
import {WMON} from "./mocks/WMON.sol";

contract VeMONTest is Test {
    uint256 internal constant MAX_LOCK = 28 days;

    WMON internal wmon;
    MonVault internal vault;
    VeMON internal ve;

    address internal owner = makeAddr("owner");
    address internal locker = makeAddr("locker");
    address internal other = makeAddr("other");

    function setUp() public {
        wmon = new WMON();

        uint256 nonce = vm.getNonce(address(this));
        address predictedVault = vm.computeCreateAddress(address(this), nonce);
        address predictedVe = vm.computeCreateAddress(address(this), nonce + 1);

        vault = new MonVault(owner, address(wmon), predictedVe, address(this), address(this));
        ve = new VeMON(owner, address(wmon), predictedVault, address(this), MAX_LOCK);

        assertEq(address(vault), predictedVault);
        assertEq(address(ve), predictedVe);
        vm.deal(locker, 1_000_000 ether);
    }

    function test_createLockNativeCustodiesInVault() public {
        vm.prank(locker);
        uint256 tokenId = ve.createLockNative{value: 100 ether}(MAX_LOCK);

        assertEq(tokenId, 1);
        assertEq(ve.ownerOf(tokenId), locker);
        assertEq(ve.supply(), 100 ether);
        assertEq(wmon.balanceOf(address(ve)), 0);
        assertEq(wmon.balanceOf(address(vault)), 0);
        assertEq(address(vault).balance, 100 ether);

        IVeMON.LockedBalance memory lock = ve.locked(tokenId);
        assertEq(lock.amount, 100 ether);
        assertEq(lock.end, block.timestamp + MAX_LOCK);
        assertGt(ve.votingPowerOfNFT(tokenId), 0);
        assertGt(ve.totalVotingPower(), 0);
    }

    function test_createLockPullsWMON() public {
        vm.prank(locker);
        wmon.deposit{value: 40 ether}();
        vm.prank(locker);
        wmon.approve(address(ve), 40 ether);
        vm.prank(locker);
        uint256 tokenId = ve.createLock(40 ether, MAX_LOCK);

        assertEq(ve.ownerOf(tokenId), locker);
        assertEq(wmon.balanceOf(locker), 0);
        assertEq(address(vault).balance, 40 ether);
        assertEq(wmon.balanceOf(address(ve)), 0);
    }

    function test_votingPowerDecaysAndWithdrawPaysNative() public {
        vm.prank(locker);
        uint256 tokenId = ve.createLockNative{value: 50 ether}(MAX_LOCK);
        uint256 vp0 = ve.votingPowerOfNFT(tokenId);

        vm.warp(block.timestamp + 7 days);
        uint256 vp1 = ve.votingPowerOfNFTAt(tokenId, block.timestamp);
        assertLt(vp1, vp0);

        uint256 end = ve.locked(tokenId).end;
        vm.warp(end);
        assertEq(ve.votingPowerOfNFT(tokenId), 0);

        uint256 before = locker.balance;
        vm.prank(locker);
        ve.withdraw(tokenId);
        assertEq(locker.balance, before + 50 ether);
        assertEq(ve.supply(), 0);
        assertEq(address(vault).balance, 0);
    }

    function test_cannotWithdrawBeforeExpiry() public {
        vm.prank(locker);
        uint256 tokenId = ve.createLockNative{value: 10 ether}(MAX_LOCK);
        vm.prank(locker);
        vm.expectRevert(IVeMON.LockNotExpired.selector);
        ve.withdraw(tokenId);
    }

    function test_votedBlocksTransferAndWithdraw() public {
        vm.prank(locker);
        uint256 tokenId = ve.createLockNative{value: 10 ether}(MAX_LOCK);
        ve.voting(tokenId, true);

        vm.prank(locker);
        vm.expectRevert(IVeMON.AlreadyVoted.selector);
        ve.transferFrom(locker, other, tokenId);

        uint256 end = ve.locked(tokenId).end;
        vm.warp(end);
        vm.prank(locker);
        vm.expectRevert(IVeMON.AlreadyVoted.selector);
        ve.withdraw(tokenId);

        ve.voting(tokenId, false);
        vm.prank(locker);
        ve.withdraw(tokenId);
        assertEq(other.balance, 0);
        assertEq(locker.balance, 1_000_000 ether);
    }

    function test_increaseAmountAndUnlockTime() public {
        vm.prank(locker);
        uint256 tokenId = ve.createLockNative{value: 10 ether}(7 days);
        uint256 vp0 = ve.votingPowerOfNFT(tokenId);
        uint256 end0 = ve.locked(tokenId).end;

        vm.prank(locker);
        ve.increaseAmountNative{value: 5 ether}(tokenId);
        assertEq(ve.locked(tokenId).amount, 15 ether);
        assertGt(ve.votingPowerOfNFT(tokenId), vp0);

        vm.prank(locker);
        ve.increaseUnlockTime(tokenId, MAX_LOCK);
        assertGt(ve.locked(tokenId).end, end0);
    }

    function test_depositForFromOther() public {
        vm.prank(locker);
        uint256 tokenId = ve.createLockNative{value: 10 ether}(MAX_LOCK);

        vm.deal(other, 3 ether);
        vm.prank(other);
        wmon.deposit{value: 3 ether}();
        vm.prank(other);
        wmon.approve(address(ve), 3 ether);
        vm.prank(other);
        ve.depositFor(tokenId, 3 ether);

        assertEq(ve.locked(tokenId).amount, 13 ether);
        assertEq(ve.supply(), 13 ether);
    }

    function test_constructorSetsImmutableVoter() public view {
        assertEq(ve.voter(), address(this));
    }

    function test_constructorRevertsOnZeroMaxLock() public {
        vm.expectRevert(IVeMON.MaxLockTooShort.selector);
        new VeMON(owner, address(wmon), address(vault), address(this), 0);
    }
}
