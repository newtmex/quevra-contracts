// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Test} from "forge-std/Test.sol";
import {MonadVm} from "monad-std/MonadVm.sol";

import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";
import {IValidatorRegistry} from "../src/interfaces/IValidatorRegistry.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {ValidatorRegistry} from "../src/ValidatorRegistry.sol";

contract StakingVaultTest is Test {
    MonadVm internal constant monadVm = MonadVm(0xc0FFeeCD43A10e1C2b0De63c6CDCFe5B7d0e0CEA);
    IMonadStaking internal constant staking = IMonadStaking(0x0000000000000000000000000000000000001000);

    ValidatorRegistry internal registry;
    StakingVault internal vault;

    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal stranger = makeAddr("stranger");

    bytes internal secpPubkey = hex"0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
    bytes internal blsPubkey =
        hex"97f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb";
    bytes internal secpSig = hex"1111";
    bytes internal blsSig = bytes.concat(bytes1(0x80), new bytes(95));

    uint256 internal requestId;
    uint256 internal validatorStake = 100_000 ether;
    uint256 internal delegationAmount = 10 ether;
    uint256 internal commission = 1e17;

    function setUp() public {
        registry = new ValidatorRegistry();
        monadVm.setEpoch(0, false);

        vm.prank(operator);
        requestId = registry.requestValidator(secpPubkey, blsPubkey, secpSig, blsSig);

        vm.prank(owner);
        StakingVault implementation = new StakingVault();
        vault = StakingVault(payable(Clones.clone(address(implementation))));
        vm.prank(owner);
        vault.initialize(address(registry), requestId);
        vm.deal(owner, 1_000_000 ether);
        vm.deal(stranger, 1_000_000 ether);
    }

    function test_initializeBindsOwnerRegistryRequestAndStakingPrecompile() public view {
        assertEq(vault.owner(), owner);
        assertEq(address(vault.registry()), address(registry));
        assertEq(address(vault.staking()), address(staking));
        assertEq(vault.requestId(), requestId);
        assertEq(vault.validatorId(), 0);
    }

    function test_initializeRejectsInvalidRegistryOrRequest() public {
        StakingVault implementation = new StakingVault();
        StakingVault clone = StakingVault(payable(Clones.clone(address(implementation))));
        vm.expectRevert(StakingVault.InvalidRequest.selector);
        clone.initialize(address(0), requestId);
        vm.expectRevert(StakingVault.InvalidRequest.selector);
        clone.initialize(address(registry), 0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        clone.initialize(address(registry), requestId);
        clone.initialize(address(registry), requestId);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        clone.initialize(address(registry), requestId);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(registry), requestId);
    }

    function test_addValidatorExecutesBoundRegistryRequestFromVault() public {
        vm.expectEmit(true, true, false, false, address(registry));
        emit IValidatorRegistry.ValidatorAdded(requestId, address(vault), 0, address(vault), validatorStake, commission);

        vm.prank(owner);
        uint64 validatorId = vault.addValidator{value: validatorStake}(commission);

        assertGt(validatorId, 0);
        assertEq(vault.validatorId(), validatorId);

        IValidatorRegistry.Proposal memory proposal = registry.getProposal(requestId);
        assertEq(uint256(proposal.status), uint256(IValidatorRegistry.Status.Executed));
        assertEq(proposal.executor, address(vault));
        assertEq(proposal.validatorId, validatorId);

        _assertValidator(validatorId);
    }

    function test_addValidatorIsOwnerOnlyAndCanOnlyRunOnce() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.addValidator{value: validatorStake}(commission);

        vm.prank(owner);
        vault.addValidator{value: validatorStake}(commission);

        vm.prank(owner);
        vm.expectRevert(StakingVault.ValidatorAlreadyAdded.selector);
        vault.addValidator{value: validatorStake}(commission);
    }

    function test_delegateSendsOwnerFundsToVaultValidator() public {
        vm.prank(owner);
        uint64 validatorId = vault.addValidator{value: validatorStake}(commission);

        vm.expectEmit(true, true, false, false, address(staking));
        emit IMonadStaking.Delegate(validatorId, address(vault), delegationAmount, 0);

        vm.prank(owner);
        bool success = vault.delegate{value: delegationAmount}();

        assertTrue(success);

        _assertDelegation(validatorId);
    }

    function test_delegateRequiresOwnerAndAddedValidator() public {
        vm.prank(owner);
        vm.expectRevert(StakingVault.ValidatorNotAdded.selector);
        vault.delegate{value: delegationAmount}();

        vm.prank(owner);
        vault.addValidator{value: validatorStake}(commission);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.delegate{value: delegationAmount}();
    }

    function _assertValidator(uint64 validatorId) internal {
        (address authAddress, uint256 stake, uint256 storedCommission) = _validatorBasics(validatorId);

        assertEq(authAddress, address(vault));
        assertEq(stake, validatorStake);
        assertEq(storedCommission, commission);
    }

    function _assertDelegation(uint64 validatorId) internal {
        (uint256 stake, uint256 deltaStake, uint256 nextDeltaStake, uint64 deltaEpoch, uint64 nextDeltaEpoch) =
            _delegatorPosition(validatorId);

        assertEq(stake + deltaStake + nextDeltaStake, validatorStake + delegationAmount);
        assertTrue(deltaEpoch != 0 || nextDeltaEpoch != 0 || stake == validatorStake + delegationAmount);
    }

    function _validatorBasics(uint64 validatorId)
        internal
        returns (address authAddress, uint256 stake, uint256 storedCommission)
    {
        (bool ok, bytes memory returndata) =
            address(staking).call(abi.encodeCall(IMonadStaking.getValidator, (validatorId)));
        require(ok && returndata.length >= 160, "getValidator");

        assembly {
            authAddress := mload(add(returndata, 32))
            stake := mload(add(returndata, 96))
            storedCommission := mload(add(returndata, 160))
        }
    }

    function _delegatorPosition(uint64 validatorId)
        internal
        returns (uint256 stake, uint256 deltaStake, uint256 nextDeltaStake, uint64 deltaEpoch, uint64 nextDeltaEpoch)
    {
        (bool ok, bytes memory returndata) =
            address(staking).call(abi.encodeCall(IMonadStaking.getDelegator, (validatorId, address(vault))));
        require(ok && returndata.length >= 224, "getDelegator");

        assembly {
            stake := mload(add(returndata, 32))
            deltaStake := mload(add(returndata, 128))
            nextDeltaStake := mload(add(returndata, 160))
            deltaEpoch := mload(add(returndata, 192))
            nextDeltaEpoch := mload(add(returndata, 224))
        }
    }
}
