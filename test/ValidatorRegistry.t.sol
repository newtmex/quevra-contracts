// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IMonadStaking} from "../src/interfaces/IMonadStaking.sol";
import {ConsensusKeyProof} from "../src/lib/ConsensusKeyProof.sol";
import {ValidatorRegistry} from "../src/ValidatorRegistry.sol";

contract ValidatorRegistryTest is Test {
    ValidatorRegistry internal registry;

    uint256 internal secpSk = 1;
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
        registry = new ValidatorRegistry();
        vm.deal(proposer, 1_000_000 ether);
        vm.deal(executor, 1_000_000 ether);
    }

    function test_proposeStoresKeysWithoutAuthOrEconomics() public {
        uint256 id = _propose();

        ValidatorRegistry.Proposal memory proposal = registry.getProposal(id);
        assertEq(proposal.secpPubkey, secpPubkey);
        assertEq(proposal.blsPubkey, blsPubkey);
        assertEq(proposal.signedBlsMessage, blsProof);
        assertEq(proposal.proposer, proposer);
        assertEq(proposal.authAddress, address(0));
        assertEq(proposal.amount, 0);
        assertEq(proposal.commission, 0);
        assertEq(proposal.executor, address(0));
        assertEq(uint256(proposal.status), uint256(ValidatorRegistry.Status.Proposed));
        assertEq(registry.idBySecpPubkey(keccak256(secpPubkey)), id);
    }

    function test_proposeRevertsIfSecpSignatureDoesNotMatchKey() public {
        bytes32 digest = registry.proposalDigest(secpPubkey, blsPubkey);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(2, digest);

        vm.prank(proposer);
        vm.expectRevert(ConsensusKeyProof.InvalidSecpSignature.selector);
        registry.propose(secpPubkey, blsPubkey, abi.encodePacked(r, s, v), blsProof);
    }

    function test_proposeRevertsOnInvalidBlsKeyOrSignature() public {
        bytes32 digest = registry.proposalDigest(secpPubkey, blsPubkey);
        bytes memory secpSig = _secpSig(digest);

        vm.startPrank(proposer);
        vm.expectRevert(ConsensusKeyProof.InvalidBlsSignature.selector);
        registry.propose(secpPubkey, blsPubkey, secpSig, hex"80");

        bytes memory badBlsKey = bytes.concat(bytes1(0x80), new bytes(47));
        bytes memory badKeySecpSig = _secpSig(registry.proposalDigest(secpPubkey, badBlsKey));
        vm.expectRevert(ConsensusKeyProof.InvalidBlsPubkey.selector);
        registry.propose(secpPubkey, badBlsKey, badKeySecpSig, blsProof);
        vm.stopPrank();
    }

    function test_proposeRevertsOnDuplicateKeys() public {
        _propose();
        bytes memory secpSig = _secpSig(registry.proposalDigest(secpPubkey, blsPubkey));
        vm.prank(proposer);
        vm.expectRevert(ValidatorRegistry.KeyAlreadyRegistered.selector);
        registry.propose(secpPubkey, blsPubkey, secpSig, blsProof);
    }

    function test_anyoneCanExecuteWithAuthAndEconomics() public {
        uint256 id = _propose();
        bytes memory payload = registry.stakingPayload(id, auth, amount, commission);
        assertEq(payload.length, 165);

        ValidatorRegistry.Proposal memory stored = registry.getProposal(id);
        vm.expectCall(
            registry.STAKING_PRECOMPILE(),
            amount,
            abi.encodeCall(IMonadStaking.addValidator, (payload, stored.signedSecpMessage, stored.signedBlsMessage))
        );

        vm.prank(executor);
        uint64 validatorId = registry.execute{value: amount}(id, auth, commission);

        ValidatorRegistry.Proposal memory proposal = registry.getProposal(id);
        assertTrue(validatorId != 0);
        assertEq(proposal.validatorId, validatorId);
        assertEq(proposal.authAddress, auth);
        assertEq(proposal.amount, amount);
        assertEq(proposal.commission, commission);
        assertEq(proposal.executor, executor);
        assertEq(uint256(proposal.status), uint256(ValidatorRegistry.Status.Executed));
    }

    function test_executeRevertsOnInvalidEconomics() public {
        uint256 id = _propose();

        vm.startPrank(executor);
        vm.expectRevert(ValidatorRegistry.InvalidAuthAddress.selector);
        registry.execute{value: amount}(id, address(0), commission);

        vm.expectRevert(ValidatorRegistry.StakeTooLow.selector);
        registry.execute{value: amount - 1}(id, auth, commission);
        vm.stopPrank();
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
        bytes memory secpSig = _secpSig(registry.proposalDigest(secpPubkey, blsPubkey));
        vm.prank(proposer);
        return registry.propose(secpPubkey, blsPubkey, secpSig, blsProof);
    }

    function _secpSig(bytes32 digest) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(secpSk, digest);
        return abi.encodePacked(r, s, v);
    }
}
