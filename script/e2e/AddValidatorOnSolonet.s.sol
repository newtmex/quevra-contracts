// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {ValidatorRegistry} from "../../src/validators/ValidatorRegistry.sol";

/// @notice Broadcasts request+addValidator against a live Solonet. The runner checks
///         the staking precompile stored the new validator.
contract AddValidatorOnSolonet is Script {
    function run() external returns (address registry, uint256 requestId, uint64 validatorId) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        uint256 amount = vm.envUint("AMOUNT");
        bytes memory payload = vm.envBytes("PAYLOAD");
        bytes memory secpSig = vm.envBytes("SECP_SIG");
        bytes memory blsSig = vm.envBytes("BLS_SIG");

        require(block.chainid == 20143, "not solonet");
        require(payload.length == 165, "payload length");
        require(secpSig.length == 64, "secp sig");
        require(blsSig.length == 96, "bls sig");
        require(amount >= 100_000 ether, "stake too low");

        vm.startBroadcast(pk);
        ValidatorRegistry reg = new ValidatorRegistry();
        requestId = reg.requestValidator(payload, secpSig, blsSig);
        validatorId = reg.addValidator{value: amount}(requestId);
        vm.stopBroadcast();

        registry = address(reg);
        require(validatorId != 0, "validator id");

        console2.log("registry", registry);
        console2.log("requestId", requestId);
        console2.log("validatorId", validatorId);
    }
}
