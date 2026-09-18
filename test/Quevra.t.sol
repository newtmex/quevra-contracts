// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";

import {IMonadStaking} from "../src/interfaces/IMonadStaking.sol";
import {IProposalGauge} from "../src/interfaces/IProposalGauge.sol";
import {IValidatorRegistry} from "../src/interfaces/IValidatorRegistry.sol";
import {IValidatorsVoter} from "../src/interfaces/IValidatorsVoter.sol";
import {IVeMON} from "../src/interfaces/IVeMON.sol";
import {MonVault} from "../src/vault/MonVault.sol";
import {ValidatorRegistry} from "../src/ValidatorRegistry.sol";
import {ValidatorsVoter} from "../src/voter/ValidatorsVoter.sol";
import {VeMON} from "../src/ve/VeMON.sol";
import {WMON} from "./mocks/WMON.sol";

contract QuevraTest is Test {
    address internal constant MONAD_VM = 0xc0FFeeCD43A10e1C2b0De63c6CDCFe5B7d0e0CEA;
    uint256 internal constant MAX_LOCK = 28 days;
    uint256 internal constant STAKE = 100_000 ether;
    uint256 internal constant COMMISSION = 2e17;

    WMON internal wmon;
    MonVault internal vault;
    VeMON internal ve;
    ValidatorRegistry internal registry;
    ValidatorsVoter internal voter;

    address internal owner = makeAddr("owner");
    address internal locker = makeAddr("locker");
    address internal proposer = makeAddr("proposer");
    address internal stranger = makeAddr("stranger");

    uint256 internal secpSk = 1;
    bytes internal secpPubkey = hex"0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
    bytes internal blsPubkey =
        hex"97f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb";
    bytes internal blsProof = bytes.concat(bytes1(0x80), new bytes(95));

    function setUp() public {
        wmon = new WMON();

        uint256 nonce = vm.getNonce(address(this));
        address predictedVault = vm.computeCreateAddress(address(this), nonce);
        address predictedRegistry = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedVe = vm.computeCreateAddress(address(this), nonce + 2);
        address predictedVoter = vm.computeCreateAddress(address(this), nonce + 3);

        vault = new MonVault(owner, address(wmon), predictedVe, predictedVoter, predictedRegistry);
        registry = new ValidatorRegistry(owner, predictedVault, STAKE, COMMISSION, predictedVoter);
        ve = new VeMON(owner, address(wmon), predictedVault, predictedVoter, MAX_LOCK);
        voter = new ValidatorsVoter(owner, predictedVe, predictedVault, predictedRegistry);

        assertEq(address(vault), predictedVault);
        assertEq(address(registry), predictedRegistry);
        assertEq(address(ve), predictedVe);
        assertEq(address(voter), predictedVoter);

        _setEpoch(2, false);
        vm.deal(locker, 1_000_000 ether);
        vm.deal(proposer, 1 ether);
        vm.deal(stranger, STAKE);
    }

    function test_lockProposeVoteFinalizeExecuteCreditsVault() public {
        uint256 tokenId = _lock(200_000 ether);
        uint256 id = _propose();
        address gauge = voter.proposalToGauge(id);
        assertTrue(gauge != address(0));
        assertEq(IProposalGauge(gauge).proposalId(), id);
        assertEq(IProposalGauge(gauge).proposer(), proposer);

        _vote(tokenId, gauge);

        _setEpoch(40, false);
        voter.finalizeCycle(0);
        assertTrue(voter.cycleFinalized(0));
        assertGt(voter.cycleWeights(0, gauge), 0);

        voter.allocate(8);

        IValidatorRegistry.Proposal memory proposal = registry.getProposal(id);
        assertEq(uint256(proposal.status), uint256(IValidatorRegistry.Status.Executed));
        assertEq(proposal.executor, address(vault));
        assertEq(proposal.authAddress, address(vault));
        assertTrue(proposal.validatorId != 0);
        assertEq(IProposalGauge(gauge).validatorId(), proposal.validatorId);

        (address gotAuth, uint256 poolStake) = _validatorAuthAndStake(proposal.validatorId);
        assertEq(gotAuth, address(vault));
        assertEq(poolStake, STAKE);

        IMonadStaking staking = IMonadStaking(registry.STAKING_PRECOMPILE());
        (uint256 vaultStake,,, uint256 vaultDelta, uint256 vaultNext,,) =
            staking.getDelegator(proposal.validatorId, address(vault));
        (uint256 strangerStake,,, uint256 strangerDelta, uint256 strangerNext,,) =
            staking.getDelegator(proposal.validatorId, stranger);
        assertEq(vaultStake + vaultDelta + vaultNext, STAKE);
        assertEq(strangerStake + strangerDelta + strangerNext, 0);
        assertEq(address(vault).balance, 100_000 ether);
    }

    function test_strangerCannotExecuteWhenVoterWired() public {
        _lock(200_000 ether);
        uint256 id = _propose();
        vm.prank(stranger);
        vm.expectRevert(IValidatorRegistry.NotAuth.selector);
        registry.execute{value: STAKE}(id);
    }

    function test_allocateWithoutVotesSkips() public {
        uint256 id = _propose();
        _setEpoch(40, false);
        voter.finalizeCycle(0);
        voter.allocate(8);
        assertEq(uint256(registry.getProposal(id).status), uint256(IValidatorRegistry.Status.Proposed));
    }

    function test_allocateWithoutLiquiditySkips() public {
        uint256 tokenId = _lock(1 ether);
        uint256 id = _propose();
        _vote(tokenId, voter.proposalToGauge(id));

        _setEpoch(40, false);
        voter.finalizeCycle(0);
        voter.allocate(8);
        assertEq(uint256(registry.getProposal(id).status), uint256(IValidatorRegistry.Status.Proposed));
    }

    function test_finalizeTwiceReverts() public {
        _setEpoch(40, false);
        voter.finalizeCycle(0);
        vm.expectRevert(IValidatorsVoter.AlreadyFinalized.selector);
        voter.finalizeCycle(0);
    }

    function test_finalizeBeforeCycleEndsReverts() public {
        vm.expectRevert(IValidatorsVoter.CycleNotOver.selector);
        voter.finalizeCycle(0);
    }

    function test_voteOutsideWindowReverts() public {
        uint256 tokenId = _lock(10 ether);
        uint256 id = _propose();
        address[] memory gs = new address[](1);
        gs[0] = voter.proposalToGauge(id);
        uint256[] memory ws = new uint256[](1);
        ws[0] = 1;

        _setEpoch(0, false);
        vm.prank(locker);
        vm.expectRevert(IValidatorsVoter.DistributeWindow.selector);
        voter.vote(tokenId, gs, ws);
    }

    function test_secondVoteSameCycleReverts() public {
        uint256 tokenId = _lock(10 ether);
        uint256 id = _propose();
        address gauge = voter.proposalToGauge(id);
        _vote(tokenId, gauge);

        address[] memory gs = new address[](1);
        gs[0] = gauge;
        uint256[] memory ws = new uint256[](1);
        ws[0] = 1;
        vm.prank(locker);
        vm.expectRevert(IValidatorsVoter.AlreadyVotedOrDeposited.selector);
        voter.vote(tokenId, gs, ws);
    }

    function test_cancelRevertsWhenGaugeHasVotes() public {
        uint256 tokenId = _lock(2 ether);
        uint256 id = _propose();
        _vote(tokenId, voter.proposalToGauge(id));

        vm.prank(proposer);
        vm.expectRevert(IValidatorsVoter.GaugeHasVotes.selector);
        registry.cancel(id);
        assertEq(uint256(registry.getProposal(id).status), uint256(IValidatorRegistry.Status.Proposed));
    }

    function test_ownerCancelKillsGaugeWithVotes() public {
        uint256 tokenId = _lock(2 ether);
        uint256 id = _propose();
        address gauge = voter.proposalToGauge(id);
        _vote(tokenId, gauge);

        vm.prank(owner);
        registry.ownerCancel(id);
        assertEq(uint256(registry.getProposal(id).status), uint256(IValidatorRegistry.Status.Cancelled));
        assertFalse(voter.isAlive(gauge));
    }

    function test_immutableWiring() public view {
        assertEq(vault.ve(), address(ve));
        assertEq(vault.voter(), address(voter));
        assertEq(vault.registry(), address(registry));
        assertEq(ve.voter(), address(voter));
        assertEq(registry.voter(), address(voter));
        assertEq(voter.ve(), address(ve));
        assertEq(voter.vault(), address(vault));
        assertEq(voter.registry(), address(registry));
    }

    function test_pokeRefreshesWeight() public {
        uint256 tokenId = _lock(10 ether);
        uint256 id = _propose();
        address gauge = voter.proposalToGauge(id);
        _vote(tokenId, gauge);
        uint256 w0 = voter.weights(gauge);

        vm.prank(locker);
        ve.increaseAmountNative{value: 10 ether}(tokenId);
        vm.prank(locker);
        voter.poke(tokenId);
        assertGt(voter.weights(gauge), w0);
    }

    function test_resetNextCycleClearsVoteAndAllowsTransfer() public {
        uint256 tokenId = _lock(10 ether);
        uint256 id = _propose();
        _vote(tokenId, voter.proposalToGauge(id));

        vm.prank(locker);
        vm.expectRevert(IVeMON.AlreadyVoted.selector);
        ve.transferFrom(locker, stranger, tokenId);

        _setEpoch(40, false);
        vm.prank(locker);
        voter.reset(tokenId);
        assertEq(voter.usedWeights(tokenId), 0);

        vm.prank(locker);
        ve.transferFrom(locker, stranger, tokenId);
        assertEq(ve.ownerOf(tokenId), stranger);
    }

    function test_nonOwnerCannotSyncProposal() public {
        uint256 id = _propose();
        vm.prank(locker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, locker));
        voter.syncProposal(id);
    }

    function _lock(uint256 value) internal returns (uint256 tokenId) {
        vm.prank(locker);
        tokenId = ve.createLockNative{value: value}(MAX_LOCK);
    }

    function _propose() internal returns (uint256 id) {
        bytes32 digest = keccak256(registry.stakingPayload(secpPubkey, blsPubkey));
        (, bytes32 r, bytes32 s) = vm.sign(secpSk, digest);
        bytes memory secpSig = abi.encodePacked(r, s);
        vm.prank(proposer);
        id = registry.propose(secpPubkey, blsPubkey, secpSig, blsProof);
    }

    function _vote(uint256 tokenId, address gauge) internal {
        address[] memory gs = new address[](1);
        gs[0] = gauge;
        uint256[] memory ws = new uint256[](1);
        ws[0] = 1;
        vm.prank(locker);
        voter.vote(tokenId, gs, ws);
    }

    function _setEpoch(uint64 epoch, bool inDelayPeriod) internal {
        (bool ok,) = MONAD_VM.call(abi.encodeWithSignature("setEpoch(uint64,bool)", epoch, inDelayPeriod));
        require(ok, "setEpoch");
    }

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
