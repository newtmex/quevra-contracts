// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {StakingController} from "../src/staking/StakingController.sol";
import {IStakingController} from "../src/interfaces/IStakingController.sol";
import {StakingControllerFixture} from "./fixtures/StakingControllerFixture.sol";
import {StakingAgent} from "../src/staking/controlled/StakingAgent.sol";
import {StakingVault} from "../src/staking/controlled/StakingVault.sol";
import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";

contract StakingControllerTest is StakingControllerFixture {
    function test_constructorSetsRegistryAndImplementations() public view {
        assertEq(address(controller.registry()), address(registry));
        assertEq(controller.owner(), address(this));
        assertTrue(address(veMON) != address(controller));
        assertTrue(controller.vaultImplementation() != address(0));
        assertTrue(controller.agentImplementation() != address(0));
    }

    function test_predictAgentAddressIsDeterministicAndTokenBound() public view {
        address first = controller.predictAgentAddress(1);
        address second = controller.predictAgentAddress(2);

        assertTrue(first != second);
        assertEq(first, controller.predictAgentAddress(1));
        assertEq(second, controller.predictAgentAddress(2));
    }

    function test_constructorSetsInitialCommissionImmediately() public {
        StakingController configured = new StakingController(address(registry), address(this), commission);
        assertEq(configured.commission(), commission);
    }

    function test_constructorRejectsCommissionAboveMaximum() public {
        vm.expectRevert(IStakingController.InvalidCommission.selector);
        new StakingController(address(registry), address(this), 1e18 + 1);
    }

    function test_veIsOwnerSetOnce() public {
        StakingController configured = new StakingController(address(registry), address(this), 0);
        address replacement = makeAddr("replacement-ve");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        vm.prank(operator);
        configured.setVe(address(veMON));

        configured.setVe(address(veMON));

        vm.expectRevert(IStakingController.VeAlreadySet.selector);
        configured.setVe(replacement);
    }

    function test_onlyOwnerCanSetCommission() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        vm.prank(operator);
        controller.setCommission(commission);

        vm.expectEmit(false, false, false, true);
        emit IStakingController.ValidatorCommissionScheduled(commission, 2);
        _setCommission();

        assertEq(controller.commission(), 0);
    }

    function test_setCommissionEnforcesPrecompileMaximum() public {
        controller.setCommission(controller.MAX_COMMISSION());
        assertEq(controller.commission(), 0);

        uint256 invalidCommission = controller.MAX_COMMISSION() + 1;
        vm.expectRevert(IStakingController.InvalidCommission.selector);
        controller.setCommission(invalidCommission);
    }

    function test_scheduledCommissionTakesEffectAtCyclePlusTwo() public {
        _setEpoch(9, false);
        controller.setCommission(commission);
        assertEq(controller.commission(), 0);

        _setEpoch(14, false);
        assertEq(controller.commission(), 0);
        _setEpoch(15, false);
        assertEq(controller.commission(), commission);
        assertEq(controller.commission(), commission);
    }

    function test_signingConfigForUsesFixedStakeAmount() public {
        bytes32 saltSeed = keccak256("controller-test");
        (address authAddress, uint256 configuredCommission, uint256 amount) =
            controller.signingConfigFor(operator, saltSeed);

        assertEq(authAddress, controller.predictVaultAddress(operator, saltSeed));
        assertEq(configuredCommission, 0);
        assertEq(amount, controller.VALIDATOR_STAKE_AMOUNT());
    }

    function test_depositOnlyAcceptsMONFromVeMONAndTracksTokenId() public {
        vm.prank(operator);
        (bool success,) = address(controller).call{value: validatorStake}("");
        assertFalse(success);

        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);
        assertEq(address(controller).balance, validatorStake);
        assertEq(controller.balanceOf(1), validatorStake);
    }
}

