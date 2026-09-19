// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StakingVault} from "../src/StakingVault.sol";
import {ValidatorGaugeFixture} from "./fixtures/ValidatorGaugeFixture.sol";

contract ValidatorGaugeTest is ValidatorGaugeFixture {
    function test_constructorStoresValidatorTargetMetadata() public view {
        assertEq(gauge.registry(), address(registry));
        assertEq(gauge.vault(), gaugeVault);
        assertEq(gauge.operator(), operator);
        assertEq(gauge.requestId(), gaugeRequestId);
        assertEq(gauge.validatorId(), 0);
    }

    function test_validatorIdTracksRegistryProposal() public {
        StakingVault vault = StakingVault(payable(gaugeVault));

        vm.deal(address(controller), 1_000_000 ether);
        vm.prank(address(controller));
        uint64 validatorId = vault.addValidator{value: validatorStake}(commission);

        assertEq(gauge.validatorId(), validatorId);
    }
}
