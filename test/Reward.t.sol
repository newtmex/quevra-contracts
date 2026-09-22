// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IReward} from "../src/interfaces/IReward.sol";
import {RewardFixture} from "./fixtures/RewardFixture.sol";

contract RewardTest is RewardFixture {
    function test_constructorUsesRealVoterAndEscrowRelationships() public view {
        assertEq(reward.voter(), address(rewardVoter));
        assertEq(reward.ve(), address(veMON));
        assertEq(reward.authorized(), address(rewardVoter));
        assertTrue(reward.isTrustedForwarder(forwarder));
        assertEq(reward.duration(), 5);
        assertEq(reward.totalSupply(), 0);
        assertEq(reward.rewardsListLength(), 0);
        assertFalse(reward.isReward(address(rewardToken)));
        assertEq(address(rewardVoter.gaugeToBribe(rewardVoter.validatorToGauge(1))), address(reward));
    }

    function test_voteUpdatesRealBribeBalancesAndCheckpoints() public {
        _setEpoch(6, false);
        uint256 tokenId = _vote(100 ether);

        assertEq(reward.balanceOf(tokenId), 100 ether);
        assertEq(reward.totalSupply(), 100 ether);
        assertEq(reward.numCheckpoints(tokenId), 1);
        (uint64 epoch, uint256 balance) = reward.checkpoints(tokenId, 0);
        assertEq(epoch, 6);
        assertEq(balance, 100 ether);

        assertEq(reward.balanceOf(tokenId), 100 ether);
        assertEq(reward.totalSupply(), 100 ether);
    }

    function test_onlyRealVoterCanMutateBribeBalances() public {
        vm.expectRevert(IReward.NotAuthorized.selector);
        reward._deposit(100 ether, 1);
        vm.expectRevert(IReward.NotAuthorized.selector);
        reward._withdraw(0, 1);
        assertEq(reward.totalSupply(), 0);
        assertEq(reward.supplyNumCheckpoints(), 0);
    }

    function test_checkpointsAppendAfterRealCycleRollover() public {
        _setEpoch(6, false);
        uint256 tokenId = _vote(100 ether);
        _setEpoch(11, false);
        // A new real veMON position and vote creates the next cycle checkpoint.
        uint256 nextTokenId = _vote(50 ether);

        assertEq(reward.numCheckpoints(tokenId), 1);
        assertEq(reward.numCheckpoints(nextTokenId), 1);
        assertEq(reward.supplyNumCheckpoints(), 2);
        (uint64 epoch, uint256 supply) = reward.supplyCheckpoints(0);
        assertEq(epoch, 6);
        assertEq(supply, 100 ether);
        (epoch, supply) = reward.supplyCheckpoints(1);
        assertEq(epoch, 11);
        assertEq(supply, 150 ether);
    }

    function test_notifyAccumulatesWhitelistedRewardsPerCycle() public {
        _whitelistRewardTokens();
        _setEpoch(11, false);
        vm.expectEmit(true, true, true, true, address(reward));
        emit IReward.NotifyReward(address(this), address(rewardToken), 10, 100);
        _notify(address(rewardToken), 100);
        _setEpoch(14, true);
        _notify(address(rewardToken), 200);
        _notify(address(otherToken), 40);
        _setEpoch(16, false);
        _notify(address(rewardToken), 50);

        assertEq(reward.tokenRewardsPerCycle(address(rewardToken), 10), 300);
        assertEq(reward.tokenRewardsPerCycle(address(rewardToken), 15), 50);
        assertEq(reward.tokenRewardsPerCycle(address(otherToken), 10), 40);
        assertEq(rewardToken.balanceOf(address(reward)), 350);
        assertEq(otherToken.balanceOf(address(reward)), 40);
    }

    function test_notifyRequiresWhitelistingAndSuccessfulTransfer() public {
        vm.expectRevert(IReward.NotWhitelisted.selector);
        _notify(address(rewardToken), 100);

        _whitelistRewardTokens();
        rewardToken.approve(address(reward), 0);
        vm.expectRevert();
        _notify(address(rewardToken), 100);
        assertEq(reward.tokenRewardsPerCycle(address(rewardToken), 0), 0);
        assertEq(rewardToken.balanceOf(address(reward)), 0);
    }

    function test_earnedUsesRealVoteWeightAndExcludesCurrentCycle() public {
        _whitelistRewardTokens();
        _setEpoch(6, false);
        uint256 tokenId = _vote(100 ether);
        _notify(address(rewardToken), 300);
        assertEq(reward.earned(address(rewardToken), tokenId), 0);

        _setEpoch(11, false);
        assertEq(reward.earned(address(rewardToken), tokenId), 300);
        assertEq(reward.earned(address(rewardToken), 999), 0);
    }

    function test_claimTransfersRewardsToTheRealVeMONOwnerOnlyOnce() public {
        _whitelistRewardTokens();
        _setEpoch(6, false);
        uint256 tokenId = _vote(100 ether);
        _notify(address(rewardToken), 300);
        _notify(address(otherToken), 200);
        _setEpoch(11, false);

        address[] memory tokens = new address[](3);
        tokens[0] = address(rewardToken);
        tokens[1] = address(otherToken);
        tokens[2] = address(rewardToken);
        vm.expectEmit(true, true, false, true, address(reward));
        emit IReward.ClaimRewards(operator, address(rewardToken), 300);
        vm.prank(operator);
        reward.getReward(tokenId, tokens);
        assertEq(rewardToken.balanceOf(operator), 300);
        assertEq(otherToken.balanceOf(operator), 200);
        assertEq(reward.lastEarn(address(rewardToken), tokenId), 11);
        assertEq(reward.lastEarn(address(otherToken), tokenId), 11);

        vm.prank(operator);
        reward.getReward(tokenId, tokens);
        assertEq(rewardToken.balanceOf(operator), 300);
        assertEq(otherToken.balanceOf(operator), 200);
    }

    function test_realVoteRewardsStayProportionalToPermanentVotingPower() public {
        _whitelistRewardTokens();
        _setEpoch(6, false);
        uint256 firstId = _vote(100 ether);
        uint256 secondId = _vote(300 ether);
        _notify(address(rewardToken), 1000);
        _setEpoch(11, false);

        assertEq(reward.earned(address(rewardToken), firstId), 250);
        assertEq(reward.earned(address(rewardToken), secondId), 750);
    }
}
