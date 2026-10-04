// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {StakingController} from "../../src/staking/StakingController.sol";
import {StakingVault} from "../../src/staking/controlled/StakingVault.sol";
import {VeMON} from "../../src/VeMON.sol";
import {ValidatorRegistryFixture} from "../fixtures/ValidatorRegistryFixture.sol";

contract ConsensusBoundVault is StakingVault {
    function bindValidator(uint64 validatorId_) external onlyController {
        validatorId = validatorId_;
    }
}

contract ConsensusBoundController is StakingController {
    constructor(address registry_, address owner_) StakingController(registry_, owner_, 0) {}

    function attachConsensusValidator(address gauge, uint64 validatorId) external onlyOwner returns (address vault) {
        ConsensusBoundVault implementation = new ConsensusBoundVault();
        vault = Clones.clone(address(implementation));
        ConsensusBoundVault(payable(vault)).initialize(address(registry), 1);
        ConsensusBoundVault(payable(vault)).bindValidator(validatorId);
        vaultByGauge[gauge] = vault;
        gaugeByVault[vault] = gauge;
        _isVault[vault] = true;
    }
}

contract ForkNativeRewardsTest is ValidatorRegistryFixture {
    uint256 private constant FIRST_STAKE = 100_000 ether;
    uint256 private constant REPLACEMENT_STAKE = 20_000 ether;

    ConsensusBoundController private forkController;
    VeMON private forkVe;
    StakingVault private forkVault;
    address private gauge;
    address private vaultAddress;
    uint64 private validatorId;
    uint64 private firstWithdrawalEpoch;
    uint256 private expectedCompound;
    uint256 private expectedClaim;

    function test_forkConsensusRewardsCanBeCompoundedClaimedAndWithdrawn() public {
        _setupConsensusPosition();
        _replacePartOfVaultStake();
        _accrueNativeRewards();
        _compoundAndClaimRewards();
        _withdrawCompoundedPosition();
    }

    function _setupConsensusPosition() private {
        (,, uint64[] memory validators) = staking.getConsensusValidatorSet(0);
        assertGt(validators.length, 0, "fork has no consensus validators");
        validatorId = validators[0];

        forkController = new ConsensusBoundController(address(registry), address(this));
        forkVe = new VeMON(address(forkController), 4);
        forkController.setVe(address(forkVe));
        gauge = makeAddr("fork-consensus-gauge");
        vaultAddress = forkController.attachConsensusValidator(gauge, validatorId);
        forkVault = StakingVault(payable(vaultAddress));

        vm.deal(operator, FIRST_STAKE + 1 ether);
        vm.prank(operator);
        forkVe.createLock{value: FIRST_STAKE}(FIRST_STAKE, lockDuration);
        vm.prank(operator);
        forkController.stake(1, _oneGauge(gauge), _oneAmount(FIRST_STAKE));
    }

    function _replacePartOfVaultStake() private {
        // Rotate 20k of the first user's position out, then let a second veMON
        // fill that live vault deficit after the validator is already active.
        _setEpoch(6, false);
        vm.prank(operator);
        forkController.unstake(1, _oneGauge(gauge), _oneAmount(REPLACEMENT_STAKE));
        (,, firstWithdrawalEpoch) = staking.getWithdrawalRequest(validatorId, vaultAddress, 0);
        _setEpoch(firstWithdrawalEpoch + 1, false);
        vm.prank(makeAddr("fork-reward-withdraw-keeper"));
        forkController.poke(1);

        vm.deal(stranger, REPLACEMENT_STAKE + 1 ether);
        vm.prank(stranger);
        forkVe.createLock{value: REPLACEMENT_STAKE}(REPLACEMENT_STAKE, lockDuration);
        vm.prank(stranger);
        forkController.stake(2, _oneGauge(gauge), _oneAmount(REPLACEMENT_STAKE));
        assertEq(forkVault.balanceOf(1), 80_000 ether);
        assertEq(forkVault.balanceOf(2), REPLACEMENT_STAKE);
        assertEq(forkVault.totalBalance(), FIRST_STAKE);

        _setEpoch(firstWithdrawalEpoch + 2, false);
        (uint256 activeStake,,,,,,) = staking.getDelegator(validatorId, vaultAddress);
        assertEq(activeStake, FIRST_STAKE);
    }

    function _accrueNativeRewards() private {
        uint256 externalReward = 1_000_000 ether;
        vm.deal(address(this), externalReward);
        assertTrue(staking.externalReward{value: externalReward}(validatorId));
        (,, uint256 vaultRewards,,,,) = staking.getDelegator(validatorId, vaultAddress);
        assertGt(vaultRewards, 0, "fork validator produced no native MON reward");

        expectedCompound = vaultRewards * 80_000 / 100_000;
        expectedClaim = vaultRewards * 20_000 / 100_000;
    }

    function _compoundAndClaimRewards() private {
        uint256 firstBalance = operator.balance;
        vm.prank(operator);
        uint256 compounded = forkController.compound(1);
        assertEq(compounded, expectedCompound);
        assertEq(operator.balance, firstBalance);
        (int128 lockedAfterCompound,,,) = forkVe.locked(1);
        assertEq(uint256(uint128(lockedAfterCompound)), FIRST_STAKE + expectedCompound);
        assertEq(forkController.allocationOf(1, gauge), 80_000 ether + expectedCompound);

        uint256 secondBalance = stranger.balance;
        vm.prank(stranger);
        forkController.claimRewards(2, _oneGauge(gauge));
        assertEq(stranger.balance - secondBalance, expectedClaim);
        assertGt(forkVault.rewardReserve(), 0, "reward rounding should leave vault dust");
        assertEq(forkVault.availableBalance(), forkVault.rewardReserve());
    }

    function _withdrawCompoundedPosition() private {
        // The first user's compounded MON is real delegated backing and returns
        // with the original principal after the normal delayed exit flow.
        _setEpoch(firstWithdrawalEpoch + 3, false);
        uint256 firstAllocation = forkController.allocationOf(1, gauge);
        vm.prank(operator);
        forkController.unstake(1, _oneGauge(gauge), _oneAmount(firstAllocation));
        (,, uint64 principalWithdrawalEpoch) = staking.getWithdrawalRequest(validatorId, vaultAddress, 0);
        address agentAddress = forkController.agentByToken(1);
        (,, uint64 compoundWithdrawalEpoch) = staking.getWithdrawalRequest(validatorId, agentAddress, 0);
        uint64 finalWithdrawalEpoch =
            principalWithdrawalEpoch > compoundWithdrawalEpoch ? principalWithdrawalEpoch : compoundWithdrawalEpoch;
        _setEpoch(finalWithdrawalEpoch + 1, false);
        vm.prank(makeAddr("fork-reward-finalizer"));
        assertTrue(forkController.poke(1));

        _setEpoch(20, false);
        uint256 finalBalance = operator.balance;
        vm.prank(operator);
        forkVe.withdraw(1);
        assertEq(operator.balance - finalBalance, FIRST_STAKE + expectedCompound);
    }

    function _oneGauge(address gaugeAddress) private pure returns (address[] memory gauges) {
        gauges = new address[](1);
        gauges[0] = gaugeAddress;
    }

    function _oneAmount(uint256 amount) private pure returns (uint256[] memory amounts) {
        amounts = new uint256[](1);
        amounts[0] = amount;
    }
}
