// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {StakingVault} from "../../src/staking/StakingVault.sol";
import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";
import {ValidatorRegistryFixture} from "./ValidatorRegistryFixture.sol";

abstract contract StakingVaultFixture is ValidatorRegistryFixture {
    StakingVault internal vault;
    StakingVault internal vaultImplementation;

    function setUp() public virtual override {
        super.setUp();
        vault = _newVault();
        bytes memory payload = abi.encodePacked(
            secpPubkey, blsPubkey, bytes20(address(vault)), bytes32(validatorStake), bytes32(commission)
        );
        vm.prank(operator);
        requestId = registry.requestValidator(payload, secpSig, blsSig);
        vm.prank(owner);
        vault.initialize(address(registry), requestId);
    }

    function _newVault() internal returns (StakingVault deployedVault) {
        vm.prank(owner);
        StakingVault implementation = new StakingVault();
        deployedVault = StakingVault(payable(Clones.clone(address(implementation))));
    }

    function _addVaultValidator() internal returns (uint64 validatorId) {
        vm.prank(owner);
        validatorId = vault.addValidator{value: validatorStake}();
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
