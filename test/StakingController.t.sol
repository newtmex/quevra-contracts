// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ValidatorsVoter} from "../src/ValidatorsVoter.sol";
import {FactoryRegistry} from "../src/factories/FactoryRegistry.sol";
import {GaugeFactory} from "../src/factories/GaugeFactory.sol";
import {VotingRewardsFactory} from "../src/factories/VotingRewardsFactory.sol";

import {StakingController} from "../src/staking/StakingController.sol";
import {IStakingController} from "../src/interfaces/IStakingController.sol";
import {StakingControllerFixture} from "./fixtures/StakingControllerFixture.sol";
import {ValidatorsVoterFixture} from "./fixtures/ValidatorsVoterFixture.sol";
import {StakingVault} from "../src/staking/controlled/StakingVault.sol";
import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";

contract StakingControllerTest is StakingControllerFixture {
    function test_constructorSetsRegistryAndVaultImplementation() public view {
        assertEq(address(controller.registry()), address(registry));
        assertEq(controller.owner(), address(this));
        assertTrue(address(veMON) != address(controller));
        assertTrue(controller.vaultImplementation() != address(0));
    }

    function test_constructorSetsInitialCommissionImmediately() public {
        StakingController configured = new StakingController(address(registry), address(this), commission);
        assertEq(configured.commission(), commission);
    }

    function test_constructorRejectsCommissionAboveMaximum() public {
        vm.expectRevert(IStakingController.InvalidCommission.selector);
        new StakingController(address(registry), address(this), 1e18 + 1);
    }

    function test_voterIsOwnerSetOnce() public {
        address voter = makeAddr("voter");
        address replacement = makeAddr("replacement-voter");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        vm.prank(operator);
        controller.setVoter(voter);

        controller.setVoter(voter);

        vm.expectRevert(IStakingController.VoterAlreadySet.selector);
        controller.setVoter(replacement);
    }

    function test_onlyOwnerCanSetCommission() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        vm.prank(operator);
        controller.setCommission(commission);

        vm.expectEmit(false, false, false, true);
        emit IStakingController.ValidatorCommissionScheduled(commission, 2);
        _setCommission();

        assertEq(controller.commission(), 0);
    }

    function test_setCommissionEnforcesPrecompileMaximum() public {
        controller.setCommission(controller.MAX_COMMISSION());
        assertEq(controller.commission(), 0);

        uint256 invalidCommission = controller.MAX_COMMISSION() + 1;
        vm.expectRevert(IStakingController.InvalidCommission.selector);
        controller.setCommission(invalidCommission);
    }

    function test_scheduledCommissionTakesEffectAtCyclePlusTwo() public {
        _setEpoch(9, false);
        controller.setCommission(commission);
        assertEq(controller.commission(), 0);

        _setEpoch(14, false);
        assertEq(controller.commission(), 0);
        _setEpoch(15, false);
        assertEq(controller.commission(), commission);
        assertEq(controller.commission(), commission);
    }

    function test_signingConfigForUsesFixedStakeAmount() public {
        controller.setVoter(makeAddr("voter"));
        bytes32 saltSeed = keccak256("controller-test");
        (address authAddress, uint256 configuredCommission, uint256 amount) =
            controller.signingConfigFor(operator, saltSeed);

        assertEq(authAddress, controller.predictVaultAddress(operator, saltSeed));
        assertEq(configuredCommission, 0);
        assertEq(amount, controller.VALIDATOR_STAKE_AMOUNT());
    }

    function test_depositOnlyAcceptsMONFromVeMONAndTracksTokenId() public {
        FactoryRegistry factoryRegistry = new FactoryRegistry();
        GaugeFactory gaugeFactory = new GaugeFactory();
        VotingRewardsFactory rewardsFactory = new VotingRewardsFactory();
        factoryRegistry.approveGaugeFactory(address(gaugeFactory), address(rewardsFactory));
        address forwarder = makeAddr("controller-test-forwarder");
        ValidatorsVoter implementation = new ValidatorsVoter(forwarder);
        bytes memory init = abi.encodeCall(
            ValidatorsVoter.initialize,
            (
                address(veMON),
                address(factoryRegistry),
                address(0),
                address(registry),
                address(controller),
                address(gaugeFactory)
            )
        );
        ValidatorsVoter voter = ValidatorsVoter(address(new ERC1967Proxy(address(implementation), init)));
        controller.setVoter(address(voter));

        vm.prank(operator);
        (bool success,) = address(controller).call{value: validatorStake}("");
        assertFalse(success);

        vm.prank(operator);
        veMON.createLock{value: validatorStake}(validatorStake, lockDuration);
        assertEq(address(controller).balance, validatorStake);
        assertEq(controller.balanceOf(1), validatorStake);
    }
}

contract StakingControllerUnstakeTest is ValidatorsVoterFixture {
    function test_stakeThenUnstakeAndWithdrawRestoresMONWithoutMocks() public {
        (,, address gauge) = _createValidator();
        uint256 amount = validatorStake;

        vm.prank(operator);
        veMON.createLock{value: amount}(amount, lockDuration);

        address[] memory gauges = new address[](1);
        gauges[0] = gauge;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.prank(address(validatorsVoter));
        controller.stake(1, gauges, amounts);
        assertEq(controller.balanceOf(1), 0);

        // Validator activation/delegation becomes an active stake at the next epoch.
        _setEpoch(1, false);
        vm.prank(address(validatorsVoter));
        controller.unstake(1, gauges, amounts);

        // Read the actual maturity epoch instead of assuming a fixed delay.
        address vault = controller.vaultByGauge(gauge);
        uint64 validatorId = StakingVault(payable(vault)).validatorId();
        (,, uint64 withdrawEpoch) = staking.getWithdrawalRequest(validatorId, vault, 0);
        _setEpoch(withdrawEpoch + 1, false);
        vm.prank(address(validatorsVoter));
        controller.withdraw(1, gauges);

        assertEq(controller.balanceOf(1), amount);
    }
}
