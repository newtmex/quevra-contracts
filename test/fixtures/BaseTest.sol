// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MonadVm} from "monad-std/MonadVm.sol";
import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";

abstract contract BaseTest is Test {
    MonadVm internal constant monadVm = MonadVm(0xc0FFeeCD43A10e1C2b0De63c6CDCFe5B7d0e0CEA);
    IMonadStaking internal constant staking = IMonadStaking(0x0000000000000000000000000000000000001000);

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

    function _fundDefaultActors() internal {
        vm.deal(owner, 1_000_000 ether);
        vm.deal(operator, 1_000_000 ether);
        vm.deal(executor, 1_000_000 ether);
        vm.deal(stranger, 1_000_000 ether);
    }

    function _setEpoch(uint64 epoch, bool inDelayPeriod) internal {
        monadVm.setEpoch(epoch, inDelayPeriod);
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

    function _validatorAuth(uint64 validatorId) internal returns (address authAddress) {
        (authAddress,,) = _validatorBasics(validatorId);
    }
}