contract StakingControllerUnstakeTest is StakingControllerFixture {
    function test_stakeThenUnstakeAndWithdrawRestoresMONWithoutMocks() public {
        bytes32 saltSeed = keccak256("validator-0");
        address expectedAuthAddress = controller.predictVaultAddress(operator, saltSeed);
        bytes memory payload = abi.encodePacked(
            secpPubkey, blsPubkey, bytes20(expectedAuthAddress), bytes32(validatorStake), bytes32(commission)
        );
        vm.prank(operator);
        uint256 requestId = registry.requestValidator(payload, secpSig, blsSig);
        address gauge = makeAddr("gauge-0");
        vm.prank(operator);
        controller.deployVault(requestId, operator, saltSeed, expectedAuthAddress, gauge);
        uint256 amount = validatorStake;

        vm.prank(operator);
        veMON.createLock{value: amount}(amount, lockDuration);

        address[] memory gauges = new address[](1);
        gauges[0] = gauge;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.prank(operator);
        controller.stake(1, gauges, amounts);
        assertEq(controller.balanceOf(1), 0);

        // Validator activation/delegation becomes an active stake at the next epoch.
        _setEpoch(1, false);
        vm.prank(operator);
        controller.unstake(1, gauges, amounts);

        // Read the actual maturity epoch instead of assuming a fixed delay.
        address vault = controller.vaultByGauge(gauge);
        uint64 validatorId = StakingVault(payable(vault)).validatorId();
        (,, uint64 withdrawEpoch) = staking.getWithdrawalRequest(validatorId, vault, 0);
        _setEpoch(withdrawEpoch + 1, false);
        uint256 beforeOwnerBalance = operator.balance;
        vm.prank(operator);
        veMON.withdraw(1);

        assertEq(controller.balanceOf(1), 0);
        assertEq(operator.balance, beforeOwnerBalance + amount);
        assertEq(veMON.balanceOf(operator), 0);
    }

    function test_agentLifecycleReturnsTokenValueThroughController() public {
        bytes32 saltSeed = keccak256("validator-agent");
        address expectedAuthAddress = controller.predictVaultAddress(operator, saltSeed);
        bytes memory payload = abi.encodePacked(
            secpPubkey, blsPubkey, bytes20(expectedAuthAddress), bytes32(validatorStake), bytes32(commission)
        );
        vm.prank(operator);
        uint256 requestId = registry.requestValidator(payload, secpSig, blsSig);
        address gauge = makeAddr("gauge-agent");
        vm.prank(operator);
        controller.deployVault(requestId, operator, saltSeed, expectedAuthAddress, gauge);

        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);
        address[] memory gauges = new address[](1);
        gauges[0] = gauge;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = validatorStake;
        vm.prank(operator);
        controller.stake(1, gauges, amounts);

        _setEpoch(1, false);
        uint256 agentAmount = delegationAmount;
        vm.prank(operator);
        veMON.createLock{value: agentAmount}(agentAmount, lockDuration);
        amounts[0] = agentAmount;
        vm.prank(operator);
        controller.stake(2, gauges, amounts);

        address vault = controller.vaultByGauge(gauge);
        uint64 validatorId = StakingVault(payable(vault)).validatorId();
        StakingAgent agent = StakingAgent(payable(controller.agentByToken(2)));
        assertEq(address(agent), controller.predictAgentAddress(2));
        assertEq(controller.balanceOf(2), 0);
        assertEq(agent.balanceOf(validatorId), agentAmount);
        assertEq(controller.allocationOf(2, gauge), agentAmount);

        // The agent delegation activates one epoch after the controller stakes it.
        _setEpoch(2, false);
        vm.prank(operator);
        controller.unstake(2, gauges, amounts);
        assertEq(agent.balanceOf(validatorId), 0);
        assertEq(agent.pendingWithdrawal(validatorId), agentAmount);
        assertEq(controller.pendingOf(2, gauge), agentAmount);

        (,, uint64 withdrawEpoch) = staking.getWithdrawalRequest(validatorId, address(agent), 0);
        _setEpoch(withdrawEpoch + 1, false);
        uint256 beforeOwnerBalance = operator.balance;
        vm.prank(operator);
        veMON.withdraw(2);

        assertEq(agent.pendingWithdrawal(validatorId), 0);
        assertEq(controller.pendingOf(2, gauge), 0);
        assertEq(controller.balanceOf(2), 0);
        assertEq(operator.balance, beforeOwnerBalance + agentAmount);
        assertEq(veMON.balanceOf(operator), 1);
    }

    function test_mixedStakeRepeatedUnstakeCreditsControllerAndOwner() public {
        bytes32 saltSeed = keccak256("validator-mixed");
        address expectedAuthAddress = controller.predictVaultAddress(operator, saltSeed);
        bytes memory payload = abi.encodePacked(
            secpPubkey, blsPubkey, bytes20(expectedAuthAddress), bytes32(validatorStake), bytes32(commission)
        );
        vm.prank(operator);
        uint256 requestId = registry.requestValidator(payload, secpSig, blsSig);
        address gauge = makeAddr("gauge-mixed");
        vm.prank(operator);
        controller.deployVault(requestId, operator, saltSeed, expectedAuthAddress, gauge);

        uint256 total = validatorStake + delegationAmount;
        vm.prank(operator);
        veMON.createLock{value: total}(total, lockDuration);
        address[] memory gauges = new address[](1);
        gauges[0] = gauge;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = total;

        vm.prank(operator);
        controller.stake(1, gauges, amounts);

        address vault = controller.vaultByGauge(gauge);
        uint64 validatorId = StakingVault(payable(vault)).validatorId();
        StakingAgent agent = StakingAgent(payable(controller.agentByToken(1)));
        assertEq(controller.balanceOf(1), 0);
        assertEq(StakingVault(payable(vault)).balanceOf(1), validatorStake);
        assertEq(agent.balanceOf(validatorId), delegationAmount);

        _setEpoch(1, false);
        amounts[0] = delegationAmount;
        vm.prank(operator);
        controller.unstake(1, gauges, amounts);
        assertEq(controller.balanceOf(1), 0);
        assertEq(agent.balanceOf(validatorId), 0);
        assertEq(agent.pendingWithdrawal(validatorId), delegationAmount);

        (,, uint64 agentWithdrawEpoch) = staking.getWithdrawalRequest(validatorId, address(agent), 0);
        _setEpoch(agentWithdrawEpoch + 1, false);
        amounts[0] = validatorStake;
        vm.prank(operator);
        controller.unstake(1, gauges, amounts);

        assertEq(controller.balanceOf(1), delegationAmount);
        assertEq(agent.pendingWithdrawal(validatorId), 0);
        assertEq(StakingVault(payable(vault)).balanceOf(1), 0);
        assertEq(StakingVault(payable(vault)).pendingWithdrawal(1), validatorStake);

        (,, uint64 vaultWithdrawEpoch) = staking.getWithdrawalRequest(validatorId, vault, 0);
        _setEpoch(vaultWithdrawEpoch + 1, false);
        uint256 beforeOwnerBalance = operator.balance;
        vm.prank(operator);
        veMON.withdraw(1);
        assertEq(controller.balanceOf(1), 0);
        assertEq(operator.balance, beforeOwnerBalance + total);
        assertEq(veMON.balanceOf(operator), 0);
    }
}
