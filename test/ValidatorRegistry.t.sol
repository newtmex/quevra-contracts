// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Test} from "forge-std/Test.sol";

import {IMonadStaking} from "../src/interfaces/IMonadStaking.sol";
import {IValidatorRegistry} from "../src/interfaces/IValidatorRegistry.sol";
import {ValidatorRegistry} from "../src/ValidatorRegistry.sol";

contract MockVoter {
    uint256 public created;
    uint256 public cancelled;
    uint256 public ownerCancelled;
    uint256 public executed;
    uint256 public lastProposalId;
    address public lastProposer;
    bool public revertCancel;

    function setRevertCancel(bool v) external {
        revertCancel = v;
    }

    function onProposalCreated(uint256 proposalId, address proposer) external {
        created++;
        lastProposalId = proposalId;
        lastProposer = proposer;
    }

    function onProposalCancelled(uint256) external {
        if (revertCancel) revert("cancel-blocked");
        cancelled++;
    }

    function onOwnerCancelled(uint256) external {
        ownerCancelled++;
    }

    function onProposalExecuted(uint256, uint64) external {
        executed++;
    }
}

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
        assertFalse(registry.paused());
    }

    function test_constructorRevertsOnInvalidConfig() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new ValidatorRegistry(address(0), auth, amount, commission);

        vm.expectRevert(IValidatorRegistry.InvalidAuthAddress.selector);
        new ValidatorRegistry(owner, address(0), amount, commission);

        vm.expectRevert(IValidatorRegistry.StakeTooLow.selector);
        new ValidatorRegistry(owner, auth, amount - 1, commission);

        vm.expectRevert(IValidatorRegistry.CommissionTooHigh.selector);
        new ValidatorRegistry(owner, auth, amount, 1e18 + 1);
    }

    function test_ownerCanSetConfig() public {
        address newAuth = makeAddr("newAuth");
        uint256 newAmount = 200_000 ether;
        uint256 newCommission = 2e17;

        vm.expectEmit(false, false, false, true);
        emit IValidatorRegistry.ConfigUpdated(newAuth, newAmount, newCommission);
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
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, proposer));
        registry.setConfig(auth, amount, commission);
    }

    function test_ownerCanTransferOwnershipInTwoSteps() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        registry.transferOwnership(newOwner);
        assertEq(registry.owner(), owner);
        assertEq(registry.pendingOwner(), newOwner);

        vm.prank(newOwner);
        registry.acceptOwnership();
        assertEq(registry.owner(), newOwner);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        registry.setConfig(auth, amount, commission);
    }

    function test_renounceOwnershipIsDisabled() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        registry.renounceOwnership();
        assertEq(registry.owner(), owner);
    }

    function test_proposeSnapshotsCurrentConfig() public {
        uint256 id = _propose();

        IValidatorRegistry.Proposal memory proposal = registry.getProposal(id);
        assertEq(proposal.secpPubkey, secpPubkey);
        assertEq(proposal.blsPubkey, blsPubkey);
        assertEq(proposal.signedBlsMessage, blsProof);
        assertEq(proposal.proposer, proposer);
        assertEq(proposal.authAddress, auth);
        assertEq(proposal.amount, amount);
        assertEq(proposal.commission, commission);
        assertEq(proposal.executor, address(0));
        assertEq(uint256(proposal.status), uint256(IValidatorRegistry.Status.Proposed));
        assertEq(registry.idBySecpPubkey(keccak256(secpPubkey)), id);
        assertEq(registry.stakingPayload(id), registry.stakingPayload(secpPubkey, blsPubkey));
    }

    function test_proposeRevertsIfSecpSignatureLengthInvalid() public {
        bytes memory secpSig = abi.encodePacked(_secpSig64(), bytes1(0x1b));

        vm.prank(proposer);
        vm.expectRevert(IValidatorRegistry.InvalidSecpSignatureLength.selector);
        registry.propose(secpPubkey, blsPubkey, secpSig, blsProof);
    }

    function test_proposeRevertsOnInvalidKeyOrSignatureLength() public {
        bytes memory secpSig = _secpSig64();

        vm.startPrank(proposer);
        vm.expectRevert(IValidatorRegistry.InvalidBlsSignatureLength.selector);
        registry.propose(secpPubkey, blsPubkey, secpSig, hex"80");

        bytes memory shortBlsKey = bytes.concat(bytes1(0x80), new bytes(46));
        vm.expectRevert(IValidatorRegistry.InvalidBlsPubkeyLength.selector);
        registry.propose(secpPubkey, shortBlsKey, secpSig, blsProof);
        vm.stopPrank();
    }

    function testFuzz_proposeRevertsOnInvalidSecpPubkeyLength(bytes calldata secp) public {
        vm.assume(secp.length != registry.SECP_PUBKEY_LENGTH());
        bytes memory secpSig = _secpSig64();
        vm.prank(proposer);
        vm.expectRevert(IValidatorRegistry.InvalidSecpPubkeyLength.selector);
        registry.propose(secp, blsPubkey, secpSig, blsProof);
    }

    function test_proposeRevertsOnDuplicateKeys() public {
        _propose();
        bytes memory secpSig = _secpSig64();
        vm.prank(proposer);
        vm.expectRevert(IValidatorRegistry.KeyAlreadyRegistered.selector);
        registry.propose(secpPubkey, blsPubkey, secpSig, blsProof);
    }

    function test_anyoneCanExecuteWithConfiguredEconomics() public {
        uint256 id = _propose();
        bytes memory payload = registry.stakingPayload(id);
        assertEq(payload.length, 165);
        assertEq(payload, bytes.concat(secpPubkey, blsPubkey, abi.encodePacked(auth, amount, commission)));

        IValidatorRegistry.Proposal memory stored = registry.getProposal(id);
        vm.expectCall(
            registry.STAKING_PRECOMPILE(),
            amount,
            abi.encodeCall(IMonadStaking.addValidator, (payload, stored.signedSecpMessage, stored.signedBlsMessage))
        );

        vm.prank(executor);
        uint64 validatorId = registry.execute{value: amount}(id);

        IValidatorRegistry.Proposal memory proposal = registry.getProposal(id);
        assertTrue(validatorId != 0);
        assertEq(proposal.validatorId, validatorId);
        assertEq(proposal.authAddress, auth);
        assertEq(proposal.amount, amount);
        assertEq(proposal.commission, commission);
        assertEq(proposal.executor, executor);
        assertEq(uint256(proposal.status), uint256(IValidatorRegistry.Status.Executed));

        (address gotAuth, uint256 poolStake) = _validatorAuthAndStake(validatorId);
        assertEq(gotAuth, auth);
        assertEq(poolStake, amount);

        IMonadStaking staking = IMonadStaking(registry.STAKING_PRECOMPILE());
        (uint256 authStake,,, uint256 authDelta, uint256 authNext,,) = staking.getDelegator(validatorId, auth);
        (uint256 execStake,,, uint256 execDelta, uint256 execNext,,) = staking.getDelegator(validatorId, executor);
        assertEq(authStake + authDelta + authNext, amount);
        assertEq(execStake + execDelta + execNext, 0);
    }

    function test_executeRevertsIfValueDoesNotMatchAmount() public {
        uint256 id = _propose();

        vm.prank(executor);
        vm.expectRevert(IValidatorRegistry.StakeMismatch.selector);
        registry.execute{value: amount - 1}(id);
    }

    function test_executeRevertsIfConfigChanged() public {
        uint256 id = _propose();

        vm.prank(owner);
        registry.setConfig(auth, 200_000 ether, commission);

        vm.prank(executor);
        vm.expectRevert(IValidatorRegistry.ConfigChanged.selector);
        registry.execute{value: amount}(id);
    }

    function test_cancelFreesKeys() public {
        uint256 id = _propose();
        vm.prank(proposer);
        registry.cancel(id);
        uint256 newId = _propose();
        assertEq(newId, 2);
        assertEq(uint256(registry.getProposal(id).status), uint256(IValidatorRegistry.Status.Cancelled));
    }

    function test_cancelRevertsIfNotProposer() public {
        uint256 id = _propose();
        vm.prank(executor);
        vm.expectRevert(IValidatorRegistry.NotProposer.selector);
        registry.cancel(id);
    }

    function test_pauseBlocksProposeAndExecuteButNotCancel() public {
        uint256 id = _propose();

        vm.prank(owner);
        registry.pause();
        assertTrue(registry.paused());

        bytes memory secpSig = _secpSig64();
        vm.prank(proposer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.propose(secpPubkey, blsPubkey, secpSig, blsProof);

        vm.prank(executor);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.execute{value: amount}(id);

        vm.prank(proposer);
        registry.cancel(id);
        assertEq(uint256(registry.getProposal(id).status), uint256(IValidatorRegistry.Status.Cancelled));

        vm.prank(owner);
        registry.unpause();

        uint256 newId = _propose();
        assertEq(newId, 2);
    }

    function test_nonOwnerCannotPause() public {
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, proposer));
        registry.pause();
    }

    function test_setVoterOnlyOwner() public {
        MockVoter mock = new MockVoter();
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, proposer));
        registry.setVoter(address(mock));

        vm.prank(owner);
        registry.setVoter(address(mock));
        assertEq(registry.voter(), address(mock));
    }

    function test_proposeCallsVoterHook() public {
        MockVoter mock = new MockVoter();
        vm.prank(owner);
        registry.setVoter(address(mock));

        uint256 id = _propose();
        assertEq(id, 1);
        assertEq(mock.created(), 1);
        assertEq(mock.lastProposalId(), 1);
        assertEq(mock.lastProposer(), proposer);
    }

    function test_whenVoterSetNonAuthExecuteReverts() public {
        MockVoter mock = new MockVoter();
        vm.prank(owner);
        registry.setVoter(address(mock));

        uint256 id = _propose();
        vm.prank(executor);
        vm.expectRevert(IValidatorRegistry.NotAuth.selector);
        registry.execute{value: amount}(id);
    }

    function test_whenVoterSetAuthCanExecute() public {
        MockVoter mock = new MockVoter();
        vm.prank(owner);
        registry.setVoter(address(mock));

        uint256 id = _propose();
        vm.deal(auth, amount);

        vm.prank(auth);
        uint64 validatorId = registry.execute{value: amount}(id);

        assertTrue(validatorId != 0);
        assertEq(mock.executed(), 1);
        assertEq(registry.getProposal(id).executor, auth);

        (address gotAuth,) = _validatorAuthAndStake(validatorId);
        assertEq(gotAuth, auth);
    }

    function test_cancelCallsVoterHookFirst() public {
        MockVoter mock = new MockVoter();
        vm.prank(owner);
        registry.setVoter(address(mock));

        uint256 id = _propose();
        mock.setRevertCancel(true);
        vm.prank(proposer);
        vm.expectRevert("cancel-blocked");
        registry.cancel(id);
        assertEq(uint256(registry.getProposal(id).status), uint256(IValidatorRegistry.Status.Proposed));

        mock.setRevertCancel(false);
        vm.prank(proposer);
        registry.cancel(id);
        assertEq(mock.cancelled(), 1);
        assertEq(uint256(registry.getProposal(id).status), uint256(IValidatorRegistry.Status.Cancelled));
    }

    function test_ownerCancelFreesKeysAndNotifiesVoter() public {
        MockVoter mock = new MockVoter();
        vm.prank(owner);
        registry.setVoter(address(mock));

        uint256 id = _propose();
        vm.prank(owner);
        registry.ownerCancel(id);

        assertEq(mock.ownerCancelled(), 1);
        assertEq(uint256(registry.getProposal(id).status), uint256(IValidatorRegistry.Status.Cancelled));
        uint256 newId = _propose();
        assertEq(newId, 2);
    }

    function test_nonOwnerCannotOwnerCancel() public {
        uint256 id = _propose();
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, proposer));
        registry.ownerCancel(id);
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

    /// @dev ABI-decode only auth + pool stake from `getValidator` (12-tuple is stack-too-deep).
    function _validatorAuthAndStake(uint64 validatorId) internal returns (address gotAuth, uint256 poolStake) {
        (bool ok, bytes memory ret) =
            registry.STAKING_PRECOMPILE().call(abi.encodeCall(IMonadStaking.getValidator, (validatorId)));
        require(ok && ret.length >= 96, "getValidator");
        assembly {
            gotAuth := mload(add(ret, 32))
            poolStake := mload(add(ret, 96))
        }
    }
}
