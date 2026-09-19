// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";

import {IValidatorRegistry} from "../src/interfaces/IValidatorRegistry.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {StakingVaultFixture} from "./fixtures/StakingVaultFixture.sol";

contract StakingVaultTest is StakingVaultFixture {
    function test_initializeBindsOwnerRegistryRequestAndStakingPrecompile() public view {
        assertEq(vault.owner(), owner);
        assertEq(address(vault.registry()), address(registry));
        assertEq(address(vault.staking()), address(staking));
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
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        clone.initialize(address(registry), requestId);
        clone.initialize(address(registry), requestId);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        clone.initialize(address(registry), requestId);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(registry), requestId);
    }

    function test_addValidatorExecutesBoundRegistryRequestFromVault() public {
        vm.expectEmit(true, true, false, false, address(registry));
        emit IValidatorRegistry.ValidatorAdded(requestId, address(vault), 0, address(vault), validatorStake, commission);

        uint64 validatorId = _addVaultValidator();

        assertGt(validatorId, 0);
        assertEq(vault.validatorId(), validatorId);
        _assertProposalExecuted(requestId, address(vault), validatorId);
        _assertValidator(validatorId);
    }

    function test_addValidatorIsOwnerOnlyAndCanOnlyRunOnce() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.addValidator{value: validatorStake}(commission);

        _addVaultValidator();

        vm.prank(owner);
        vm.expectRevert(StakingVault.ValidatorAlreadyAdded.selector);
        vault.addValidator{value: validatorStake}(commission);
    }

    function test_delegateSendsOwnerFundsToVaultValidator() public {
        uint64 validatorId = _addVaultValidator();

        vm.expectEmit(true, true, false, false, address(staking));
        emit IMonadStaking.Delegate(validatorId, address(vault), delegationAmount, 0);

        vm.prank(owner);
        bool success = vault.delegate{value: delegationAmount}();

        assertTrue(success);
        _assertDelegation(validatorId);
    }

    function test_delegateRequiresOwnerAndAddedValidator() public {
        vm.prank(owner);
        vm.expectRevert(StakingVault.ValidatorNotAdded.selector);
        vault.delegate{value: delegationAmount}();

        _addVaultValidator();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.delegate{value: delegationAmount}();
    }

    function _assertValidator(uint64 validatorId) internal {
        (address authAddress, uint256 stake, uint256 storedCommission) = _validatorBasics(validatorId);

        assertEq(authAddress, address(vault));
        assertEq(stake, validatorStake);
        assertEq(storedCommission, commission);
    }

    function _assertDelegation(uint64 validatorId) internal {
        (uint256 stake, uint256 deltaStake, uint256 nextDeltaStake, uint64 deltaEpoch, uint64 nextDeltaEpoch) =
            _delegatorPosition(validatorId);

        assertEq(stake + deltaStake + nextDeltaStake, validatorStake + delegationAmount);
        assertTrue(deltaEpoch != 0 || nextDeltaEpoch != 0 || stake == validatorStake + delegationAmount);
    }
}
