// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {ValidatorRegistry} from "../../src/ValidatorRegistry.sol";

/// @notice Broadcasts propose+execute against a live Solonet. The runner checks
///         the staking precompile stored the new validator.
contract AddValidatorOnSolonet is Script {
    function run() external returns (address registry, uint256 proposalId, uint64 validatorId) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(pk);
        address auth = vm.envAddress("AUTH_ADDRESS");
        uint256 amount = vm.envUint("AMOUNT");
        uint256 commission = vm.envUint("COMMISSION");
        bytes memory secpPubkey = vm.envBytes("SECP_PUBKEY");
        bytes memory blsPubkey = vm.envBytes("BLS_PUBKEY");
        bytes memory secpSig = vm.envBytes("SECP_SIG");
        bytes memory blsSig = vm.envBytes("BLS_SIG");

        require(block.chainid == 20143, "not solonet");
        require(secpPubkey.length == 33, "secp pubkey");
        require(blsPubkey.length == 48, "bls pubkey");
        require(secpSig.length == 64, "secp sig");
        require(blsSig.length == 96, "bls sig");
        require(amount >= 100_000 ether, "stake too low");

        vm.startBroadcast(pk);
        ValidatorRegistry reg = new ValidatorRegistry(owner, auth, amount, commission, address(0));
        proposalId = reg.propose(secpPubkey, blsPubkey, secpSig, blsSig);
        validatorId = reg.execute{value: amount}(proposalId);
        vm.stopBroadcast();

        registry = address(reg);
        require(validatorId != 0, "validator id");

        console2.log("registry", registry);
        console2.log("proposalId", proposalId);
        console2.log("validatorId", validatorId);
    }
}
