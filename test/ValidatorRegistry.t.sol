// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IMonadStaking} from "../src/interfaces/IMonadStaking.sol";
import {ValidatorRegistry} from "../src/ValidatorRegistry.sol";

contract ValidatorRegistryTest is Test {
    ValidatorRegistry internal registry;

    uint256 internal secpSk = 1;
    address internal owner = makeAddr("owner");
    address internal proposer = makeAddr("proposer");
    address internal auth = makeAddr("auth");
    address internal executor = makeAddr("executor");

    bytes internal secpPubkey = hex"0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
    bytes internal blsPubkey =
        hex"97f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb";
    bytes internal blsProof = bytes.concat(bytes1(0x80), new bytes(95));
    uint256 internal amount = 100_000 ether;
    uint256 internal commission = 1e17;

    function setUp() public {
        registry = new ValidatorRegistry(owner, auth, amount, commission);
        vm.deal(proposer, 1_000_000 ether);
        vm.deal(executor, 1_000_000 ether);
    }

    function test_constructorSetsReadableConfig() public view {
        assertEq(registry.owner(), owner);
        assertEq(registry.authAddress(), auth);
        assertEq(registry.amount(), amount);
        assertEq(registry.commission(), commission);
        assertEq(registry.stakingPayload(secpPubkey, blsPubkey).length, 165);
    }

    function test_constructorRevertsOnInvalidConfig() public {
        vm.expectRevert(ValidatorRegistry.InvalidOwner.selector);
        new ValidatorRegistry(address(0), auth, amount, commission);

        vm.expectRevert(ValidatorRegistry.InvalidAuthAddress.selector);
        new ValidatorRegistry(owner, address(0), amount, commission);

        vm.expectRevert(ValidatorRegistry.StakeTooLow.selector);
        new ValidatorRegistry(owner, auth, amount - 1, commission);

        vm.expectRevert(ValidatorRegistry.CommissionTooHigh.selector);
        new ValidatorRegistry(owner, auth, amount, 1e18 + 1);
    }

    function test_ownerCanSetConfig() public {
        address newAuth = makeAddr("newAuth");
        uint256 newAmount = 200_000 ether;
        uint256 newCommission = 2e17;

        vm.expectEmit(false, false, false, true);
        emit ValidatorRegistry.ConfigUpdated(newAuth, newAmount, newCommission);
        vm.prank(owner);
        registry.setConfig(newAuth, newAmount, newCommission);

        assertEq(registry.authAddress(), newAuth);
        assertEq(registry.amount(), newAmount);
        assertEq(registry.commission(), newCommission);
        assertEq(
            registry.stakingPayload(secpPubkey, blsPubkey),
            bytes.concat(secpPubkey, blsPubkey, abi.encodePacked(newAuth, newAmount, newCommission))
        );
    }

    function test_nonOwnerCannotSetConfig() public {
        vm.prank(proposer);
        vm.expectRevert(ValidatorRegistry.NotOwner.selector);
        registry.setConfig(auth, amount, commission);
    }

    function test_ownerCanTransferOwnership() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        registry.transferOwnership(newOwner);
        assertEq(registry.owner(), newOwner);

        vm.prank(owner);
        vm.expectRevert(ValidatorRegistry.NotOwner.selector);
        registry.setConfig(auth, amount, commission);
    }

    function test_proposeSnapshotsCurrentConfig() public {
        uint256 id = _propose();

        ValidatorRegistry.Proposal memory proposal = registry.getProposal(id);
        assertEq(proposal.secpPubkey, secpPubkey);
        assertEq(proposal.blsPubkey, blsPubkey);
        assertEq(proposal.signedBlsMessage, blsProof);
        assertEq(proposal.proposer, proposer);
        assertEq(proposal.authAddress, auth);
        assertEq(proposal.amount, amount);
        assertEq(proposal.commission, commission);
        assertEq(proposal.executor, address(0));
        assertEq(uint256(proposal.status), uint256(ValidatorRegistry.Status.Proposed));
        assertEq(registry.idBySecpPubkey(keccak256(secpPubkey)), id);
        assertEq(registry.stakingPayload(id), registry.stakingPayload(secpPubkey, blsPubkey));
    }

    function test_proposeRevertsIfSecpSignatureLengthInvalid() public {
        bytes memory secpSig = abi.encodePacked(_secpSig64(), bytes1(0x1b));

        vm.prank(proposer);
        vm.expectRevert(ValidatorRegistry.InvalidSecpSignatureLength.selector);
        registry.propose(secpPubkey, blsPubkey, secpSig, blsProof);
    }

    function test_proposeRevertsOnInvalidKeyOrSignatureLength() public {
        bytes memory secpSig = _secpSig64();

        vm.startPrank(proposer);
        vm.expectRevert(ValidatorRegistry.InvalidBlsSignatureLength.selector);
        registry.propose(secpPubkey, blsPubkey, secpSig, hex"80");

        bytes memory shortBlsKey = bytes.concat(bytes1(0x80), new bytes(46));
        vm.expectRevert(ValidatorRegistry.InvalidBlsPubkeyLength.selector);
        registry.propose(secpPubkey, shortBlsKey, secpSig, blsProof);
        vm.stopPrank();
    }

    function test_proposeRevertsOnDuplicateKeys() public {
        _propose();
        bytes memory secpSig = _secpSig64();
        vm.prank(proposer);
        vm.expectRevert(ValidatorRegistry.KeyAlreadyRegistered.selector);
        registry.propose(secpPubkey, blsPubkey, secpSig, blsProof);
    }

    function test_anyoneCanExecuteWithConfiguredEconomics() public {
        uint256 id = _propose();
        bytes memory payload = registry.stakingPayload(id);
        assertEq(payload.length, 165);
        assertEq(payload, bytes.concat(secpPubkey, blsPubkey, abi.encodePacked(auth, amount, commission)));

        ValidatorRegistry.Proposal memory stored = registry.getProposal(id);
        vm.expectCall(
            registry.STAKING_PRECOMPILE(),
            amount,
            abi.encodeCall(IMonadStaking.addValidator, (payload, stored.signedSecpMessage, stored.signedBlsMessage))
        );

        vm.prank(executor);
        uint64 validatorId = registry.execute{value: amount}(id);

        ValidatorRegistry.Proposal memory proposal = registry.getProposal(id);
        assertTrue(validatorId != 0);
        assertEq(proposal.validatorId, validatorId);
        assertEq(proposal.authAddress, auth);
        assertEq(proposal.amount, amount);
        assertEq(proposal.commission, commission);
        assertEq(proposal.executor, executor);
        assertEq(uint256(proposal.status), uint256(ValidatorRegistry.Status.Executed));
    }

    function test_executeRevertsIfValueDoesNotMatchAmount() public {
        uint256 id = _propose();

        vm.prank(executor);
        vm.expectRevert(ValidatorRegistry.StakeMismatch.selector);
        registry.execute{value: amount - 1}(id);
    }

    function test_executeRevertsIfConfigChanged() public {
        uint256 id = _propose();

        vm.prank(owner);
        registry.setConfig(auth, 200_000 ether, commission);

        vm.prank(executor);
        vm.expectRevert(ValidatorRegistry.ConfigChanged.selector);
        registry.execute{value: amount}(id);
    }

    function test_cancelFreesKeys() public {
        uint256 id = _propose();
        vm.prank(proposer);
        registry.cancel(id);
        uint256 newId = _propose();
        assertEq(newId, 2);
        assertEq(uint256(registry.getProposal(id).status), uint256(ValidatorRegistry.Status.Cancelled));
    }

    function test_cancelRevertsIfNotProposer() public {
        uint256 id = _propose();
        vm.prank(executor);
        vm.expectRevert(ValidatorRegistry.NotProposer.selector);
        registry.cancel(id);
    }

    function _propose() internal returns (uint256) {
        bytes memory secpSig = _secpSig64();
        vm.prank(proposer);
        return registry.propose(secpPubkey, blsPubkey, secpSig, blsProof);
    }

    function _secpSig64() internal view returns (bytes memory) {
        bytes32 digest = keccak256(registry.stakingPayload(secpPubkey, blsPubkey));
        (, bytes32 r, bytes32 s) = vm.sign(secpSk, digest);
        return abi.encodePacked(r, s);
    }
}
