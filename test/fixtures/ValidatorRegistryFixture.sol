// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IValidatorRegistry} from "../../src/interfaces/IValidatorRegistry.sol";
import {ValidatorRegistry} from "../../src/validators/ValidatorRegistry.sol";
import {BaseTest} from "./BaseTest.sol";

abstract contract ValidatorRegistryFixture is BaseTest {
    ValidatorRegistry internal registry;
    uint256 internal requestId;

    function setUp() public virtual override {
        super.setUp();
        registry = new ValidatorRegistry();
    }

    function _requestValidator() internal returns (uint256 id) {
        vm.prank(operator);
        id = registry.requestValidator(secpPubkey, blsPubkey, secpSig, blsSig);
    }

    function _requestBoundValidator() internal returns (uint256 id) {
        id = _requestValidator();
        requestId = id;
    }

    function _assertProposalExecuted(uint256 id, address expectedExecutor, uint64 expectedValidatorId) internal view {
        IValidatorRegistry.Proposal memory proposal = registry.getProposal(id);
        assertEq(uint256(proposal.status), uint256(IValidatorRegistry.Status.Executed));
        assertEq(proposal.executor, expectedExecutor);
        assertEq(proposal.validatorId, expectedValidatorId);
    }
}
