// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IValidatorRegistry} from "../src/interfaces/IValidatorRegistry.sol";
import {ValidatorRegistryFixture} from "./fixtures/ValidatorRegistryFixture.sol";

contract ValidatorRegistryTest is ValidatorRegistryFixture {
    function test_constructorSetsReadableRegistryState() public view {
        assertEq(registry.nextId(), 1);
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

    function test_unknownSubmissionReverts() public {
        vm.expectRevert(IValidatorRegistry.UnknownSubmission.selector);
        registry.getSubmission(1);
    }
}
