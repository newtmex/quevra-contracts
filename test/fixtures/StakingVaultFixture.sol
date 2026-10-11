// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {StakingVault} from "../../src/staking/controlled/StakingVault.sol";
import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";
import {VeValidatorFixture} from "./VeValidatorFixture.sol";

abstract contract StakingVaultFixture is VeValidatorFixture {
    StakingVault internal vault;
    StakingVault internal vaultImplementation;

    function setUp() public virtual override {
        super.setUp();
        vault = _newVault();
        bytes memory payload = abi.encodePacked(
            secpPubkey, blsPubkey, bytes20(address(vault)), bytes32(validatorStake), bytes32(commission)
        );
        tokenId = validatorVe.registerNew(operator, payload, secpSig, blsSig);
    }

    function _newVault() internal returns (StakingVault deployedVault) {
        StakingVault implementation = new StakingVault();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(implementation), owner);
        vm.prank(owner);
        deployedVault = StakingVault(payable(address(new BeaconProxy(address(beacon), bytes("")))));
        vm.prank(owner);
        deployedVault.initialize(owner, address(validatorVe), 1, 0);
    }

    function _addVaultValidator() internal returns (uint64 validatorId) {
        vm.prank(owner);
        vault.deposit{value: validatorStake}(0);
        validatorId = vault.validatorId();
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
