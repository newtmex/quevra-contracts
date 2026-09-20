// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ValidatorGauge} from "../src/validators/ValidatorGauge.sol";
import {StakingVault} from "../src/staking/StakingVault.sol";
import {ValidatorGaugeFixture} from "./fixtures/ValidatorGaugeFixture.sol";

contract ValidatorGaugeTest is ValidatorGaugeFixture {
    TestToken internal rewardToken;
    TestToken internal otherRewardToken;
    FeeToken internal feeToken;

    event RewardNotified(uint256 indexed cycle, address indexed token, address indexed poster, uint256 amount);

    function setUp() public override {
        super.setUp();

        rewardToken = new TestToken();
        otherRewardToken = new TestToken();
        feeToken = new FeeToken(1_000);

        voter.setRewardTokenWhitelisted(address(rewardToken), true);
        voter.setRewardTokenWhitelisted(address(otherRewardToken), true);
        voter.setRewardTokenWhitelisted(address(feeToken), true);

        rewardToken.mint(operator, 1_000 ether);
        rewardToken.mint(stranger, 1_000 ether);
        otherRewardToken.mint(operator, 1_000 ether);
        feeToken.mint(operator, 1_000 ether);
    }

    function test_constructorStoresValidatorTargetMetadata() public view {
        assertEq(gauge.registry(), address(registry));
        assertEq(gauge.vault(), gaugeVault);
        assertEq(gauge.operator(), operator);
        assertEq(gauge.requestId(), gaugeRequestId);
        assertEq(gauge.validatorId(), 0);
    }

    function test_notifyRewardTracksCycleTokenTotalAndPosterContribution() public {
        uint256 cycle = 7;
        uint256 amount = 100 ether;
        _setEpoch(35, false);

        vm.startPrank(operator);
        rewardToken.approve(address(gauge), amount);

        vm.expectEmit(true, true, true, true);
        emit RewardNotified(cycle, address(rewardToken), operator, amount);

        uint256 received = gauge.notifyReward(address(rewardToken), amount);
        vm.stopPrank();

        assertEq(received, amount);
        assertEq(rewardToken.balanceOf(address(gauge)), amount);
        assertEq(gauge.totalRewards(cycle, address(rewardToken)), amount);
        assertEq(gauge.rewardContributions(cycle, address(rewardToken), operator), amount);
    }

    function test_notifyRewardAggregatesByCycleTokenAndPoster() public {
        _setEpoch(5, false);
        vm.startPrank(operator);
        rewardToken.approve(address(gauge), 375 ether);
        otherRewardToken.approve(address(gauge), 50 ether);
        gauge.notifyReward(address(rewardToken), 100 ether);
        gauge.notifyReward(address(rewardToken), 200 ether);
        gauge.notifyReward(address(otherRewardToken), 50 ether);
        vm.stopPrank();

        _setEpoch(10, false);
        vm.prank(operator);
        gauge.notifyReward(address(rewardToken), 75 ether);

        _setEpoch(5, false);
        vm.startPrank(stranger);
        rewardToken.approve(address(gauge), 25 ether);
        gauge.notifyReward(address(rewardToken), 25 ether);
        vm.stopPrank();

        assertEq(gauge.totalRewards(1, address(rewardToken)), 325 ether);
        assertEq(gauge.totalRewards(2, address(rewardToken)), 75 ether);
        assertEq(gauge.totalRewards(1, address(otherRewardToken)), 50 ether);
        assertEq(gauge.rewardContributions(1, address(rewardToken), operator), 300 ether);
        assertEq(gauge.rewardContributions(1, address(rewardToken), stranger), 25 ether);
        assertEq(gauge.rewardContributions(2, address(rewardToken), stranger), 0);
    }

    function test_notifyRewardAccountsForActualAmountReceived() public {
        uint256 cycle = 3;
        uint256 amount = 100 ether;
        uint256 expectedReceived = 90 ether;
        _setEpoch(15, false);

        vm.startPrank(operator);
        feeToken.approve(address(gauge), amount);

        vm.expectEmit(true, true, true, true);
        emit RewardNotified(cycle, address(feeToken), operator, expectedReceived);

        uint256 received = gauge.notifyReward(address(feeToken), amount);
        vm.stopPrank();

        assertEq(received, expectedReceived);
        assertEq(feeToken.balanceOf(address(gauge)), expectedReceived);
        assertEq(gauge.totalRewards(cycle, address(feeToken)), expectedReceived);
        assertEq(gauge.rewardContributions(cycle, address(feeToken), operator), expectedReceived);
    }

    function test_notifyRewardRevertsForInvalidReward() public {
        vm.expectRevert(ValidatorGauge.InvalidReward.selector);
        gauge.notifyReward(address(rewardToken), 0);

        vm.expectRevert(ValidatorGauge.InvalidReward.selector);
        gauge.notifyReward(address(0), 1);
    }

    function test_notifyRewardRequiresWhitelistedToken() public {
        vm.prank(operator);
        vm.expectRevert(ValidatorGauge.RewardTokenNotWhitelisted.selector);
        gauge.notifyReward(address(0x1234), 1);
    }

    function test_refundRequiresCycleRolloverAndOnlyRefundsOwnContribution() public {
        _setEpoch(5, false);
        vm.startPrank(operator);
        rewardToken.approve(address(gauge), 100 ether);
        gauge.notifyReward(address(rewardToken), 100 ether);
        vm.stopPrank();

        vm.expectRevert(ValidatorGauge.CycleNotEnded.selector);
        gauge.refundReward(1, address(rewardToken));

        _setEpoch(10, false);
        vm.prank(stranger);
        vm.expectRevert(ValidatorGauge.NoContribution.selector);
        gauge.refundReward(1, address(rewardToken));

        uint256 beforeBalance = rewardToken.balanceOf(operator);
        vm.prank(operator);
        vm.expectEmit(true, true, true, true);
        emit RewardRefunded(1, address(rewardToken), operator, 100 ether);
        assertEq(gauge.refundReward(1, address(rewardToken)), 100 ether);
        assertEq(rewardToken.balanceOf(operator), beforeBalance + 100 ether);
        assertEq(gauge.totalRewards(1, address(rewardToken)), 0);

        vm.prank(operator);
        vm.expectRevert(ValidatorGauge.NoContribution.selector);
        gauge.refundReward(1, address(rewardToken));
    }

    function test_acceptedValidatorRewardsCannotBeRefunded() public {
        _setEpoch(5, false);
        vm.prank(operator);
        rewardToken.approve(address(gauge), 20 ether);
        vm.prank(operator);
        gauge.notifyReward(address(rewardToken), 20 ether);
        voter.setValidatorAccepted(gaugeRequestId, 1, true);

        _setEpoch(10, false);
        vm.prank(operator);
        vm.expectRevert(ValidatorGauge.ValidatorAccepted.selector);
        gauge.refundReward(1, address(rewardToken));
    }

    function test_voterClaimsFinalizedGaugeRewardOnce() public {
        uint256 tokenId;
        _setEpoch(1, false);
        vm.prank(operator);
        tokenId = veMON.createLock{value: 100 ether}(100 ether, lockDuration);
        voter.setValidatorAccepted(gaugeRequestId, 0, true);

        address[] memory gauges = new address[](1);
        gauges[0] = address(gauge);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;
        vm.prank(operator);
        voter.vote(tokenId, gauges, weights);

        vm.startPrank(operator);
        rewardToken.approve(address(gauge), 100 ether);
        gauge.notifyReward(address(rewardToken), 100 ether);
        vm.stopPrank();

        assertEq(gauge.earned(tokenId, 0, address(rewardToken)), 100 ether);
        _setEpoch(5, false);
        uint256 beforeBalance = rewardToken.balanceOf(operator);
        assertEq(gauge.claim(tokenId, 0, address(rewardToken)), 100 ether);
        assertEq(rewardToken.balanceOf(operator), beforeBalance + 100 ether);

        vm.expectRevert(ValidatorGauge.NoReward.selector);
        gauge.claim(tokenId, 0, address(rewardToken));
    }

    function test_claimWaitsForRolloverAndAcceptedCycle() public {
        uint256 tokenId;
        _setEpoch(1, false);
        vm.prank(operator);
        tokenId = veMON.createLock{value: 100 ether}(100 ether, lockDuration);
        vm.prank(operator);
        rewardToken.approve(address(gauge), 10 ether);
        vm.prank(operator);
        gauge.notifyReward(address(rewardToken), 10 ether);

        vm.expectRevert(ValidatorGauge.CycleNotEnded.selector);
        gauge.claim(tokenId, 0, address(rewardToken));
        _setEpoch(5, false);
        vm.expectRevert(ValidatorGauge.NotAccepted.selector);
        gauge.claim(tokenId, 0, address(rewardToken));
    }

    function test_claimsMultipleRewardTokensProportionally() public {
        _setEpoch(1, false);
        uint256 tokenId;
        vm.prank(operator);
        tokenId = veMON.createLock{value: 100 ether}(100 ether, lockDuration);
        voter.setValidatorAccepted(gaugeRequestId, 0, true);
        address[] memory gauges = new address[](1);
        gauges[0] = address(gauge);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;
        vm.prank(operator);
        voter.vote(tokenId, gauges, weights);

        vm.startPrank(operator);
        rewardToken.approve(address(gauge), 100 ether);
        otherRewardToken.approve(address(gauge), 40 ether);
        gauge.notifyReward(address(rewardToken), 100 ether);
        gauge.notifyReward(address(otherRewardToken), 40 ether);
        vm.stopPrank();

        _setEpoch(5, false);
        address[] memory tokens = new address[](2);
        tokens[0] = address(rewardToken);
        tokens[1] = address(otherRewardToken);
        uint256[] memory amounts = gauge.claim(tokenId, 0, tokens);
        assertEq(amounts[0], 100 ether);
        assertEq(amounts[1], 40 ether);
        assertEq(rewardToken.balanceOf(operator), 1_000 ether);
        assertEq(otherRewardToken.balanceOf(operator), 1_000 ether);
    }

    function test_refundsRemainAvailableAfterTokenIsRemovedFromWhitelist() public {
        _setEpoch(5, false);
        vm.prank(operator);
        rewardToken.approve(address(gauge), 20 ether);
        vm.prank(operator);
        gauge.notifyReward(address(rewardToken), 20 ether);
        voter.setRewardTokenWhitelisted(address(rewardToken), false);

        _setEpoch(10, false);
        vm.prank(operator);
        assertEq(gauge.refundReward(1, address(rewardToken)), 20 ether);
    }

    function test_refundsAreScopedToPosterAndToken() public {
        _setEpoch(5, false);
        vm.startPrank(operator);
        rewardToken.approve(address(gauge), 100 ether);
        otherRewardToken.approve(address(gauge), 50 ether);
        gauge.notifyReward(address(rewardToken), 100 ether);
        gauge.notifyReward(address(otherRewardToken), 50 ether);
        vm.stopPrank();

        vm.startPrank(stranger);
        rewardToken.approve(address(gauge), 40 ether);
        gauge.notifyReward(address(rewardToken), 40 ether);
        vm.stopPrank();

        _setEpoch(10, false);
        vm.prank(operator);
        assertEq(gauge.refundReward(1, address(rewardToken)), 100 ether);
        vm.prank(operator);
        assertEq(gauge.refundReward(1, address(otherRewardToken)), 50 ether);
        vm.prank(stranger);
        assertEq(gauge.refundReward(1, address(rewardToken)), 40 ether);

        assertEq(gauge.totalRewards(1, address(rewardToken)), 0);
        assertEq(gauge.totalRewards(1, address(otherRewardToken)), 0);
    }

    event RewardRefunded(uint256 indexed cycle, address indexed token, address indexed poster, uint256 amount);

    function test_validatorIdTracksRegistryProposal() public {
        StakingVault vault = StakingVault(payable(gaugeVault));

        vm.deal(address(controller), 1_000_000 ether);
        vm.prank(address(controller));
        uint64 validatorId = vault.addValidator{value: validatorStake}(commission);

        assertEq(gauge.validatorId(), validatorId);
    }
}

contract TestToken is ERC20 {
    constructor() ERC20("Test Token", "TEST") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract FeeToken is TestToken {
    uint256 private immutable _feeBps;

    constructor(uint256 feeBps_) {
        _feeBps = feeBps_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || _feeBps == 0) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = (value * _feeBps) / 10_000;
        super._update(from, to, value - fee);
        super._update(from, address(0xdead), fee);
    }
}
