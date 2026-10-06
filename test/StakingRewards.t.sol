// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StakingRewards} from "../src/rewards/StakingRewards.sol";
import {IBaseVoter} from "../src/interfaces/IBaseVoter.sol";
import {IReward} from "../src/interfaces/IReward.sol";
import {StakingRewardsFixture} from "./fixtures/StakingRewardsFixture.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract RewardVoterMock is IBaseVoter {
    address public immutable override ve;
    mapping(address token => bool) public override isWhitelistedToken;

    constructor(address ve_) {
        ve = ve_;
    }

    function setWhitelisted(address token, bool whitelisted) external {
        isWhitelistedToken[token] = whitelisted;
    }
}

contract StakingRewardsTest is StakingRewardsFixture {
    StakingRewards private stakingRewards;
    RewardVoterMock private rewardVoter;
    ERC20Mock private rewardA;
    ERC20Mock private rewardB;
    ERC20Mock private unlisted;

    function setUp() public override {
        super.setUp();
        rewardVoter = new RewardVoterMock(address(veMON));
        stakingRewards = new StakingRewards(address(rewardVoter), 1, operator);
        rewardA = new ERC20Mock();
        rewardB = new ERC20Mock();
        unlisted = new ERC20Mock();
        rewardVoter.setWhitelisted(address(rewardA), true);
        rewardVoter.setWhitelisted(address(rewardB), true);
        rewardA.mint(stranger, 1_000 ether);
        rewardB.mint(stranger, 1_000 ether);
        vm.startPrank(stranger);
        rewardA.approve(address(stakingRewards), type(uint256).max);
        rewardB.approve(address(stakingRewards), type(uint256).max);
        vm.stopPrank();
        _lockAndDeposit(operator, 70 ether);
        _lockAndDeposit(executor, 30 ether);
    }

    function test_constructorDoesNotRegisterEscrowToken() public view {
        assertEq(stakingRewards.rewardsListLength(), 0);
    }

    function test_whitelistedRewardTokenCanBeAdded() public {
        _notify(rewardA, 100 ether);
        assertTrue(stakingRewards.isReward(address(rewardA)));
        assertEq(stakingRewards.rewardsListLength(), 1);
        assertEq(stakingRewards.tokenRewardsPerCycle(address(rewardA), 0), 100 ether);
        assertEq(rewardA.balanceOf(address(stakingRewards)), 100 ether);
    }

    function test_nonWhitelistedTokenIsRejected() public {
        vm.expectRevert(IReward.NotWhitelisted.selector);
        stakingRewards.notifyRewardAmount(address(unlisted), 100 ether);

        rewardVoter.setWhitelisted(address(rewardA), false);
        vm.expectRevert(IReward.NotWhitelisted.selector);
        _notify(rewardA, 100 ether);
    }

    function test_twoTokenIdsReceiveCycleRewardsInSeventyThirtyRatio() public {
        _notify(rewardA, 100 ether);
        _setEpoch(5, false);
        assertApproxEqAbs(stakingRewards.earned(address(rewardA), 1), 70 ether, 1);
        assertApproxEqAbs(stakingRewards.earned(address(rewardA), 2), 30 ether, 1);

        vm.prank(operator);
        stakingRewards.getReward(1, _oneToken(address(rewardA)));
        vm.prank(executor);
        stakingRewards.getReward(2, _oneToken(address(rewardA)));
        assertApproxEqAbs(rewardA.balanceOf(operator), 70 ether, 1);
        assertApproxEqAbs(rewardA.balanceOf(executor), 30 ether, 1);
    }

    function test_multipleRewardTokensAccountIndependentlyByCycle() public {
        _notify(rewardA, 100 ether);
        _notify(rewardB, 200 ether);
        _setEpoch(5, false);
        assertApproxEqAbs(stakingRewards.earned(address(rewardA), 1), 70 ether, 1);
        assertApproxEqAbs(stakingRewards.earned(address(rewardB), 1), 140 ether, 1);
        assertApproxEqAbs(stakingRewards.earned(address(rewardA), 2), 30 ether, 1);
        assertApproxEqAbs(stakingRewards.earned(address(rewardB), 2), 60 ether, 1);
    }

    function test_weightChangeCheckpointsPreviouslyEarnedRewards() public {
        _notify(rewardA, 100 ether);
        _setEpoch(5, false);
        vm.prank(address(rewardVoter));
        stakingRewards._withdraw(40 ether, 1);
        assertEq(stakingRewards.balanceOf(1), stakingRewards.balanceOf(2));
        assertApproxEqAbs(stakingRewards.earned(address(rewardA), 1), 70 ether, 1);

        _notify(rewardA, 100 ether);
        _setEpoch(10, false);
        assertApproxEqAbs(stakingRewards.earned(address(rewardA), 1), 120 ether, 1);
        assertApproxEqAbs(stakingRewards.earned(address(rewardA), 2), 80 ether, 1);
    }

    function _lockAndDeposit(address account, uint256 amount) private {
        vm.prank(account);
        uint256 tokenId = veMON.createLock{value: amount}(amount, lockDuration);
        vm.prank(address(rewardVoter));
        stakingRewards._deposit(amount, tokenId);
    }

    function _notify(ERC20Mock token, uint256 amount) private {
        vm.prank(stranger);
        stakingRewards.notifyRewardAmount(address(token), amount);
    }

    function _oneToken(address token) private pure returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = token;
    }
}
