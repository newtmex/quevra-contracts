// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ValidatorVoter} from "../../src/validators/ValidatorVoter.sol";
import {StakingControllerFixture} from "./StakingControllerFixture.sol";

abstract contract ValidatorVoterFixture is StakingControllerFixture {
    ValidatorVoter internal voter;
    address internal initialVault;

    function setUp() public virtual override {
        super.setUp();
        voter = new ValidatorVoter(address(registry), address(controller));
        controller.setVoter(address(voter));
        initialVault = controller.predictVaultAddress(operator, secpPubkey, blsPubkey);
    }

    function _createValidatorStack() internal returns (uint256 id, address vault, address gauge) {
        vm.prank(operator);
        return voter.createValidator(initialVault, secpPubkey, blsPubkey, secpSig, blsSig);
    }
}
