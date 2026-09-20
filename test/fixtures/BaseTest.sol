// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MonadVm} from "monad-std/MonadVm.sol";
import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";
import {MonadStdConstants} from "monad-std/MonadStdConstants.sol";

abstract contract BaseTest is Test, MonadStdConstants {
    MonadVm internal constant monadVm = MONAD_VM;
    IMonadStaking internal constant staking = STAKING;

    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal executor = makeAddr("executor");
    address internal stranger = makeAddr("stranger");

    bytes internal secpPubkey = hex"0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
    bytes internal blsPubkey =
        hex"97f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb";
    bytes internal secpSig = hex"1111";
    bytes internal blsSig = bytes.concat(bytes1(0x80), new bytes(95));

    uint256 internal validatorStake = 100_000 ether;
    uint256 internal delegationAmount = 10 ether;
    uint256 internal commission = 1e17;
    uint256 internal lockDuration = 4;

    function setUp() public virtual {
        _setEpoch(0, false);
        _fundDefaultActors();
    }

    // Foundry funding is infrastructure-only: the actors need native MON before
    // the real veMON, validator registration, and delegation flows can execute.
    function _fundDefaultActors() internal {
        vm.deal(owner, 1_000_000 ether);
        vm.deal(operator, 1_000_000 ether);
        vm.deal(executor, 1_000_000 ether);
        vm.deal(stranger, 1_000_000 ether);
    }

    // Monad's canonical test harness owns epoch state; tests do not mock staking reads.
    function _setEpoch(uint64 epoch, bool inDelayPeriod) internal {
        monadVm.setEpoch(epoch, inDelayPeriod);
    }

    function _validatorIdentity(uint64 validatorId)
        internal
        returns (address authAddress, uint256 validatorCommission)
    {
        (bool ok, bytes memory data) = address(STAKING).call(abi.encodeWithSelector(bytes4(0x2b6d639a), validatorId));
        require(ok && data.length >= 384, "getValidator");
        assembly ("memory-safe") {
            authAddress := mload(add(data, 32))
            validatorCommission := mload(add(data, 160))
        }
    }

    function _validatorStake(uint64 validatorId) internal returns (uint256 stake) {
        (bool ok, bytes memory data) = address(STAKING).call(abi.encodeWithSelector(bytes4(0x2b6d639a), validatorId));
        require(ok && data.length >= 384, "getValidator");
        assembly ("memory-safe") {
            stake := mload(add(data, 96))
        }
    }
}
