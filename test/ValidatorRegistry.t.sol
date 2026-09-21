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
        emit IValidatorRegistry.ValidatorRequested(1, operator, validatorPayload);

        uint256 id = _requestValidator();

        IValidatorRegistry.Submission memory submission = registry.getSubmission(id);
        assertEq(id, 1);
        assertEq(registry.nextId(), 2);
        assertEq(submission.payload, validatorPayload);
        assertEq(submission.signedSecpMessage, secpSig);
        assertEq(submission.signedBlsMessage, blsSig);
        assertEq(submission.operator, operator);
        assertEq(submission.executor, address(0));
        assertEq(submission.validatorId, 0);
        assertEq(uint256(submission.status), uint256(IValidatorRegistry.Status.Submitted));
    }

    function test_requestValidatorRejectsInvalidValidatorData() public {
        bytes memory validSecpSig = hex"040506";
        bytes memory validBlsSig = hex"0708090a";

        vm.prank(operator);
        vm.expectRevert(IValidatorRegistry.InvalidValidatorData.selector);
        registry.requestValidator(new bytes(0), validSecpSig, validBlsSig);

        vm.prank(operator);
        vm.expectRevert(IValidatorRegistry.InvalidValidatorData.selector);
        registry.requestValidator(bytes.concat(validatorPayload, bytes1(0)), validSecpSig, validBlsSig);
    }

    function test_stakingPayloadReturnsOpaqueSubmittedPayload() public {
        uint256 id = _requestValidator();

        bytes memory payload = registry.stakingPayload(id);

        assertEq(payload.length, 165);
        assertEq(payload, validatorPayload);
    }

    function test_anyoneCanAddValidatorWithSignedPayload() public {
        uint256 id = _requestValidator();

        vm.prank(executor);
        uint64 validatorId = registry.addValidator{value: validatorStake}(id);

        _assertSubmissionExecuted(id, executor, validatorId);
        assertGt(validatorId, 0);
        (address authAddress,) = _validatorIdentity(validatorId);
        assertEq(authAddress, address(0x1234));
    }

    function test_cancelAllowsNewSubmission() public {
        uint256 id = _requestValidator();

        vm.prank(operator);
        registry.cancel(id);

        uint256 newId = _requestValidator();
        assertEq(newId, 2);
        assertEq(uint256(registry.getSubmission(id).status), uint256(IValidatorRegistry.Status.Cancelled));
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
        vm.expectRevert(IValidatorRegistry.NotSubmitted.selector);
        registry.addValidator{value: validatorStake}(id);
    }

    function test_unknownSubmissionReverts() public {
        vm.expectRevert(IValidatorRegistry.UnknownSubmission.selector);
        registry.getSubmission(1);

        vm.expectRevert(IValidatorRegistry.UnknownSubmission.selector);
        registry.stakingPayload(1);
    }
}
