// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StakingController} from "../../src/staking/StakingController.sol";
import {VeMON} from "../../src/VeMON.sol";
import {VeValidatorFixture} from "./VeValidatorFixture.sol";
import {StakingVault} from "../../src/staking/controlled/StakingVault.sol";
import {StakingAgent} from "../../src/staking/controlled/StakingAgent.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

abstract contract StakingControllerFixture is VeValidatorFixture {
    StakingController internal controller;
    VeMON internal veMON;
    address internal vaultBeacon;
    address internal agentBeacon;

    function setUp() public virtual override {
        super.setUp();
        (controller, vaultBeacon, agentBeacon) = _newController(0);
        veMON = _newVeMON(address(controller));
        controller.setVe(address(veMON));
        controller.setValidatorVe(address(validatorVe));
    }

    function _newController(uint256 initialCommission)
        internal
        returns (StakingController deployed, address deployedVaultBeacon, address deployedAgentBeacon)
    {
        StakingVault vaultImplementation = new StakingVault();
        StakingAgent agentImplementation = new StakingAgent();
        deployedVaultBeacon = address(new UpgradeableBeacon(address(vaultImplementation), address(this)));
        deployedAgentBeacon = address(new UpgradeableBeacon(address(agentImplementation), address(this)));
        StakingController implementation = new StakingController();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                StakingController.initialize,
                (address(this), initialCommission, deployedVaultBeacon, deployedAgentBeacon)
            )
        );
        deployed = StakingController(payable(address(proxy)));
    }

    function _newVeMON(address controller_) internal returns (VeMON deployed) {
        VeMON implementation = new VeMON();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(VeMON.initialize, (controller_, 4, address(this)))
        );
        deployed = VeMON(address(proxy));
    }

    function _setCommission() internal {
        controller.setCommission(commission);
    }
}
