// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MonadVm} from "monad-std/MonadVm.sol";

import {IValidatorRegistry} from "../src/interfaces/IValidatorRegistry.sol";
import {IValidatorVoter} from "../src/interfaces/IValidatorVoter.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {ValidatorGauge} from "../src/ValidatorGauge.sol";
import {ValidatorRegistry} from "../src/ValidatorRegistry.sol";
import {ValidatorVoter} from "../src/ValidatorVoter.sol";

contract ValidatorStackTest is Test {
    MonadVm internal constant monadVm = MonadVm(0xc0FFeeCD43A10e1C2b0De63c6CDCFe5B7d0e0CEA);
    ValidatorRegistry internal registry;
    ValidatorVoter internal voter;

    address internal operator = makeAddr("operator");
    bytes internal secpPubkey = hex"0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
    bytes internal blsPubkey =
        hex"97f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb";
    bytes internal secpSig = hex"1111";
    bytes internal blsSig = bytes.concat(bytes1(0x80), new bytes(95));
    uint256 internal stake = 100_000 ether;
    uint256 internal commission = 1e17;

    function setUp() public {
        registry = new ValidatorRegistry();
        voter = new ValidatorVoter(address(registry));
        monadVm.setEpoch(0, false);
        vm.deal(operator, 1_000_000 ether);
    }

    function test_createValidatorRequestsAndDeploysVaultAndGaugeAtomically() public {
        vm.prank(operator);
        (uint256 requestId, address vaultAddress, address gaugeAddress) =
            voter.createValidator(secpPubkey, blsPubkey, secpSig, blsSig);

        IValidatorVoter.ValidatorStack memory stack = voter.stackByRequest(requestId);
        assertEq(stack.vault, vaultAddress);
        assertEq(stack.gauge, gaugeAddress);
        assertEq(stack.validatorId, 0);

        StakingVault vault = StakingVault(payable(vaultAddress));
        ValidatorGauge gauge = ValidatorGauge(gaugeAddress);
        assertEq(vault.owner(), operator);
        assertEq(address(vault.registry()), address(registry));
        assertEq(vault.requestId(), requestId);
        assertEq(gauge.registry(), address(registry));
        assertEq(gauge.vault(), vaultAddress);
        assertEq(gauge.operator(), operator);
        assertEq(gauge.requestId(), requestId);
        assertEq(gauge.validatorId(), 0);
        assertEq(uint256(registry.getProposal(requestId).status), uint256(IValidatorRegistry.Status.Proposed));
    }

    function test_createValidatorRejectsInvalidDataBeforeRequestOrDeployment() public {
        vm.prank(operator);
        vm.expectRevert(IValidatorRegistry.InvalidValidatorData.selector);
        voter.createValidator(hex"01", blsPubkey, secpSig, blsSig);

        assertEq(registry.nextId(), 1);
    }

    function test_duplicateValidatorCannotCreateSecondVaultOrGauge() public {
        vm.prank(operator);
        voter.createValidator(secpPubkey, blsPubkey, secpSig, blsSig);

        vm.prank(operator);
        vm.expectRevert(IValidatorRegistry.KeyAlreadyRegistered.selector);
        voter.createValidator(secpPubkey, blsPubkey, secpSig, blsSig);
        assertEq(registry.nextId(), 2);
    }

    function test_createValidatorFailureRollsBackRequestAndDeployments() public {
        // Invalid data reverts before the registry request or CREATE operations,
        // so no request, vault, or gauge state can be left behind.
        vm.prank(operator);
        vm.expectRevert(IValidatorRegistry.InvalidValidatorData.selector);
        voter.createValidator(secpPubkey, new bytes(0), secpSig, blsSig);

        assertEq(registry.nextId(), 1);
        IValidatorVoter.ValidatorStack memory stack = voter.stackByRequest(1);
        assertEq(stack.vault, address(0));
    }

    function test_onlyOperatorCanCancelThroughVoterAndDirectRegistryCancelIsBlocked() public {
        vm.prank(operator);
        (uint256 requestId,,) = voter.createValidator(secpPubkey, blsPubkey, secpSig, blsSig);

        vm.prank(operator);
        vm.expectRevert(IValidatorRegistry.NotOperator.selector);
        registry.cancel(requestId);

        vm.prank(address(this));
        vm.expectRevert(IValidatorVoter.NotRequestOperator.selector);
        voter.cancel(requestId);

        vm.prank(operator);
        voter.cancel(requestId);
        assertEq(uint256(registry.getProposal(requestId).status), uint256(IValidatorRegistry.Status.Cancelled));
        assertEq(voter.stackByRequest(requestId).vault, address(0));
    }
}
