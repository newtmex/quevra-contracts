// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {StakingController} from "../src/staking/StakingController.sol";
import {StakingControllerFixture} from "./fixtures/StakingControllerFixture.sol";
import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";

contract StakingControllerTest is StakingControllerFixture {
    function test_constructorDeploysVeMONAndVaultImplementation() public view {
        assertEq(address(controller.registry()), address(registry));
        assertEq(controller.owner(), address(this));
        assertEq(address(controller.veMON()), address(veMON));
        assertTrue(controller.vaultImplementation() != address(0));
    }

    function test_voterIsOwnerSetOnce() public {
        address voter = makeAddr("voter");
        address replacement = makeAddr("replacement-voter");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        vm.prank(operator);
        controller.setVoter(voter);

        controller.setVoter(voter);

        vm.expectRevert(StakingController.VoterAlreadySet.selector);
        controller.setVoter(replacement);
    }

    function test_onlyOwnerCanSetValidatorConfig() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        vm.prank(operator);
        controller.setValidatorConfig(validatorStake, commission);

        _setValidatorConfig();

        assertEq(controller.validatorAmount(), validatorStake);
        assertEq(controller.commission(), commission);
    }

    function test_validatorStakeBufferIsOwnerConfiguredAndEmitsChange() public {
        vm.expectEmit(false, false, false, true);
        emit StakingController.ValidatorStakeBufferSet(0, 2_000 ether);
        controller.setValidatorStakeBuffer(2_000 ether);
        assertEq(controller.validatorStakeBuffer(), 2_000 ether);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        controller.setValidatorStakeBuffer(3_000 ether);
    }

    function test_capacityUsesPoolSizeLiveTopSetFloorAndBuffer() public {
        uint256 pool = 25_000_000 ether;
        vm.deal(address(controller), pool);
        vm.mockCall(
            address(staking),
            abi.encodeWithSelector(IMonadStaking.getSnapshotValidatorSet.selector, uint32(0)),
            abi.encode(true, uint32(0), new uint64[](0))
        );
        assertEq(controller.maxAdmissibleValidators(), 2);

        uint64[] memory active = new uint64[](1);
        active[0] = 1;
        vm.mockCall(
            address(staking),
            abi.encodeWithSelector(IMonadStaking.getSnapshotValidatorSet.selector, uint32(0)),
            abi.encode(true, uint32(1), active)
        );
        uint256 liveFloor = 12_000_000 ether;
        vm.mockCall(
            address(staking),
            abi.encodeWithSelector(IMonadStaking.getValidator.selector, uint64(1)),
            abi.encode(
                address(1),
                uint64(0),
                liveFloor,
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0),
                liveFloor,
                uint256(0),
                bytes(""),
                bytes("")
            )
        );
        assertEq(controller.targetStake(), liveFloor);
        controller.setValidatorStakeBuffer(2_000_000 ether);
        assertEq(controller.targetStake(), liveFloor + 2_000_000 ether);
        assertEq(controller.maxAdmissibleValidators(), 1);
        vm.clearMockedCalls();
    }

    function test_receiveOnlyAcceptsMONFromVeMON() public {
        vm.prank(operator);
        (bool success,) = address(controller).call{value: validatorStake}("");
        assertFalse(success);
    }
}
