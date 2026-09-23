// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StakingAgent} from "../src/staking/controlled/StakingAgent.sol";
import {StakeControlled} from "../src/staking/controlled/StakeControlled.sol";
import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";
import {StakingAgentFixture} from "./fixtures/StakingAgentFixture.sol";

contract StakingAgentTest is StakingAgentFixture {
    receive() external payable {}

    function test_constructorSetsController() public view {
        assertEq(agent.controller(), address(this));
    }

    function test_onlyControllerCanCallActions() public {
        uint64[] memory ids = _ids(validatorA);
        uint256[] memory amounts = _amounts(1 ether);

        vm.prank(stranger);
        vm.expectRevert(StakeControlled.OnlyController.selector);
        agent.delegate{value: 1 ether}(ids, amounts);

        vm.prank(stranger);
        vm.expectRevert(StakeControlled.OnlyController.selector);
        agent.undelegate(ids, amounts);

        vm.prank(stranger);
        vm.expectRevert(StakeControlled.OnlyController.selector);
        agent.withdraw(ids);
    }

    function test_delegateValidatesArraysAndAmounts() public {
        uint64[] memory ids = new uint64[](0);
        uint256[] memory amounts = new uint256[](0);
        vm.expectRevert(StakingAgent.EmptyArray.selector);
        agent.delegate(ids, amounts);

        ids = _ids(validatorA, validatorB);
        amounts = _amounts(1 ether);
        vm.expectRevert(StakingAgent.LengthMismatch.selector);
        agent.delegate{value: 1 ether}(ids, amounts);

        ids = _ids(validatorA);
        amounts = _amounts(0);
        vm.expectRevert(StakingAgent.ZeroAmount.selector);
        agent.delegate(ids, amounts);

        amounts = _amounts(1 ether);
        vm.mockCall(address(staking), abi.encodeCall(IMonadStaking.delegate, (validatorA)), abi.encode(true));
        vm.expectRevert(StakingAgent.ValueMismatch.selector);
        agent.delegate{value: 2 ether}(ids, amounts);
    }

    function test_delegateDistributesExactValueAcrossValidators() public {
        uint64[] memory ids = _ids(validatorA, validatorB);
        uint256[] memory amounts = _amounts(1 ether, 2 ether);
        vm.mockCall(address(staking), abi.encodeCall(IMonadStaking.delegate, (validatorA)), abi.encode(true));
        vm.mockCall(address(staking), abi.encodeCall(IMonadStaking.delegate, (validatorB)), abi.encode(true));
        vm.expectCall(address(staking), 1 ether, abi.encodeCall(IMonadStaking.delegate, (validatorA)));
        vm.expectCall(address(staking), 2 ether, abi.encodeCall(IMonadStaking.delegate, (validatorB)));

        agent.delegate{value: 3 ether}(ids, amounts);

        assertEq(address(agent).balance, 0);
        assertEq(agent.balanceOf(validatorA), 1 ether);
        assertEq(agent.balanceOf(validatorB), 2 ether);
    }

    function test_undelegateValidatesArraysAndAmounts() public {
        uint64[] memory ids = new uint64[](0);
        uint256[] memory amounts = new uint256[](0);
        vm.expectRevert(StakingAgent.EmptyArray.selector);
        agent.undelegate(ids, amounts);

        ids = _ids(validatorA, validatorB);
        amounts = _amounts(1 ether);
        vm.expectRevert(StakingAgent.LengthMismatch.selector);
        agent.undelegate(ids, amounts);

        ids = _ids(validatorA);
        amounts = _amounts(0);
        vm.expectRevert(StakingAgent.ZeroAmount.selector);
        agent.undelegate(ids, amounts);
    }

    function test_undelegateMultipleValidatorsAlwaysUsesSlotZero() public {
        uint64[] memory ids = _ids(validatorA, validatorB);
        uint256[] memory amounts = _amounts(3 ether, 4 ether);
        vm.deal(address(agent), 7 ether);
        vm.mockCall(address(staking), abi.encodeCall(IMonadStaking.delegate, (validatorA)), abi.encode(true));
        vm.mockCall(address(staking), abi.encodeCall(IMonadStaking.delegate, (validatorB)), abi.encode(true));
        agent.delegate{value: 7 ether}(ids, amounts);
        vm.mockCall(
            address(staking), abi.encodeCall(IMonadStaking.undelegate, (validatorA, 3 ether, 0)), abi.encode(true)
        );
        vm.mockCall(
            address(staking), abi.encodeCall(IMonadStaking.undelegate, (validatorB, 4 ether, 0)), abi.encode(true)
        );
        vm.expectCall(address(staking), abi.encodeCall(IMonadStaking.undelegate, (validatorA, 3 ether, 0)));
        vm.expectCall(address(staking), abi.encodeCall(IMonadStaking.undelegate, (validatorB, 4 ether, 0)));

        agent.undelegate(ids, amounts);
        assertEq(agent.balanceOf(validatorA), 0);
        assertEq(agent.balanceOf(validatorB), 0);
        assertEq(agent.pendingWithdrawal(validatorA), 3 ether);
        assertEq(agent.pendingWithdrawal(validatorB), 4 ether);
    }

    function test_undelegateReliesOnMonadToRejectAnOccupiedWithdrawalSlot() public {
        uint64[] memory ids = _ids(validatorA);
        uint256[] memory amounts = _amounts(1 ether);
        vm.deal(address(agent), 1 ether);
        vm.mockCall(address(staking), abi.encodeCall(IMonadStaking.delegate, (validatorA)), abi.encode(true));
        agent.delegate{value: 1 ether}(ids, amounts);
        vm.mockCall(
            address(staking), abi.encodeCall(IMonadStaking.undelegate, (validatorA, 1 ether, 0)), abi.encode(false)
        );

        vm.expectRevert(StakingAgent.StakingCallFailed.selector);
        agent.undelegate(ids, amounts);
    }

    function test_withdrawCallsSlotZeroAndForwardsAllMONToController() public {
        uint64[] memory ids = _ids(validatorA, validatorB);
        vm.mockCall(address(staking), abi.encodeCall(IMonadStaking.withdraw, (validatorA, 0)), abi.encode(true));
        vm.mockCall(address(staking), abi.encodeCall(IMonadStaking.withdraw, (validatorB, 0)), abi.encode(true));
        vm.expectCall(address(staking), abi.encodeCall(IMonadStaking.withdraw, (validatorA, 0)));
        vm.expectCall(address(staking), abi.encodeCall(IMonadStaking.withdraw, (validatorB, 0)));
        vm.deal(address(agent), 5 ether);

        uint256 beforeBalance = address(this).balance;
        agent.withdraw(ids);

        assertEq(address(this).balance, beforeBalance + 5 ether);
        assertEq(address(agent).balance, 0);
        assertEq(agent.balanceOf(validatorA), 0);
        assertEq(agent.balanceOf(validatorB), 0);
        assertEq(agent.pendingWithdrawal(validatorA), 0);
        assertEq(agent.pendingWithdrawal(validatorB), 0);
    }

    function test_unstakeFlowUndelegatesBeforeLaterWithdraw() public {
        uint64[] memory ids = _ids(validatorA);
        uint256[] memory amounts = _amounts(3 ether);

        vm.mockCall(
            address(staking), abi.encodeCall(IMonadStaking.undelegate, (validatorA, 3 ether, 0)), abi.encode(true)
        );
        vm.mockCall(address(staking), abi.encodeCall(IMonadStaking.delegate, (validatorA)), abi.encode(true));
        agent.delegate{value: 3 ether}(ids, amounts);
        vm.mockCall(address(staking), abi.encodeCall(IMonadStaking.withdraw, (validatorA, 0)), abi.encode(true));
        vm.deal(address(agent), 3 ether);

        // The controller first submits the undelegation. No MON is redeemed yet.
        agent.undelegate(ids, amounts);
        assertEq(address(agent).balance, 3 ether);
        assertEq(agent.balanceOf(validatorA), 0);
        assertEq(agent.pendingWithdrawal(validatorA), 3 ether);

        // Withdrawal is a separate later operation, after Monad's epoch delay.
        uint256 beforeBalance = address(this).balance;
        agent.withdraw(ids);
        assertEq(address(this).balance, beforeBalance + 3 ether);
        assertEq(address(agent).balance, 0);
        assertEq(agent.pendingWithdrawal(validatorA), 0);
    }

    function test_withdrawRejectsEmptyArray() public {
        vm.expectRevert(StakingAgent.EmptyArray.selector);
        agent.withdraw(new uint64[](0));
    }

    function _ids(uint64 a) internal pure returns (uint64[] memory values) {
        values = new uint64[](1);
        values[0] = a;
    }

    function _ids(uint64 a, uint64 b) internal pure returns (uint64[] memory values) {
        values = new uint64[](2);
        values[0] = a;
        values[1] = b;
    }

    function _amounts(uint256 a) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = a;
    }

    function _amounts(uint256 a, uint256 b) internal pure returns (uint256[] memory values) {
        values = new uint256[](2);
        values[0] = a;
        values[1] = b;
    }
}
