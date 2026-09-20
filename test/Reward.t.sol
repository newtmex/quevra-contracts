// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {stdError} from "forge-std/StdError.sol";
import {IReward} from "../src/interfaces/IReward.sol";
import {RewardFixture} from "./fixtures/RewardFixture.sol";

contract RewardTest is RewardFixture {
    function test_constructorAndInitialState() public view {
        assertEq(reward.voter(), address(rewardVoter));
        assertEq(reward.ve(), escrow);
        assertEq(reward.authorized(), address(this));
        assertTrue(reward.isTrustedForwarder(forwarder));
        assertEq(reward.duration(), 5);
        assertEq(reward.totalSupply(), 0);
        assertEq(reward.rewardsListLength(), 0);
        assertFalse(reward.isReward(address(rewardToken)));
    }

    function test_depositAndWithdrawUpdateBalancesAndEmitEvents() public {
        _setEpoch(11, false);
        vm.expectEmit(true, true, false, true, address(reward));
        emit IReward.Deposit(address(this), 1, 100);
        reward._deposit(100, 1);
        reward._deposit(50, 2);
        vm.expectEmit(true, true, false, true, address(reward));
        emit IReward.Withdraw(address(this), 1, 40);
        reward._withdraw(40, 1);
        assertEq(reward.balanceOf(1), 60);
        assertEq(reward.balanceOf(2), 50);
        assertEq(reward.totalSupply(), 110);
        (uint64 epoch, uint256 balance) = reward.checkpoints(1, 0);
        assertEq(epoch, 11);
        assertEq(balance, 60);
        (epoch, balance) = reward.supplyCheckpoints(0);
        assertEq(epoch, 11);
        assertEq(balance, 110);
    }

    function test_unauthorizedMutationsRevert() public {
        vm.startPrank(stranger);
        vm.expectRevert(IReward.NotAuthorized.selector);
        reward._deposit(100, 1);
        vm.expectRevert(IReward.NotAuthorized.selector);
        reward._withdraw(0, 1);
        vm.stopPrank();
        assertEq(reward.totalSupply(), 0);
        assertEq(reward.supplyNumCheckpoints(), 0);
    }

    function test_trustedForwarderUsesOriginalSender() public {
        vm.prank(forwarder);
        (bool ok,) = address(reward).call(abi.encodePacked(abi.encodeCall(reward._deposit, (100, 1)), address(this)));
        assertTrue(ok);
        assertEq(reward.balanceOf(1), 100);
        vm.prank(stranger);
        (ok,) = address(reward).call(abi.encodePacked(abi.encodeCall(reward._deposit, (100, 1)), address(this)));
        assertFalse(ok);
        assertEq(reward.balanceOf(1), 100);
    }

    function test_overWithdrawalRevertsAtomically() public {
        reward._deposit(100, 1);
        reward._deposit(200, 2);
        vm.expectRevert(stdError.arithmeticError);
        reward._withdraw(101, 1);
        assertEq(reward.totalSupply(), 300);
        assertEq(reward.balanceOf(1), 100);
        vm.expectRevert(stdError.arithmeticError);
        reward._withdraw(301, 1);
        assertEq(reward.totalSupply(), 300);
    }

    function test_checkpointsCoalesceWithinCycleAndAppendOnRollover() public {
        _setEpoch(10, false);
        reward._deposit(100, 1);
        _setEpoch(14, true);
        reward._withdraw(25, 1);
        assertEq(reward.numCheckpoints(1), 1);
        assertEq(reward.supplyNumCheckpoints(), 1);
        (uint64 epoch, uint256 balance) = reward.checkpoints(1, 0);
        assertEq(epoch, 14);
        assertEq(balance, 75);
        _setEpoch(15, false);
        reward._deposit(50, 1);
        assertEq(reward.numCheckpoints(1), 2);
        assertEq(reward.supplyNumCheckpoints(), 2);
        (epoch, balance) = reward.checkpoints(1, 1);
        assertEq(epoch, 15);
        assertEq(balance, 125);
        (epoch, balance) = reward.supplyCheckpoints(0);
        assertEq(epoch, 14);
        assertEq(balance, 75);
    }

    function testFuzz_priorIndicesMatchLatestCheckpointAtOrBeforeEpoch(uint64 query) public {
        assertEq(reward.getPriorBalanceIndex(1, query), 0);
        assertEq(reward.getPriorSupplyIndex(query), 0);
        for (uint64 epoch = 5; epoch <= 25; epoch += 5) {
            _setEpoch(epoch, false);
            reward._deposit(10, 1);
        }
        query = uint64(bound(query, 0, 35));
        uint256 expected = query < 5 ? 0 : query >= 25 ? 4 : query / 5 - 1;
        assertEq(reward.getPriorBalanceIndex(1, query), expected);
        assertEq(reward.getPriorSupplyIndex(query), expected);
        assertEq(reward.getPriorBalanceIndex(999, query), 0);
    }

    function test_notifyAccumulatesPerTokenAndCycleAndTransfersFunds() public {
        _setEpoch(11, false);
        vm.expectEmit(true, true, true, true, address(reward));
        emit IReward.NotifyReward(address(this), address(rewardToken), 10, 100);
        reward.notifyRewardAmount(address(rewardToken), 100);
        _setEpoch(14, true);
        reward.notifyRewardAmount(address(rewardToken), 200);
        reward.notifyRewardAmount(address(otherToken), 40);
        _setEpoch(15, false);
        reward.notifyRewardAmount(address(rewardToken), 50);
        assertEq(reward.tokenRewardsPerCycle(address(rewardToken), 10), 300);
        assertEq(reward.tokenRewardsPerCycle(address(rewardToken), 15), 50);
        assertEq(reward.tokenRewardsPerCycle(address(otherToken), 10), 40);
        assertEq(rewardToken.balanceOf(address(reward)), 350);
        assertEq(otherToken.balanceOf(address(reward)), 40);
    }

    function test_notifyZeroAndFailedTransferLeaveAccountingUnchanged() public {
        vm.expectRevert(IReward.ZeroAmount.selector);
        reward.notifyRewardAmount(address(rewardToken), 0);
        rewardToken.approve(address(reward), 0);
        vm.expectRevert();
        reward.notifyRewardAmount(address(rewardToken), 100);
        assertEq(reward.tokenRewardsPerCycle(address(rewardToken), 0), 0);
        assertEq(rewardToken.balanceOf(address(reward)), 0);
    }

    function test_earnedExcludesCurrentCycleAndAccountsForNonzeroCycle() public {
        _setEpoch(10, false);
        reward._deposit(100, 1);
        reward.notifyRewardAmount(address(rewardToken), 300);
        _setEpoch(14, true);
        assertEq(reward.earned(address(rewardToken), 1), 0);
        _setEpoch(15, false);
        assertEq(reward.earned(address(rewardToken), 1), 300);
        assertEq(reward.earned(address(rewardToken), 999), 0);
    }

    function test_earnedUsesFinalBalancesAndSupplyAcrossSkippedCycles() public {
        reward._deposit(100, 1);
        reward._deposit(100, 2);
        reward.notifyRewardAmount(address(rewardToken), 300);
        _setEpoch(4, true);
        reward._withdraw(50, 1);
        _setEpoch(10, false);
        reward.notifyRewardAmount(address(rewardToken), 600);
        _setEpoch(15, false);
        assertEq(reward.earned(address(rewardToken), 1), 300);
        assertEq(reward.earned(address(rewardToken), 2), 600);
    }

    function test_fullWithdrawalAndZeroSupplyEarnNothing() public {
        reward._deposit(100, 1);
        reward.notifyRewardAmount(address(rewardToken), 300);
        _setEpoch(4, false);
        reward._withdraw(100, 1);
        _setEpoch(5, false);
        assertEq(reward.totalSupply(), 0);
        assertEq(reward.earned(address(rewardToken), 1), 0);
    }

    function test_lateDepositorCannotEarnEarlierCycleRewards() public {
        reward._deposit(100, 1);
        reward.notifyRewardAmount(address(rewardToken), 300);
        _setEpoch(5, false);
        reward._deposit(100, 2);
        _setEpoch(10, false);
        assertEq(reward.earned(address(rewardToken), 2), 0);
        assertEq(reward.earned(address(rewardToken), 1), 300);
    }

    function test_claimTransfersMultipleTokensAndCannotDoubleClaim() public {
        reward._deposit(100, 1);
        reward.notifyRewardAmount(address(rewardToken), 300);
        reward.notifyRewardAmount(address(otherToken), 200);
        _setEpoch(5, false);
        address[] memory tokens = new address[](3);
        tokens[0] = address(rewardToken);
        tokens[1] = address(otherToken);
        tokens[2] = address(rewardToken);
        vm.expectEmit(true, true, false, true, address(reward));
        emit IReward.ClaimRewards(owner, address(rewardToken), 300);
        vm.prank(owner);
        reward.getReward(1, tokens);
        assertEq(rewardToken.balanceOf(owner), 300);
        assertEq(otherToken.balanceOf(owner), 200);
        assertEq(reward.lastEarn(address(rewardToken), 1), 5);
        assertEq(reward.lastEarn(address(otherToken), 1), 5);
        vm.prank(owner);
        reward.getReward(1, tokens);
        assertEq(rewardToken.balanceOf(owner), 300);
        assertEq(otherToken.balanceOf(owner), 200);
    }

    function test_claimDuringCyclePreservesRewardsWhenCycleCompletes() public {
        _setEpoch(10, false);
        reward._deposit(100, 1);
        reward.notifyRewardAmount(address(rewardToken), 300);
        _setEpoch(12, true);
        vm.prank(owner);
        reward.getReward(1, _rewardTokens());
        assertEq(rewardToken.balanceOf(owner), 0);
        assertEq(reward.lastEarn(address(rewardToken), 1), 12);
        _setEpoch(15, false);
        vm.prank(owner);
        reward.getReward(1, _rewardTokens());
        assertEq(rewardToken.balanceOf(owner), 300);
        assertEq(reward.earned(address(rewardToken), 1), 0);
    }

    function testFuzz_rewardsAreProportionalAndNeverExceedFunding(uint96 a, uint96 b, uint96 funding) public {
        a = uint96(bound(a, 1, type(uint96).max));
        b = uint96(bound(b, 1, type(uint96).max));
        funding = uint96(bound(funding, 1, 1_000_000 ether));
        reward._deposit(a, 1);
        reward._deposit(b, 2);
        reward.notifyRewardAmount(address(rewardToken), funding);
        _setEpoch(5, false);
        uint256 first = reward.earned(address(rewardToken), 1);
        uint256 second = reward.earned(address(rewardToken), 2);
        assertEq(first, uint256(funding) * a / (uint256(a) + b));
        assertEq(second, uint256(funding) * b / (uint256(a) + b));
        assertLe(first + second, funding);
        assertLe(uint256(funding) - first - second, 1);
    }
}
