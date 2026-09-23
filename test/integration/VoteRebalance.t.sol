// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {StakingAgent} from "../../src/staking/controlled/StakingAgent.sol";
import {StakingVault} from "../../src/staking/controlled/StakingVault.sol";
import {IStakingController} from "../../src/interfaces/IStakingController.sol";
import {ValidatorsVoterFixture} from "../fixtures/ValidatorsVoterFixture.sol";

/// @notice Vote targets are desired stake. Rebalance moves vault + agent balances toward them.
contract VoteRebalanceTest is ValidatorsVoterFixture {
    using stdStorage for StdStorage;
    uint256 internal constant PRINCIPAL = 200_000 ether;

    function test_firstVoteStakesLiquidMonToVoteAllocation() public {
        (address vaultA, address gaugeA) = _addValidator(2);
        (address vaultB, address gaugeB) = _addValidator(3);
        uint256 tokenId = _lock(100 ether);

        _voteWindow(6);
        _vote(tokenId, _gauges(gaugeA, gaugeB), _weights(1, 3));

        (uint128 weightA, uint128 stakeA) = validatorsVoter.votes(tokenId, gaugeA);
        (uint128 weightB, uint128 stakeB) = validatorsVoter.votes(tokenId, gaugeB);
        assertEq(weightA, 25 ether);
        assertEq(stakeA, 25 ether);
        assertEq(weightB, 75 ether);
        assertEq(stakeB, 75 ether);
        assertEq(controller.balanceOf(tokenId), 0);
        assertEq(controller.allocationOf(tokenId, gaugeA), 25 ether);
        assertEq(controller.allocationOf(tokenId, gaugeB), 75 ether);
        assertEq(StakingVault(payable(vaultA)).balanceOf(tokenId), 25 ether);
        assertEq(StakingVault(payable(vaultB)).balanceOf(tokenId), 75 ether);
        assertEq(_agentBalance(tokenId, vaultA) + _agentBalance(tokenId, vaultB), 0);
        _assertBooks(tokenId, _gauges(gaugeA, gaugeB), 100 ether);
    }

    function test_allocationOfIsVaultPlusAgentAndExcludesPendingWithdrawal() public {
        (address vaultA, address gaugeA) = _addValidator(2);
        uint256 tokenId = _lock(PRINCIPAL);

        _voteWindow(6);
        _vote(tokenId, _gauges(gaugeA), _weights(1));

        uint256 vaultBalance = StakingVault(payable(vaultA)).balanceOf(tokenId);
        uint256 agentBalance = _agentBalance(tokenId, vaultA);
        assertEq(vaultBalance, validatorStake);
        assertEq(agentBalance, PRINCIPAL - validatorStake);
        assertEq(controller.allocationOf(tokenId, gaugeA), vaultBalance + agentBalance);
        assertEq(controller.balanceOf(tokenId), 0);

        _voteWindow(11);
        (, address gaugeB) = _addValidator(3);
        _vote(tokenId, _gauges(gaugeA, gaugeB), _weights(3, 1));

        assertEq(StakingVault(payable(vaultA)).balanceOf(tokenId), validatorStake);
        assertEq(StakingVault(payable(vaultA)).exiting(), false);
        assertEq(_agentBalance(tokenId, vaultA), 50_000 ether);
        assertEq(_pending(tokenId, vaultA), 50_000 ether);
        // The 50_000 undelegated MON is no longer realized allocation.
        assertEq(controller.allocationOf(tokenId, gaugeA), 150_000 ether);
        assertEq(controller.allocationOf(tokenId, gaugeB), 0);
        _assertBooks(tokenId, _gauges(gaugeA, gaugeB), PRINCIPAL);
    }

    function test_subsequentVoteUnstakesOnlyTheAgentDelta() public {
        (address vaultA, address gaugeA) = _addValidator(2);
        (, address gaugeB) = _addValidator(3);
        uint256 tokenId = _lock(PRINCIPAL);
        _voteWindow(6);
        _vote(tokenId, _gauges(gaugeA), _weights(1));

        uint64 validatorId = StakingVault(payable(vaultA)).validatorId();
        _voteWindow(11);
        _vote(tokenId, _gauges(gaugeA, gaugeB), _weights(3, 1));

        assertEq(StakingVault(payable(vaultA)).balanceOf(tokenId), validatorStake);
        assertEq(_agentBalance(tokenId, vaultA), 50_000 ether);
        assertEq(_pending(tokenId, vaultA), 50_000 ether);
        (uint256 vaultWithdrawal,,) = staking.getWithdrawalRequest(validatorId, vaultA, 0);
        assertEq(vaultWithdrawal, 0);
        assertEq(controller.allocationOf(tokenId, gaugeB), 0);
        assertEq(controller.balanceOf(tokenId), 0);
    }

    function test_removedGaugeConvergesToZeroAndNewGaugeReceivesIdleMon() public {
        (address vaultA, address gaugeA) = _addValidator(2);
        (address vaultB, address gaugeB) = _addValidator(3);
        uint256 tokenId = _lock(100 ether);

        _voteWindow(6);
        _vote(tokenId, _gauges(gaugeA), _weights(1));
        assertEq(controller.allocationOf(tokenId, gaugeA), 100 ether);
        assertEq(StakingVault(payable(vaultA)).validatorId(), 0);

        _voteWindow(11);
        _vote(tokenId, _gauges(gaugeB), _weights(1));

        assertEq(controller.allocationOf(tokenId, gaugeA), 0);
        assertEq(StakingVault(payable(vaultA)).balanceOf(tokenId), 0);
        assertEq(controller.allocationOf(tokenId, gaugeB), 100 ether);
        assertEq(StakingVault(payable(vaultB)).balanceOf(tokenId), 100 ether);
        assertEq(controller.balanceOf(tokenId), 0);
        assertEq(validatorsVoter.poolVoteLength(tokenId), 1);
        _assertBooks(tokenId, _gauges(gaugeA, gaugeB), 100 ether);
    }

    function test_deficitStaysUnresolvedWhileWithdrawalIsPending() public {
        (address vaultA, address gaugeA) = _addValidator(2);
        (, address gaugeB) = _addValidator(3);
        uint256 tokenId = _lock(PRINCIPAL);
        _voteWindow(6);
        _vote(tokenId, _gauges(gaugeA), _weights(1));

        _voteWindow(11);
        _vote(tokenId, _gauges(gaugeA, gaugeB), _weights(3, 1));

        (, uint128 targetB) = validatorsVoter.votes(tokenId, gaugeB);
        assertEq(targetB, 50_000 ether);
        assertEq(controller.allocationOf(tokenId, gaugeB), 0);
        assertEq(_pending(tokenId, vaultA), 50_000 ether);
        assertEq(controller.balanceOf(tokenId), 0);

        uint256 pendingBefore = _pending(tokenId, vaultA);
        uint256 agentBefore = _agentBalance(tokenId, vaultA);
        validatorsVoter.rebalance(tokenId);
        validatorsVoter.rebalance(tokenId);
        assertEq(_pending(tokenId, vaultA), pendingBefore);
        assertEq(_agentBalance(tokenId, vaultA), agentBefore);
        assertEq(controller.allocationOf(tokenId, gaugeB), 0);
    }

    function test_maturedWithdrawalIsStakedToTheLatestVote() public {
        (address vaultA, address gaugeA) = _addValidator(2);
        (address vaultB, address gaugeB) = _addValidator(3);
        uint256 tokenId = _lock(PRINCIPAL);
        _voteWindow(6);
        _vote(tokenId, _gauges(gaugeA), _weights(1));
        _voteWindow(11);
        _vote(tokenId, _gauges(gaugeA, gaugeB), _weights(3, 1));

        _mature(_agent(tokenId), StakingVault(payable(vaultA)).validatorId());
        vm.prank(stranger);
        validatorsVoter.rebalance(tokenId);

        assertEq(_pending(tokenId, vaultA), 0);
        assertEq(controller.balanceOf(tokenId), 0);
        assertEq(controller.allocationOf(tokenId, gaugeA), 150_000 ether);
        assertEq(controller.allocationOf(tokenId, gaugeB), 50_000 ether);
        assertEq(StakingVault(payable(vaultB)).balanceOf(tokenId), 50_000 ether);
        _assertBooks(tokenId, _gauges(gaugeA, gaugeB), PRINCIPAL);
    }

    function test_newVoteWhileWithdrawalIsPendingSupersedesTheOldDestination() public {
        (address vaultA, address gaugeA) = _addValidator(2);
        (, address gaugeB) = _addValidator(3);
        uint256 tokenId = _lock(PRINCIPAL);
        _voteWindow(6);
        _vote(tokenId, _gauges(gaugeA), _weights(1));
        _voteWindow(11);
        _vote(tokenId, _gauges(gaugeA, gaugeB), _weights(3, 1));
        assertEq(_pending(tokenId, vaultA), 50_000 ether);

        // The next real vote window is a later cycle, after this 1-epoch withdrawal would mature.
        // Clear the once-per-cycle lock so a new vote lands while the withdrawal is still pending.
        stdstore.target(address(validatorsVoter))
            .sig("lastVotedCycle(uint256)")
            .with_key(tokenId)
            .checked_write(uint256(0));
        _vote(tokenId, _gauges(gaugeA), _weights(1));

        (, uint128 targetA) = validatorsVoter.votes(tokenId, gaugeA);
        (, uint128 targetB) = validatorsVoter.votes(tokenId, gaugeB);
        assertEq(targetA, PRINCIPAL);
        assertEq(targetB, 0);
        assertEq(_pending(tokenId, vaultA), 50_000 ether);
        assertEq(controller.allocationOf(tokenId, gaugeA), 150_000 ether);
        assertEq(controller.allocationOf(tokenId, gaugeB), 0);

        _mature(_agent(tokenId), StakingVault(payable(vaultA)).validatorId());
        vm.prank(stranger);
        validatorsVoter.rebalance(tokenId);

        assertEq(controller.allocationOf(tokenId, gaugeA), PRINCIPAL);
        assertEq(controller.allocationOf(tokenId, gaugeB), 0);
        assertEq(_pending(tokenId, vaultA), 0);
        assertEq(controller.balanceOf(tokenId), 0);
    }

    function test_pendingWithdrawalBlocksReuseOfTheSameSlot() public {
        (address vaultA, address gaugeA) = _addValidator(2);
        (, address gaugeB) = _addValidator(3);
        uint256 tokenId = _lock(PRINCIPAL);
        _voteWindow(6);
        _vote(tokenId, _gauges(gaugeA), _weights(1));
        _voteWindow(11);
        _vote(tokenId, _gauges(gaugeA, gaugeB), _weights(3, 1));

        uint256 pendingBefore = _pending(tokenId, vaultA);
        uint256 agentBefore = _agentBalance(tokenId, vaultA);
        validatorsVoter.rebalance(tokenId);
        assertEq(_pending(tokenId, vaultA), pendingBefore);
        assertEq(_agentBalance(tokenId, vaultA), agentBefore);

        vm.expectRevert(IStakingController.InvalidUnstakeAmount.selector);
        vm.prank(address(validatorsVoter));
        controller.unstake(tokenId, _gauges(gaugeA), _amounts(1 ether));
        assertEq(_pending(tokenId, vaultA), pendingBefore);
        assertEq(_agentBalance(tokenId, vaultA), agentBefore);
    }

    function test_permissionlessCallerCanRebalanceButCannotStakeDirectly() public {
        (address vaultA, address gaugeA) = _addValidator(2);
        (, address gaugeB) = _addValidator(3);
        uint256 tokenId = _lock(PRINCIPAL);
        _voteWindow(6);
        _vote(tokenId, _gauges(gaugeA), _weights(1));
        _voteWindow(11);
        _vote(tokenId, _gauges(gaugeA, gaugeB), _weights(3, 1));
        _mature(_agent(tokenId), StakingVault(payable(vaultA)).validatorId());

        vm.prank(stranger);
        validatorsVoter.rebalance(tokenId);
        assertEq(controller.allocationOf(tokenId, gaugeB), 50_000 ether);

        vm.expectRevert(IStakingController.NotVoter.selector);
        vm.prank(stranger);
        controller.stake(tokenId, _gauges(gaugeB), _amounts(1 ether));

        vm.expectRevert(IStakingController.NotVoter.selector);
        vm.prank(stranger);
        controller.unstake(tokenId, _gauges(gaugeA), _amounts(1 ether));

        vm.expectRevert(IStakingController.NotVoter.selector);
        vm.prank(stranger);
        controller.withdraw(tokenId, _gauges(gaugeA));
    }

    function test_voteRemainsValidWhenStakeCannotMoveYet() public {
        (, address gaugeA) = _addValidator(2);
        (, address gaugeB) = _addValidator(3);
        uint256 tokenId = _lock(PRINCIPAL);
        _voteWindow(6);
        _vote(tokenId, _gauges(gaugeA), _weights(1));
        _voteWindow(11);

        _vote(tokenId, _gauges(gaugeA, gaugeB), _weights(3, 1));

        assertEq(validatorsVoter.lastVotedCycle(tokenId), 10);
        (, uint128 stakeA) = validatorsVoter.votes(tokenId, gaugeA);
        (, uint128 stakeB) = validatorsVoter.votes(tokenId, gaugeB);
        assertEq(stakeA, 150_000 ether);
        assertEq(stakeB, 50_000 ether);
        assertLt(controller.allocationOf(tokenId, gaugeB), stakeB);
        assertEq(controller.allocationOf(tokenId, gaugeA), stakeA);
    }

    function test_repeatedRebalanceConvergesWithoutOvershooting() public {
        (, address gaugeA) = _addValidator(2);
        (address vaultB, address gaugeB) = _addValidator(3);
        uint256 tokenId = _lock(100 ether);
        _voteWindow(6);
        _vote(tokenId, _gauges(gaugeA), _weights(1));
        _voteWindow(11);
        _vote(tokenId, _gauges(gaugeB), _weights(1));

        assertEq(controller.allocationOf(tokenId, gaugeA), 0);
        assertEq(controller.allocationOf(tokenId, gaugeB), 100 ether);

        uint256 liquid = controller.balanceOf(tokenId);
        uint256 onB = StakingVault(payable(vaultB)).balanceOf(tokenId);
        validatorsVoter.rebalance(tokenId);
        validatorsVoter.rebalance(tokenId);
        assertEq(controller.balanceOf(tokenId), liquid);
        assertEq(StakingVault(payable(vaultB)).balanceOf(tokenId), onB);
        assertEq(controller.allocationOf(tokenId, gaugeB), 100 ether);
        assertEq(controller.allocationOf(tokenId, gaugeA), 0);
    }

    function test_delegatedRemovalUnstakesAgentBeforeVault() public {
        (address vaultA, address gaugeA) = _addValidator(2);
        (, address gaugeB) = _addValidator(3);
        uint256 tokenId = _lock(PRINCIPAL);
        _voteWindow(6);
        _vote(tokenId, _gauges(gaugeA), _weights(1));

        _voteWindow(11);
        _vote(tokenId, _gauges(gaugeB), _weights(1));

        assertEq(controller.allocationOf(tokenId, gaugeA), 0);
        assertEq(_agentBalance(tokenId, vaultA), 0);
        assertEq(_pending(tokenId, vaultA), PRINCIPAL - validatorStake);
        assertTrue(StakingVault(payable(vaultA)).exiting());
        assertEq(StakingVault(payable(vaultA)).balanceOf(tokenId), validatorStake);
        assertEq(controller.allocationOf(tokenId, gaugeB), 0);
        _assertBooks(tokenId, _gauges(gaugeA, gaugeB), PRINCIPAL);
    }

    function _addValidator(uint256 seed) internal returns (address vault, address gauge) {
        bytes32 saltSeed = keccak256(abi.encode("rebalance-validator", seed));
        address auth = controller.predictVaultAddress(operator, saltSeed);
        bytes memory payload = abi.encodePacked(
            bytes1(0x02), bytes32(seed), blsPubkey, bytes20(auth), bytes32(validatorStake), bytes32(commission)
        );
        vm.prank(operator);
        (, vault, gauge) = validatorsVoter.createValidator(saltSeed, auth, payload, secpSig, blsSig);
    }

    function _lock(uint256 amount) internal returns (uint256 tokenId) {
        vm.prank(operator);
        tokenId = veMON.createLock{value: amount}(amount, lockDuration);
    }

    function _voteWindow(uint64 epoch) internal {
        _setEpoch(epoch, false);
    }

    function _vote(uint256 tokenId, address[] memory gauges, uint256[] memory weights_) internal {
        vm.prank(operator);
        validatorsVoter.vote(tokenId, gauges, weights_);
    }

    function _mature(address delegator, uint64 validatorId) internal {
        (,, uint64 withdrawEpoch) = staking.getWithdrawalRequest(validatorId, delegator, 0);
        _setEpoch(withdrawEpoch + 1, false);
    }

    function _agent(uint256 tokenId) internal view returns (address) {
        return controller.agentByToken(tokenId);
    }

    function _agentBalance(uint256 tokenId, address vault) internal view returns (uint256) {
        address agent = _agent(tokenId);
        if (agent == address(0)) return 0;
        uint64 validatorId = StakingVault(payable(vault)).validatorId();
        if (validatorId == 0) return 0;
        return StakingAgent(payable(agent)).balanceOf(validatorId);
    }

    function _pending(uint256 tokenId, address vault) internal view returns (uint256) {
        address agent = _agent(tokenId);
        uint64 validatorId = StakingVault(payable(vault)).validatorId();
        if (agent == address(0) || validatorId == 0) return 0;
        return StakingAgent(payable(agent)).pendingWithdrawal(validatorId);
    }

    function _assertBooks(uint256 tokenId, address[] memory gauges, uint256 principal) internal view {
        uint256 accounted = controller.balanceOf(tokenId);
        for (uint256 i; i < gauges.length; ++i) {
            StakingVault vault = StakingVault(payable(controller.vaultByGauge(gauges[i])));
            accounted += controller.allocationOf(tokenId, gauges[i]);
            if (vault.exiting()) accounted += vault.balanceOf(tokenId);
            accounted += _pending(tokenId, address(vault));
        }
        assertEq(accounted, principal);
    }

    function _gauges(address gauge) internal pure returns (address[] memory gauges) {
        gauges = new address[](1);
        gauges[0] = gauge;
    }

    function _gauges(address a, address b) internal pure returns (address[] memory gauges) {
        gauges = new address[](2);
        gauges[0] = a;
        gauges[1] = b;
    }

    function _weights(uint256 weight) internal pure returns (uint256[] memory weights_) {
        weights_ = new uint256[](1);
        weights_[0] = weight;
    }

    function _weights(uint256 a, uint256 b) internal pure returns (uint256[] memory weights_) {
        weights_ = new uint256[](2);
        weights_[0] = a;
        weights_[1] = b;
    }

    function _amounts(uint256 amount) internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](1);
        amounts[0] = amount;
    }
}
