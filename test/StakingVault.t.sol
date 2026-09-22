// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";

import {IValidatorRegistry} from "../src/interfaces/IValidatorRegistry.sol";
import {StakingVault} from "../src/staking/StakingVault.sol";
import {StakeControlled} from "../src/staking/StakeControlled.sol";
import {StakingVaultFixture} from "./fixtures/StakingVaultFixture.sol";

contract StakingVaultTest is StakingVaultFixture {
    function test_initializeBindsOwnerRegistryRequestAndStakingPrecompile() public view {
        assertEq(vault.controller(), owner);
        assertEq(address(vault.registry()), address(registry));
        assertEq(vault.requestId(), requestId);
        assertEq(vault.validatorId(), 0);
    }

    function test_initializeRejectsInvalidRegistryOrRequest() public {
        StakingVault implementation = new StakingVault();
        StakingVault clone = StakingVault(payable(Clones.clone(address(implementation))));
        vm.expectRevert(StakingVault.InvalidRequest.selector);
        clone.initialize(address(0), requestId);
        vm.expectRevert(StakingVault.InvalidRequest.selector);
        clone.initialize(address(registry), 0);
        vm.prank(stranger);
        vm.expectRevert(StakeControlled.OnlyController.selector);
        clone.initialize(address(registry), requestId);
        clone.initialize(address(registry), requestId);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        clone.initialize(address(registry), requestId);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(registry), requestId);
    }

    function test_depositExecutesBoundRegistryRequestFromVaultAtMinimumStake() public {
        vm.expectEmit(true, true, false, false, address(registry));
        emit IValidatorRegistry.ValidatorAdded(requestId, address(vault), 0, address(vault), validatorStake, commission);

        uint64 validatorId = _addVaultValidator();

        assertGt(validatorId, 0);
        assertEq(vault.validatorId(), validatorId);
        _assertSubmissionExecuted(requestId, address(vault), validatorId);
        _assertValidator(validatorId);
    }

    function test_depositIsControllerOnlyAndRejectsOverfundingAfterActivation() public {
        vm.prank(stranger);
        vm.expectRevert(StakeControlled.OnlyController.selector);
        vault.deposit{value: validatorStake}(0);

        _addVaultValidator();

        vm.prank(owner);
        vm.expectRevert(StakingVault.InvalidAmount.selector);
        vault.deposit{value: 1}(0);
    }

    function test_depositAfterActivationIsRejected() public {
        _addVaultValidator();

        vm.prank(owner);
        vm.expectRevert(StakingVault.InvalidAmount.selector);
        vault.deposit{value: delegationAmount}(1);
    }

    function test_depositCanAccumulateBeforeActivation() public {
        vm.prank(owner);
        vault.deposit{value: delegationAmount}(1);

        assertEq(vault.balanceOf(1), delegationAmount);
        assertEq(vault.totalBalance(), delegationAmount);
        assertEq(vault.validatorId(), 0);
    }

    function _assertValidator(uint64 validatorId) internal {
        (address authAddress, uint256 storedCommission) = _validatorIdentity(validatorId);
        uint256 snapshotStake = _validatorStake(validatorId);

        assertEq(authAddress, address(vault));
        assertEq(snapshotStake, validatorStake);
        assertEq(storedCommission, commission);
    }

    function _assertDelegation(uint64 validatorId) internal {
        (uint256 stake, uint256 deltaStake, uint256 nextDeltaStake, uint64 deltaEpoch, uint64 nextDeltaEpoch) =
            _delegatorPosition(validatorId);

        assertEq(stake + deltaStake + nextDeltaStake, validatorStake + delegationAmount);
        assertTrue(deltaEpoch != 0 || nextDeltaEpoch != 0 || stake == validatorStake + delegationAmount);
    }
}
