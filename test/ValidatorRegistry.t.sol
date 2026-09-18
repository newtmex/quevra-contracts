// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MonadVm} from "monad-std/MonadVm.sol";

import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";
import {IValidatorRegistry} from "../src/interfaces/IValidatorRegistry.sol";
import {ValidatorRegistry} from "../src/ValidatorRegistry.sol";

contract ValidatorRegistryTest is Test {
    MonadVm internal constant monadVm = MonadVm(0xc0FFeeCD43A10e1C2b0De63c6CDCFe5B7d0e0CEA);
    ValidatorRegistry internal registry;

    address internal operator = makeAddr("operator");
    address internal executor = makeAddr("executor");

    bytes internal secpPubkey = hex"0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
    bytes internal blsPubkey =
        hex"97f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb";
    bytes internal secpSig = hex"1111";
    bytes internal blsSig = bytes.concat(bytes1(0x80), new bytes(95));
    uint256 internal amount = 100_000 ether;
    uint256 internal commission = 1e17;

    function setUp() public {
        registry = new ValidatorRegistry();
        vm.deal(executor, 1_000_000 ether);
        monadVm.setEpoch(0, false);
    }

    function test_constructorSetsReadableRegistryState() public view {
        assertEq(registry.nextId(), 1);
        assertEq(address(registry.staking()), address(0x1000));
    }

    function test_requestValidatorStoresPendingRequest() public {
        vm.expectEmit(true, true, false, true);
        emit IValidatorRegistry.ValidatorRequested(1, operator, secpPubkey, blsPubkey);

        uint256 id = _request();

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
        _request();

        vm.prank(operator);
        vm.expectRevert(IValidatorRegistry.KeyAlreadyRegistered.selector);
        registry.requestValidator(secpPubkey, blsPubkey, secpSig, blsSig);
    }

    function test_stakingPayloadReconstructsCallerSuppliedEconomics() public {
        uint256 id = _request();

        bytes memory payload = registry.stakingPayload(id, executor, amount, commission);

        assertEq(payload.length, 165);
        assertEq(payload, bytes.concat(secpPubkey, blsPubkey, abi.encodePacked(executor, amount, commission)));
    }

    function test_anyoneCanAddValidatorWithCallerEconomics() public {
        uint256 id = _request();

        vm.prank(executor);
        uint64 validatorId = registry.addValidator{value: amount}(id, commission);

        IValidatorRegistry.Proposal memory proposal = registry.getProposal(id);
        assertGt(validatorId, 0);
        assertEq(proposal.validatorId, validatorId);
        assertEq(proposal.executor, executor);
        assertEq(uint256(proposal.status), uint256(IValidatorRegistry.Status.Executed));

        assertEq(_validatorAuth(validatorId), executor);
    }

    function test_cancelFreesKeys() public {
        uint256 id = _request();

        vm.prank(operator);
        registry.cancel(id);

        uint256 newId = _request();
        assertEq(newId, 2);
        assertEq(uint256(registry.getProposal(id).status), uint256(IValidatorRegistry.Status.Cancelled));
    }

    function test_cancelRevertsIfNotOperator() public {
        uint256 id = _request();

        vm.prank(executor);
        vm.expectRevert(IValidatorRegistry.NotOperator.selector);
        registry.cancel(id);
    }

    function test_addValidatorRevertsAfterCancellation() public {
        uint256 id = _request();

        vm.prank(operator);
        registry.cancel(id);

        vm.prank(executor);
        vm.expectRevert(IValidatorRegistry.NotProposed.selector);
        registry.addValidator{value: amount}(id, commission);
    }

    function test_unknownProposalReverts() public {
        vm.expectRevert(IValidatorRegistry.UnknownProposal.selector);
        registry.getProposal(1);

        vm.expectRevert(IValidatorRegistry.UnknownProposal.selector);
        registry.stakingPayload(1, executor, amount, commission);
    }

    function _request() internal returns (uint256) {
        vm.prank(operator);
        return registry.requestValidator(secpPubkey, blsPubkey, secpSig, blsSig);
    }

    function _validatorAuth(uint64 validatorId) internal returns (address authAddress) {
        (bool ok, bytes memory returndata) =
            address(0x1000).call(abi.encodeCall(IMonadStaking.getValidator, (validatorId)));
        require(ok && returndata.length >= 32, "getValidator");
        assembly {
            authAddress := mload(add(returndata, 32))
        }
    }
}
