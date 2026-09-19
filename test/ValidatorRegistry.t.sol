// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IValidatorRegistry} from "../src/interfaces/IValidatorRegistry.sol";
import {ValidatorRegistryFixture} from "./fixtures/ValidatorRegistryFixture.sol";

contract ValidatorRegistryTest is ValidatorRegistryFixture {
    function test_constructorSetsReadableRegistryState() public view {
        assertEq(registry.nextId(), 1);
        assertEq(address(registry.staking()), address(staking));
    }

    function test_requestValidatorStoresPendingRequest() public {
        vm.expectEmit(true, true, false, true);
        emit IValidatorRegistry.ValidatorRequested(1, operator, secpPubkey, blsPubkey);

        uint256 id = _requestValidator();

        IValidatorRegistry.Proposal memory proposal = registry.getProposal(id);
        assertEq(id, 1);
        assertEq(registry.nextId(), 2);
        assertEq(proposal.secpPubkey, secpPubkey);
        assertEq(proposal.blsPubkey, blsPubkey);
        assertEq(proposal.signedSecpMessage, secpSig);
        assertEq(proposal.signedBlsMessage, blsSig);
        assertEq(proposal.operator, operator);
        assertEq(proposal.executor, address(0));
        assertEq(proposal.validatorId, 0);
        assertEq(uint256(proposal.status), uint256(IValidatorRegistry.Status.Proposed));
        assertEq(registry.idBySecpPubkey(keccak256(secpPubkey)), id);
        assertEq(registry.idByBlsPubkey(keccak256(blsPubkey)), id);
    }

    function test_requestValidatorRejectsInvalidValidatorData() public {
        bytes memory validSecp = new bytes(33);
        bytes memory validBls = new bytes(48);
        bytes memory validSecpSig = hex"040506";
        bytes memory validBlsSig = hex"0708090a";

        vm.prank(operator);
        vm.expectRevert(IValidatorRegistry.InvalidValidatorData.selector);
        registry.requestValidator(new bytes(0), validBls, validSecpSig, validBlsSig);

        vm.prank(operator);
        vm.expectRevert(IValidatorRegistry.InvalidValidatorData.selector);
        registry.requestValidator(validSecp, new bytes(0), validSecpSig, validBlsSig);
    }

    function test_requestValidatorRevertsOnDuplicateKeys() public {
        _requestValidator();

        vm.prank(operator);
        vm.expectRevert(IValidatorRegistry.KeyAlreadyRegistered.selector);
        registry.requestValidator(secpPubkey, blsPubkey, secpSig, blsSig);
    }

    function test_stakingPayloadReconstructsCallerSuppliedEconomics() public {
        uint256 id = _requestValidator();

        bytes memory payload = registry.stakingPayload(id, executor, validatorStake, commission);

        assertEq(payload.length, 165);
        assertEq(payload, bytes.concat(secpPubkey, blsPubkey, abi.encodePacked(executor, validatorStake, commission)));
    }

    function test_anyoneCanAddValidatorWithCallerEconomics() public {
        uint256 id = _requestValidator();

        vm.prank(executor);
        uint64 validatorId = registry.addValidator{value: validatorStake}(id, commission);

        _assertProposalExecuted(id, executor, validatorId);
        assertGt(validatorId, 0);
        assertEq(_validatorAuth(validatorId), executor);
    }

    function test_cancelFreesKeys() public {
        uint256 id = _requestValidator();

        vm.prank(operator);
        registry.cancel(id);

        uint256 newId = _requestValidator();
        assertEq(newId, 2);
        assertEq(uint256(registry.getProposal(id).status), uint256(IValidatorRegistry.Status.Cancelled));
    }

    function test_cancelRevertsIfNotOperator() public {
        uint256 id = _requestValidator();

        vm.prank(executor);
        vm.expectRevert(IValidatorRegistry.NotOperator.selector);
        registry.cancel(id);
    }

    function test_addValidatorRevertsAfterCancellation() public {
        uint256 id = _requestValidator();

        vm.prank(operator);
        registry.cancel(id);

        vm.prank(executor);
        vm.expectRevert(IValidatorRegistry.NotProposed.selector);
        registry.addValidator{value: validatorStake}(id, commission);
    }

    function test_unknownProposalReverts() public {
        vm.expectRevert(IValidatorRegistry.UnknownProposal.selector);
        registry.getProposal(1);

        vm.expectRevert(IValidatorRegistry.UnknownProposal.selector);
        registry.stakingPayload(1, executor, validatorStake, commission);
    }
}
