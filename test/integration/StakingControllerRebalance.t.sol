// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StakingAgent} from "../../src/staking/controlled/StakingAgent.sol";
import {StakingVault} from "../../src/staking/controlled/StakingVault.sol";
import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";
import {IStakingController} from "../../src/interfaces/IStakingController.sol";
import {ProtocolTimeLibrary} from "../../src/libraries/ProtocolTimeLibrary.sol";
import {StakingControllerFixture} from "../fixtures/StakingControllerFixture.sol";

contract StakingControllerRebalanceIntegrationTest is StakingControllerFixture {
    uint256 private constant TOTAL_LOCKED = 400_000 ether;
    uint256 private constant INITIAL_A = 160_000 ether;
    uint256 private constant INITIAL_B = 140_000 ether;
    uint256 private constant INITIAL_C = 100_000 ether;
    uint256 private constant REDUCE_A = 80_000 ether;
    uint256 private constant REMOVE_C = 100_000 ether;
    uint256 private constant INCREASE_B = 60_000 ether;
    uint256 private constant ADD_D = 120_000 ether;

    address private vaultA;
    address private vaultB;
    address private vaultC;
    address private vaultD;
    uint64 private validatorIdA;
    uint64 private validatorIdB;
    uint64 private validatorIdC;
    StakingAgent private agent;
    uint256 private ownerBalanceAfterLock;

    function test_reusesLockedMONWhenReallocatingAcrossValidators() public {
        _setupValidators();
        _initialStake();
        _releaseReductions();
        _stakeReallocation();
    }

    function test_stakeRestakeAndCompoundKeepVeMONEqualToBackingAcrossEpochs() public {
        vaultA = _deployValidator(keccak256("compound-validator-a"), 1);
        vaultB = _deployValidator(keccak256("compound-validator-b"), 2);

        uint256 initialPerValidator = 10_100_000 ether;
        uint256 lockedAmount = 2 * initialPerValidator;
        vm.deal(operator, lockedAmount + 100 ether);
        vm.prank(operator);
        veMON.createLock{value: lockedAmount}(lockedAmount, lockDuration);

        address[] memory vaults = new address[](2);
        vaults[0] = vaultA;
        vaults[1] = vaultB;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = initialPerValidator;
        amounts[1] = initialPerValidator;
        vm.prank(operator);
        controller.stake(1, vaults, amounts);
        validatorIdA = StakingVault(payable(vaultA)).validatorId();
        validatorIdB = StakingVault(payable(vaultB)).validatorId();
        StakingAgent tokenAgent = StakingAgent(payable(controller.agentByToken(1)));
        _assertBacking(lockedAmount);

        _setEpoch(6, false);
        amounts[0] -= 100_000 ether;
        amounts[1] += 100_000 ether;
        vm.prank(operator);
        controller.stake(1, vaults, amounts);
        (int128 amountAfterRestake,,,) = veMON.locked(1);
        assertEq(int256(amountAfterRestake), int256(lockedAmount));

        (,, uint64 withdrawEpoch) = staking.getWithdrawalRequest(validatorIdA, address(tokenAgent), 0);
        _setEpoch(withdrawEpoch + 1, false);
        assertEq(ProtocolTimeLibrary.currentCycle(), 1);
        vm.prank(makeAddr("compound-keeper"));
        assertTrue(controller.poke(1));
        _assertBacking(lockedAmount);

        _setEpoch(9, false);
        _setEpoch(10, false);
        _setEpoch(11, false);

        (int128 amountBeforeCompound,,,) = veMON.locked(1);
        assertEq(int256(amountBeforeCompound), int256(lockedAmount));
        vm.prank(operator);
        uint256 compounded = controller.compound(1);

        assertEq(compounded, 0);
        _assertBacking(lockedAmount);
        (int128 amountAfterCompound,,,) = veMON.locked(1);
        assertEq(int256(amountAfterCompound), int256(lockedAmount));
    }

    function test_claimRewardsEveryCycleAfterMultipleCyclesAndAlternatingWithCompound() public {
        // The fork harness does not snapshot test-created validators into its
        // consensus set, so their native reward balance stays empty here.
        vaultA = _deployValidator(keccak256("claim-validator-a"), 1);
        vaultB = _deployValidator(keccak256("claim-validator-b"), 2);

        uint256 initialPerValidator = 10_100_000 ether;
        uint256 lockedAmount = 2 * initialPerValidator;
        vm.deal(operator, lockedAmount + 100 ether);
        vm.prank(operator);
        veMON.createLock{value: lockedAmount}(lockedAmount, lockDuration);

        address[] memory vaults = new address[](2);
        vaults[0] = vaultA;
        vaults[1] = vaultB;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = initialPerValidator;
        amounts[1] = initialPerValidator;
        vm.prank(operator);
        controller.stake(1, vaults, amounts);
        validatorIdA = StakingVault(payable(vaultA)).validatorId();
        validatorIdB = StakingVault(payable(vaultB)).validatorId();

        // Restake in the next cycle, then claim after the withdrawal matures.
        _setEpoch(6, false);
        amounts[0] -= 100_000 ether;
        amounts[1] += 100_000 ether;
        vm.prank(operator);
        controller.stake(1, vaults, amounts);
        (,, uint64 withdrawEpoch) = staking.getWithdrawalRequest(validatorIdA, controller.agentByToken(1), 0);
        _setEpoch(withdrawEpoch + 1, false);
        vm.prank(makeAddr("claim-keeper"));
        assertTrue(controller.poke(1));
        _assertBacking(lockedAmount);

        // Claim after each of two consecutive cycles.
        _setEpoch(10, false);
        assertEq(ProtocolTimeLibrary.currentCycle(), 2);
        uint256 ownerBalance = operator.balance;
        vm.prank(operator);
        controller.claimRewards(1, vaults);
        uint256 firstCycleClaim = operator.balance - ownerBalance;
        assertEq(firstCycleClaim, 0);
        _assertBacking(lockedAmount);

        _setEpoch(15, false);
        assertEq(ProtocolTimeLibrary.currentCycle(), 3);
        ownerBalance = operator.balance;
        vm.prank(operator);
        controller.claimRewards(1, vaults);
        uint256 secondCycleClaim = operator.balance - ownerBalance;
        assertEq(secondCycleClaim, 0);
        _assertBacking(lockedAmount);

        // Leave two cycles without a claim, then claim once after both rollovers.
        _setEpoch(20, false);
        assertEq(ProtocolTimeLibrary.currentCycle(), 4);
        _setEpoch(25, false);
        assertEq(ProtocolTimeLibrary.currentCycle(), 5);
        ownerBalance = operator.balance;
        vm.prank(operator);
        controller.claimRewards(1, vaults);
        uint256 multiCycleClaim = operator.balance - ownerBalance;
        assertEq(multiCycleClaim, firstCycleClaim + secondCycleClaim);
        _assertBacking(lockedAmount);

        // Alternate compounding and liquid claims across successive cycles.
        _setEpoch(30, false);
        assertEq(ProtocolTimeLibrary.currentCycle(), 6);
        vm.prank(operator);
        uint256 firstCompound = controller.compound(1);
        assertEq(firstCompound, 0);
        lockedAmount += firstCompound;
        _assertBacking(lockedAmount);

        _setEpoch(35, false);
        assertEq(ProtocolTimeLibrary.currentCycle(), 7);
        ownerBalance = operator.balance;
        vm.prank(operator);
        controller.claimRewards(1, vaults);
        assertEq(operator.balance, ownerBalance);
        _assertBacking(lockedAmount);

        _setEpoch(40, false);
        assertEq(ProtocolTimeLibrary.currentCycle(), 8);
        vm.prank(operator);
        uint256 secondCompound = controller.compound(1);
        assertEq(secondCompound, 0);
        lockedAmount += secondCompound;
        _assertBacking(lockedAmount);

        _setEpoch(45, false);
        assertEq(ProtocolTimeLibrary.currentCycle(), 9);
        ownerBalance = operator.balance;
        vm.prank(operator);
        controller.claimRewards(1, vaults);
        assertEq(operator.balance, ownerBalance);
        _assertBacking(lockedAmount);
    }

    function test_sharedVaultRewardsAreAccountedPerTokenAndCompoundIndependently() public {
        vaultA = _deployValidator(keccak256("shared-reward-validator"), 1);

        uint256 firstShare = 80_000 ether;
        uint256 secondShare = 20_000 ether;
        vm.deal(operator, firstShare + 1 ether);
        vm.prank(operator);
        veMON.createLock{value: firstShare}(firstShare, lockDuration);
        vm.deal(stranger, secondShare + 1 ether);
        vm.prank(stranger);
        veMON.createLock{value: secondShare}(secondShare, lockDuration);

        address[] memory vaults = new address[](1);
        vaults[0] = vaultA;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = firstShare;
        vm.prank(operator);
        controller.stake(1, vaults, amounts);
        amounts[0] = secondShare;
        vm.prank(stranger);
        controller.stake(2, vaults, amounts);

        vaultB = _deployValidator(keccak256("other-reward-validator"), 2);
        vm.prank(owner);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);
        amounts[0] = validatorStake;
        vm.prank(owner);
        controller.stake(3, _singleVault(vaultB), amounts);

        vm.prank(stranger);
        vm.expectRevert(IStakingController.NotVaultParticipant.selector);
        controller.claimRewards(2, _singleVault(vaultB));

        uint256 reward = 100 ether;
        vm.deal(vaultA, reward);
        _mockVaultRewards(vaultA, StakingVault(payable(vaultA)).validatorId(), reward);
        vm.mockCall(
            address(staking),
            abi.encodeCall(IMonadStaking.claimRewards, (StakingVault(payable(vaultA)).validatorId())),
            abi.encode(true)
        );

        (int128 firstLockedBefore,,,) = veMON.locked(1);
        (int128 secondLockedBefore,,,) = veMON.locked(2);
        vm.prank(operator);
        assertEq(controller.compound(1), 80 ether);
        (int128 firstLockedAfter,,,) = veMON.locked(1);
        (int128 secondLockedAfter,,,) = veMON.locked(2);
        assertEq(int256(firstLockedAfter), int256(firstLockedBefore) + 80 ether);
        assertEq(int256(secondLockedAfter), int256(secondLockedBefore));
        assertEq(StakingVault(payable(vaultA)).balanceOf(2), secondShare);
        assertEq(controller.allocationOf(1, vaultA), firstShare + 80 ether);
        assertEq(controller.allocationOf(2, vaultA), secondShare);

        _mockVaultRewards(vaultA, StakingVault(payable(vaultA)).validatorId(), 0);
        uint256 strangerBalanceBefore = stranger.balance;
        vm.prank(stranger);
        controller.claimRewards(2, _singleVault(vaultA));
        assertEq(stranger.balance - strangerBalanceBefore, 20 ether);
    }

    function test_lateVaultDepositDoesNotSharePreviouslyAccruedRewards() public {
        vaultA = _deployValidator(keccak256("late-deposit-reward-validator"), 1);

        vm.deal(operator, validatorStake + 1 ether);
        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);
        vm.prank(operator);
        controller.stake(1, _singleVault(vaultA), _singleAmount(validatorStake));

        uint64 validatorId = StakingVault(payable(vaultA)).validatorId();
        uint256 reward = 50 ether;
        vm.deal(vaultA, reward);
        _mockVaultRewards(vaultA, validatorId, reward);
        vm.mockCall(address(staking), abi.encodeCall(IMonadStaking.claimRewards, (validatorId)), abi.encode(true));

        vm.deal(stranger, 25_000 ether + 1 ether);
        vm.prank(stranger);
        veMON.createLock{value: 25_000 ether}(25_000 ether, lockDuration);
        vm.prank(stranger);
        controller.stake(2, _singleVault(vaultA), _singleAmount(25_000 ether));

        uint256 operatorBalance = operator.balance;
        vm.prank(operator);
        controller.claimRewards(1, _singleVault(vaultA));
        assertEq(operator.balance - operatorBalance, reward);

        _mockVaultRewards(vaultA, validatorId, 0);
        uint256 strangerBalance = stranger.balance;
        vm.prank(stranger);
        controller.claimRewards(2, _singleVault(vaultA));
        assertEq(stranger.balance - strangerBalance, 0);
    }

    function test_restoresActivatedVaultDeficitBeforeDelegatingRemainderToAgent() public {
        vaultA = _deployValidator(keccak256("vault-deficit-validator"), 1);

        vm.deal(operator, validatorStake + 1 ether);
        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);
        vm.prank(operator);
        controller.stake(1, _singleVault(vaultA), _singleAmount(validatorStake));

        uint64 validatorId = StakingVault(payable(vaultA)).validatorId();
        _setEpoch(6, false);
        vm.prank(operator);
        controller.unstake(1, _singleVault(vaultA), _singleAmount(40_000 ether));
        assertEq(StakingVault(payable(vaultA)).deficit(), 40_000 ether);

        vm.deal(stranger, validatorStake + 1 ether);
        vm.prank(stranger);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);
        vm.prank(stranger);
        controller.stake(2, _singleVault(vaultA), _singleAmount(validatorStake));

        StakingVault vault = StakingVault(payable(vaultA));
        StakingAgent tokenAgent = StakingAgent(payable(controller.agentByToken(2)));
        assertEq(vault.balanceOf(2), 40_000 ether);
        assertEq(vault.totalBalance(), validatorStake);
        assertEq(tokenAgent.balanceOf(validatorId), 60_000 ether);
        assertEq(controller.allocationOf(2, vaultA), validatorStake);
    }

    function test_rewardSharesSurvivePartialAndFullExit() public {
        vaultA = _deployValidator(keccak256("exit-reward-validator"), 1);

        uint256 firstShare = 80_000 ether;
        uint256 secondShare = 20_000 ether;
        vm.deal(operator, firstShare + 1 ether);
        vm.prank(operator);
        veMON.createLock{value: firstShare}(firstShare, lockDuration);
        vm.deal(stranger, secondShare + 1 ether);
        vm.prank(stranger);
        veMON.createLock{value: secondShare}(secondShare, lockDuration);

        vm.prank(operator);
        controller.stake(1, _singleVault(vaultA), _singleAmount(firstShare));
        vm.prank(stranger);
        controller.stake(2, _singleVault(vaultA), _singleAmount(secondShare));

        uint64 validatorId = StakingVault(payable(vaultA)).validatorId();
        uint256 reward = 100 ether;
        _mockVaultRewards(vaultA, validatorId, reward);
        vm.mockCall(address(staking), abi.encodeCall(IMonadStaking.claimRewards, (validatorId)), abi.encode(true));

        _setEpoch(6, false);
        vm.prank(operator);
        controller.unstake(1, _singleVault(vaultA), _singleAmount(40_000 ether));

        (,, uint64 firstExitEpoch) = staking.getWithdrawalRequest(validatorId, address(vaultA), 0);
        _setEpoch(firstExitEpoch + 1, false);
        vm.prank(makeAddr("partial-exit-keeper"));
        controller.poke(1);

        vm.prank(stranger);
        controller.unstake(2, _singleVault(vaultA), _singleAmount(secondShare));

        _mockVaultRewards(vaultA, validatorId, reward);
        vm.deal(vaultA, reward);

        uint256 operatorBalance = operator.balance;
        vm.prank(operator);
        controller.claimRewards(1, _singleVault(vaultA));
        assertEq(operator.balance - operatorBalance, 80 ether);
        assertEq(StakingVault(payable(vaultA)).balanceOf(1), 40_000 ether);

        _mockVaultRewards(vaultA, validatorId, 0);
        _setEpoch(20, false);
        uint256 strangerBalance = stranger.balance;
        vm.prank(stranger);
        veMON.withdraw(2);
        assertEq(stranger.balance - strangerBalance, secondShare + 20 ether);
        assertEq(veMON.balanceOf(stranger), 0);
        assertEq(controller.balanceOf(2), 0);
    }

    function _mockVaultRewards(address vault, uint64 validatorId, uint256 unclaimed) internal {
        vm.mockCall(
            address(staking),
            abi.encodeCall(IMonadStaking.getDelegator, (validatorId, vault)),
            abi.encode(uint256(0), uint256(0), unclaimed, uint256(0), uint256(0), uint64(0), uint64(0))
        );
    }

    function _singleAmount(uint256 amount) internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](1);
        amounts[0] = amount;
    }

    function _singleVault(address vault) internal pure returns (address[] memory vaults) {
        vaults = new address[](1);
        vaults[0] = vault;
    }

    function _setupValidators() internal {
        vaultA = _deployValidator(keccak256("validator-a"), 1);
        vaultB = _deployValidator(keccak256("validator-b"), 2);
        vaultC = _deployValidator(keccak256("validator-c"), 3);
        vaultD = _deployValidator(keccak256("validator-d"), 4);
    }

    function _initialStake() internal {
        vm.prank(operator);
        veMON.createLock{value: TOTAL_LOCKED}(TOTAL_LOCKED, lockDuration);
        ownerBalanceAfterLock = operator.balance;
        (int128 lockedAmount,,,) = veMON.locked(1);
        assertEq(int256(lockedAmount), int256(TOTAL_LOCKED));
        assertEq(controller.balanceOf(1), TOTAL_LOCKED);

        address[] memory vaults = new address[](3);
        vaults[0] = vaultA;
        vaults[1] = vaultB;
        vaults[2] = vaultC;
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = INITIAL_A;
        amounts[1] = INITIAL_B;
        amounts[2] = INITIAL_C;

        vm.prank(operator);
        controller.stake(1, vaults, amounts);

        agent = StakingAgent(payable(controller.agentByToken(1)));
        assertEq(controller.stakingCycleOf(1), 0);
        validatorIdA = StakingVault(payable(vaultA)).validatorId();
        validatorIdB = StakingVault(payable(vaultB)).validatorId();
        validatorIdC = StakingVault(payable(vaultC)).validatorId();
        assertEq(controller.balanceOf(1), 0);
        assertEq(controller.allocationOf(1, vaultA), INITIAL_A);
        assertEq(controller.allocationOf(1, vaultB), INITIAL_B);
        assertEq(controller.allocationOf(1, vaultC), INITIAL_C);
        assertEq(controller.allocationOf(1, vaultD), 0);
        assertEq(_allocationSum(1), TOTAL_LOCKED);
        assertEq(controller.balanceOf(1) + _allocationSum(1), TOTAL_LOCKED);
        assertEq(StakingVault(payable(vaultA)).balanceOf(1), validatorStake);
        assertEq(StakingVault(payable(vaultB)).balanceOf(1), validatorStake);
        assertEq(StakingVault(payable(vaultC)).balanceOf(1), validatorStake);
        assertEq(agent.balanceOf(validatorIdA), INITIAL_A - validatorStake);
        assertEq(agent.balanceOf(validatorIdB), INITIAL_B - validatorStake);
        assertEq(agent.balanceOf(validatorIdC), 0);
    }

    function _releaseReductions() internal {
        // A later cycle replaces the allocation intent. B remains active while
        // A is reduced, C is removed, and D is added.
        _setEpoch(6, false);
        address[] memory vaults = new address[](3);
        vaults[0] = vaultA;
        vaults[1] = vaultB;
        vaults[2] = vaultD;
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = INITIAL_A - REDUCE_A;
        amounts[1] = INITIAL_B + INCREASE_B;
        amounts[2] = ADD_D;
        vm.prank(operator);
        controller.stake(1, vaults, amounts);

        assertEq(controller.allocationOf(1, vaultA), INITIAL_A - REDUCE_A);
        assertEq(controller.allocationOf(1, vaultB), INITIAL_B);
        assertEq(controller.allocationOf(1, vaultC), 0);
        assertEq(controller.allocationOf(1, vaultD), 0);
        assertEq(controller.intentOf(1, vaultA), INITIAL_A - REDUCE_A);
        assertEq(controller.intentOf(1, vaultB), INITIAL_B + INCREASE_B);
        assertEq(controller.intentOf(1, vaultC), 0);
        assertEq(controller.intentOf(1, vaultD), ADD_D);
        assertEq(controller.pendingOf(1, vaultA), REDUCE_A);
        assertEq(controller.pendingOf(1, vaultC), REMOVE_C);
        assertEq(controller.balanceOf(1), 0);
    }

    function _stakeReallocation() internal {
        uint64 withdrawalEpoch = _maxWithdrawalEpoch();
        _setEpoch(withdrawalEpoch + 1, false);

        // Anyone can advance the rebalance once the withdrawal delay has elapsed.
        vm.prank(makeAddr("keeper"));
        bool satisfied = controller.poke(1);
        assertTrue(satisfied);

        StakingAgent finalAgent = StakingAgent(payable(controller.agentByToken(1)));
        uint64 validatorIdD = StakingVault(payable(vaultD)).validatorId();
        assertEq(address(finalAgent), address(agent));
        assertEq(controller.stakingCycleOf(1), 1);
        assertEq(controller.balanceOf(1), 0);
        assertEq(controller.allocationOf(1, vaultA), INITIAL_A - REDUCE_A);
        assertEq(controller.allocationOf(1, vaultB), INITIAL_B + INCREASE_B);
        assertEq(controller.allocationOf(1, vaultC), 0);
        assertEq(controller.allocationOf(1, vaultD), ADD_D);
        assertEq(controller.pendingOf(1, vaultA), 0);
        assertEq(controller.pendingOf(1, vaultC), 0);
        assertEq(_allocationSum(1), TOTAL_LOCKED);
        assertLe(_allocationSum(1), TOTAL_LOCKED);
        assertEq(controller.balanceOf(1) + _allocationSum(1), TOTAL_LOCKED);

        assertEq(StakingVault(payable(vaultA)).balanceOf(1), INITIAL_A - REDUCE_A);
        assertEq(StakingVault(payable(vaultB)).balanceOf(1), validatorStake);
        assertEq(StakingVault(payable(vaultC)).balanceOf(1), 0);
        assertEq(StakingVault(payable(vaultD)).balanceOf(1), validatorStake);
        assertEq(finalAgent.balanceOf(validatorIdA), 0);
        assertEq(finalAgent.balanceOf(validatorIdB), INITIAL_B - validatorStake + INCREASE_B);
        assertEq(finalAgent.balanceOf(validatorIdC), 0);
        assertEq(finalAgent.balanceOf(validatorIdD), ADD_D - validatorStake);

        (int128 lockedAmount,,,) = veMON.locked(1);
        assertEq(int256(lockedAmount), int256(TOTAL_LOCKED));
        assertEq(operator.balance, ownerBalanceAfterLock);
        assertEq(veMON.balanceOf(operator), 1);
    }

    function _deployValidator(bytes32 saltSeed, uint8 keyNumber) internal returns (address vault) {
        address expectedAuthAddress = controller.predictVaultAddress(operator, saltSeed);
        bytes memory validatorSecpPubkey = _secpPubkey(keyNumber);
        bytes memory payload = abi.encodePacked(
            validatorSecpPubkey,
            _blsPubkey(keyNumber),
            bytes20(expectedAuthAddress),
            bytes32(validatorStake),
            bytes32(commission)
        );
        vm.prank(operator);
        uint256 requestId = registry.requestValidator(payload, secpSig, blsSig);
        vm.prank(operator);
        vault = controller.admitValidatorRequest(requestId, saltSeed);
    }

    function _secpPubkey(uint8 keyNumber) internal view returns (bytes memory) {
        if (keyNumber == 1) return secpPubkey;
        if (keyNumber == 2) {
            return hex"02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5";
        }
        if (keyNumber == 3) {
            return hex"02f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9";
        }
        return hex"02e493dbf1c10d80f3581e4904930b1404cc6c13900ee0758474fa94abe8c4cd13";
    }

    function _blsPubkey(uint8 keyNumber) internal pure returns (bytes memory) {
        if (keyNumber == 1) {
            return hex"97f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb";
        }
        if (keyNumber == 2) {
            return hex"a572cbea904d67468808c8eb50a9450c9721db309128012543902d0ac358a62ae28f75bb8f1c7c42c39a8c5529bf0f4e";
        }
        if (keyNumber == 3) {
            return hex"89ece308f9d1f0131765212deca99697b112d61f9be9a5f1f3780a51335b3ff981747a0b2ca2179b96d2c0c9024e5224";
        }
        return hex"ac9b60d5afcbd5663a8a44b7c5a02f19e9a77ab0a35bd65809bb5c67ec582c897feb04decc694b13e08587f3ff9b5b60";
    }

    function _allocationSum(uint256 tokenId) internal view returns (uint256) {
        return controller.allocationOf(tokenId, vaultA) + controller.allocationOf(tokenId, vaultB)
            + controller.allocationOf(tokenId, vaultC) + controller.allocationOf(tokenId, vaultD);
    }

    function _assertVeMONMatchesBacking(uint256 expectedAmount) internal view {
        (int128 lockedAmount,,,) = veMON.locked(1);
        assertEq(int256(lockedAmount), int256(expectedAmount));
        assertEq(controller.balanceOf(1) + _allocationSum(1), expectedAmount);
    }

    function _assertBacking(uint256 expectedAmount) internal {
        (int128 lockedAmount,,,) = veMON.locked(1);
        assertEq(int256(lockedAmount), int256(expectedAmount));
        assertEq(
            controller.balanceOf(1) + controller.allocationOf(1, vaultA) + controller.allocationOf(1, vaultB),
            expectedAmount
        );

        address tokenAgent = controller.agentByToken(1);
        uint256 totalDelegated = _delegatedStake(validatorIdA, vaultA) + _delegatedStake(validatorIdA, tokenAgent)
            + _delegatedStake(validatorIdB, vaultB) + _delegatedStake(validatorIdB, tokenAgent);
        assertEq(totalDelegated, expectedAmount);
    }

    function _delegatedStake(uint64 validatorId, address delegator) internal returns (uint256 total) {
        (uint256 stake,,, uint256 deltaStake, uint256 nextDeltaStake,,) = staking.getDelegator(validatorId, delegator);
        total = stake + deltaStake + nextDeltaStake;
    }

    function _maxWithdrawalEpoch() internal returns (uint64 withdrawalEpoch) {
        (,, withdrawalEpoch) = staking.getWithdrawalRequest(validatorIdA, address(agent), 0);
        (,, uint64 epoch) = staking.getWithdrawalRequest(validatorIdA, vaultA, 0);
        if (epoch > withdrawalEpoch) withdrawalEpoch = epoch;
        (,, epoch) = staking.getWithdrawalRequest(validatorIdC, vaultC, 0);
        if (epoch > withdrawalEpoch) withdrawalEpoch = epoch;
    }
}
