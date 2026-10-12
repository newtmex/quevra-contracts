// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import {BribeVotingRewards} from "../../src/rewards/BribeVotingRewards.sol";
import {IReward} from "../../src/interfaces/IReward.sol";
import {ProtocolTimeLibrary} from "../../src/libraries/ProtocolTimeLibrary.sol";
import {QuevraProtocolFixture} from "../fixtures/QuevraProtocolFixture.sol";

/// @notice End-to-end bribe path: stake-linked gauge weight → fund in cycle `c`
///         → claim from `c+1`, including later vote changes, auth, and exit.
contract BribeIncentiveFlowIntegrationTest is QuevraProtocolFixture {
    ERC20Mock private incentive;
    address private vault;
    address private gauge;
    BribeVotingRewards private bribe;
    uint256 private validatorTokenId;
    uint256 private aliceTokenId;
    uint256 private bobTokenId;

    uint256 private constant ALICE_STAKE = 70_000 ether;
    uint256 private constant BOB_STAKE = 30_000 ether;
    uint256 private constant CYCLE_C_REWARD = 100 ether;
    uint256 private constant CYCLE_C1_REWARD = 50 ether;

    function setUp() public override {
        super.setUp();

        incentive = new ERC20Mock();
        validatorsVoter.whitelistToken(address(incentive), true);
        incentive.mint(sponsor, 1_000 ether);

        validatorTokenId = _createValidator(keccak256("bribe-flow-validator"));
        (,, vault, gauge,) = veValidator.validatorPosition(validatorTokenId);
        bribe = BribeVotingRewards(validatorsVoter.gaugeToBribe(gauge));
        assertTrue(address(bribe) != address(0));

        vm.prank(sponsor);
        incentive.approve(address(bribe), type(uint256).max);

        vm.prank(operator);
        aliceTokenId = veMON.createLock{value: ALICE_STAKE}(ALICE_STAKE, lockDuration);
        vm.prank(stranger);
        bobTokenId = veMON.createLock{value: BOB_STAKE}(BOB_STAKE, lockDuration);

        // Stake-linked votes write bribe balances through ValidatorsVoter.
        vm.prank(operator);
        controller.stake(aliceTokenId, _one(vault), _oneAmount(ALICE_STAKE));
        vm.prank(stranger);
        controller.stake(bobTokenId, _one(vault), _oneAmount(BOB_STAKE));
    }

    function test_fundInCycleCClaimableFromCycleCPlusOneWithProportionalPayout() public {
        uint256 aliceWeight = validatorsVoter.votes(aliceTokenId, gauge);
        uint256 bobWeight = validatorsVoter.votes(bobTokenId, gauge);
        assertGt(aliceWeight, 0);
        assertGt(bobWeight, 0);
        assertEq(bribe.balanceOf(aliceTokenId), aliceWeight);
        assertEq(bribe.balanceOf(bobTokenId), bobWeight);
        assertEq(bribe.totalSupply(), aliceWeight + bobWeight);

        // Fund cycle `c` (epoch 0 → cycle start 0) with a real ERC-20 transfer.
        uint256 bribeBalanceBefore = incentive.balanceOf(address(bribe));
        vm.prank(sponsor);
        bribe.notifyRewardAmount(address(incentive), CYCLE_C_REWARD);
        assertEq(incentive.balanceOf(address(bribe)), bribeBalanceBefore + CYCLE_C_REWARD);
        assertEq(bribe.tokenRewardsPerCycle(address(incentive), 0), CYCLE_C_REWARD);
        assertTrue(bribe.isReward(address(incentive)));

        // Still in cycle `c`: nothing claimable yet.
        _setEpoch(4, false);
        assertEq(ProtocolTimeLibrary.currentCycle(), 0);
        assertEq(bribe.earned(address(incentive), aliceTokenId), 0);
        assertEq(bribe.earned(address(incentive), bobTokenId), 0);

        // Exact boundary: first epoch of cycle `c+1` unlocks cycle-`c` rewards.
        _setEpoch(5, false);
        assertEq(ProtocolTimeLibrary.currentCycle(), 1);
        uint256 aliceEarned = bribe.earned(address(incentive), aliceTokenId);
        uint256 bobEarned = bribe.earned(address(incentive), bobTokenId);
        uint256 expectedAlice = (aliceWeight * CYCLE_C_REWARD) / (aliceWeight + bobWeight);
        uint256 expectedBob = (bobWeight * CYCLE_C_REWARD) / (aliceWeight + bobWeight);
        assertApproxEqAbs(aliceEarned, expectedAlice, 1);
        assertApproxEqAbs(bobEarned, expectedBob, 1);
        assertApproxEqAbs(aliceEarned + bobEarned, CYCLE_C_REWARD, 1);

        uint256 aliceBefore = incentive.balanceOf(operator);
        uint256 bobBefore = incentive.balanceOf(stranger);
        vm.prank(operator);
        bribe.getReward(aliceTokenId, _oneToken(address(incentive)));
        vm.prank(stranger);
        bribe.getReward(bobTokenId, _oneToken(address(incentive)));

        assertApproxEqAbs(incentive.balanceOf(operator) - aliceBefore, expectedAlice, 1);
        assertApproxEqAbs(incentive.balanceOf(stranger) - bobBefore, expectedBob, 1);
        assertEq(bribe.earned(address(incentive), aliceTokenId), 0);
        assertEq(bribe.earned(address(incentive), bobTokenId), 0);
    }

    function test_laterVoteChangeDoesNotRewriteCompletedCycleEntitlement() public {
        uint256 aliceWeightC = validatorsVoter.votes(aliceTokenId, gauge);
        uint256 bobWeightC = validatorsVoter.votes(bobTokenId, gauge);

        vm.prank(sponsor);
        bribe.notifyRewardAmount(address(incentive), CYCLE_C_REWARD);

        // Move to cycle `c+1` and change Bob's allocation (unstake clears bribe weight).
        _setEpoch(5, false);
        assertEq(ProtocolTimeLibrary.currentCycle(), 1);
        vm.prank(stranger);
        controller.unstake(bobTokenId, _one(vault), _oneAmount(BOB_STAKE));
        assertEq(bribe.balanceOf(bobTokenId), 0);
        assertEq(validatorsVoter.votes(bobTokenId, gauge), 0);
        assertEq(bribe.balanceOf(aliceTokenId), aliceWeightC);

        // Fund cycle `c+1` while only Alice still has weight.
        vm.prank(sponsor);
        bribe.notifyRewardAmount(address(incentive), CYCLE_C1_REWARD);
        assertEq(bribe.tokenRewardsPerCycle(address(incentive), 5), CYCLE_C1_REWARD);

        // Cycle `c+2`: Alice keeps cycle-`c` share plus all of cycle-`c+1`; Bob keeps cycle-`c` only.
        _setEpoch(10, false);
        assertEq(ProtocolTimeLibrary.currentCycle(), 2);

        uint256 expectedAliceC = (aliceWeightC * CYCLE_C_REWARD) / (aliceWeightC + bobWeightC);
        uint256 expectedBobC = (bobWeightC * CYCLE_C_REWARD) / (aliceWeightC + bobWeightC);
        uint256 aliceEarned = bribe.earned(address(incentive), aliceTokenId);
        uint256 bobEarned = bribe.earned(address(incentive), bobTokenId);

        assertApproxEqAbs(aliceEarned, expectedAliceC + CYCLE_C1_REWARD, 1);
        assertApproxEqAbs(bobEarned, expectedBobC, 1);

        uint256 aliceBefore = incentive.balanceOf(operator);
        uint256 bobBefore = incentive.balanceOf(stranger);
        vm.prank(operator);
        bribe.getReward(aliceTokenId, _oneToken(address(incentive)));
        vm.prank(stranger);
        bribe.getReward(bobTokenId, _oneToken(address(incentive)));

        assertApproxEqAbs(incentive.balanceOf(operator) - aliceBefore, expectedAliceC + CYCLE_C1_REWARD, 1);
        assertApproxEqAbs(incentive.balanceOf(stranger) - bobBefore, expectedBobC, 1);
    }

    function test_unauthorizedCallerCannotClaimAndOwnerCanClaimAfterApproval() public {
        vm.prank(sponsor);
        bribe.notifyRewardAmount(address(incentive), CYCLE_C_REWARD);
        _setEpoch(5, false);

        vm.expectRevert(IReward.NotAuthorized.selector);
        vm.prank(executor);
        bribe.getReward(aliceTokenId, _oneToken(address(incentive)));

        // Approval lets a third party claim, and payout still goes to the NFT owner.
        vm.prank(operator);
        veMON.approve(executor, aliceTokenId);

        uint256 ownerBefore = incentive.balanceOf(operator);
        uint256 executorBefore = incentive.balanceOf(executor);
        vm.prank(executor);
        bribe.getReward(aliceTokenId, _oneToken(address(incentive)));
        assertGt(incentive.balanceOf(operator), ownerBefore);
        assertEq(incentive.balanceOf(executor), executorBefore);
    }

    function test_claimBeforeExitThenBurnedPositionCannotClaim() public {
        vm.prank(sponsor);
        bribe.notifyRewardAmount(address(incentive), CYCLE_C_REWARD);

        _setEpoch(5, false);
        uint256 aliceWeight = validatorsVoter.votes(aliceTokenId, gauge);
        uint256 bobWeight = validatorsVoter.votes(bobTokenId, gauge);
        uint256 expectedAlice = (aliceWeight * CYCLE_C_REWARD) / (aliceWeight + bobWeight);

        uint256 aliceBefore = incentive.balanceOf(operator);
        vm.prank(operator);
        bribe.getReward(aliceTokenId, _oneToken(address(incentive)));
        assertApproxEqAbs(incentive.balanceOf(operator) - aliceBefore, expectedAlice, 1);

        // Clear stake so the position can exit after lock + withdrawal maturity.
        vm.prank(operator);
        controller.unstake(aliceTokenId, _one(vault), _oneAmount(ALICE_STAKE));
        assertEq(bribe.balanceOf(aliceTokenId), 0);

        (uint64 validatorId,,,,) = veValidator.validatorPosition(validatorTokenId);
        (,, uint64 withdrawEpoch) = staking.getWithdrawalRequest(validatorId, vault, 0);
        _setEpochAfterLockExpiry(aliceTokenId, withdrawEpoch);

        vm.prank(operator);
        veMON.withdraw(aliceTokenId);
        vm.expectRevert();
        veMON.ownerOf(aliceTokenId);

        // A burned NFT has no owner; claims must fail rather than pay a stranger.
        vm.expectRevert();
        vm.prank(operator);
        bribe.getReward(aliceTokenId, _oneToken(address(incentive)));
    }

    function test_zeroAndUnwhitelistedFundingAreRejected() public {
        vm.expectRevert(IReward.ZeroAmount.selector);
        vm.prank(sponsor);
        bribe.notifyRewardAmount(address(incentive), 0);

        ERC20Mock unlisted = new ERC20Mock();
        unlisted.mint(sponsor, 10 ether);
        vm.startPrank(sponsor);
        unlisted.approve(address(bribe), type(uint256).max);
        vm.expectRevert(IReward.NotWhitelisted.selector);
        bribe.notifyRewardAmount(address(unlisted), 10 ether);
        vm.stopPrank();
    }
}
