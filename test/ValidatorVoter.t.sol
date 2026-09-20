// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IValidatorRegistry} from "../src/interfaces/IValidatorRegistry.sol";
import {IValidatorVoter} from "../src/interfaces/IValidatorVoter.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {ValidatorGauge} from "../src/ValidatorGauge.sol";
import {ValidatorVoter} from "../src/ValidatorVoter.sol";
import {StakingController} from "../src/StakingController.sol";
import {ValidatorVoterFixture} from "./fixtures/ValidatorVoterFixture.sol";

contract ValidatorVoterTest is ValidatorVoterFixture {
    function test_voteResetAndPokeTrackCycleGaugeWeight() public {
        _setEpoch(1, false);
        (uint256 requestId,, address gaugeAddress) = _createValidatorStack();
        voter.setValidatorAccepted(requestId, 0, true);
        uint256 tokenId;
        vm.prank(operator);
        tokenId = veMON.createLock{value: 100 ether}(100 ether, lockDuration);
        uint256 secondTokenId;
        vm.prank(stranger);
        secondTokenId = veMON.createLock{value: 70 ether}(70 ether, lockDuration);

        address[] memory gauges = new address[](1);
        gauges[0] = gaugeAddress;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;
        vm.prank(operator);
        voter.vote(tokenId, gauges, weights);
        vm.prank(stranger);
        voter.vote(secondTokenId, gauges, weights);
        uint256 firstWeight = voter.voterWeight(tokenId, gaugeAddress, 0);
        uint256 secondWeight = voter.voterWeight(secondTokenId, gaugeAddress, 0);
        assertGt(firstWeight, 0);
        assertGt(secondWeight, 0);
        assertEq(voter.totalGaugeWeight(gaugeAddress, 0), firstWeight + secondWeight);

        vm.prank(operator);
        voter.poke(tokenId);
        assertEq(voter.voterWeight(tokenId, gaugeAddress, 0), firstWeight);
        vm.prank(operator);
        voter.reset(tokenId);
        assertEq(voter.voterWeight(tokenId, gaugeAddress, 0), 0);
        assertEq(voter.totalGaugeWeight(gaugeAddress, 0), secondWeight);

        _setEpoch(6, false);
        voter.setValidatorAccepted(requestId, 1, true);
        vm.prank(operator);
        voter.vote(tokenId, gauges, weights);
        assertEq(voter.voterWeight(tokenId, gaugeAddress, 0), 0);
        assertEq(voter.totalGaugeWeight(gaugeAddress, 0), secondWeight);
        assertGt(voter.voterWeight(tokenId, gaugeAddress, 1), 0);
    }

    function test_votesCanRankRequestsBeforeCycleAcceptance() public {
        _setEpoch(1, false);
        (,, address gaugeAddress) = _createValidatorStack();
        uint256 tokenId;
        vm.prank(operator);
        tokenId = veMON.createLock{value: 100 ether}(100 ether, lockDuration);
        address[] memory gauges = new address[](1);
        gauges[0] = gaugeAddress;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;
        vm.prank(operator);
        voter.vote(tokenId, gauges, weights);
        assertGt(voter.totalGaugeWeight(gaugeAddress, 0), 0);
    }

    function test_finalizeCycleAcceptsHighestVotedRequestsWithinCapacity() public {
        _setEpoch(1, false);
        (,, address firstGauge) = _createValidatorStack();

        bytes memory secondSecp = bytes.concat(bytes1(0x02), bytes32(uint256(7)));
        bytes memory secondBls = bytes.concat(bytes1(0x97), new bytes(47));
        address predicted = controller.predictVaultAddress(operator, secondSecp, secondBls);
        vm.prank(operator);
        (,, address secondGauge) = voter.createValidator(predicted, secondSecp, secondBls, secpSig, blsSig);

        uint256 tokenId;
        vm.prank(operator);
        tokenId = veMON.createLock{value: 100 ether}(100 ether, lockDuration);
        address[] memory gauges = new address[](2);
        gauges[0] = firstGauge;
        gauges[1] = secondGauge;
        uint256[] memory weights = new uint256[](2);
        weights[0] = 9;
        weights[1] = 1;
        vm.prank(operator);
        voter.vote(tokenId, gauges, weights);

        vm.mockCall(
            address(controller),
            abi.encodeWithSelector(StakingController.maxAdmissibleValidators.selector),
            abi.encode(uint256(1))
        );
        _setEpoch(6, false);
        voter.finalizeCycle(0);
        assertTrue(voter.validatorAccepted(1, 0));
        assertFalse(voter.validatorAccepted(2, 0));
        assertTrue(voter.cycleFinalized(0));
        vm.clearMockedCalls();
    }

    function test_managedPositionVotesItsAggregatedEscrowPower() public {
        _setEpoch(1, false);
        (uint256 requestId,, address gaugeAddress) = _createValidatorStack();
        voter.setValidatorAccepted(requestId, 0, true);
        uint256 managedId;
        vm.prank(operator);
        managedId = veMON.createManagedLock();
        uint256 childId;
        vm.prank(stranger);
        childId = veMON.createLock{value: 100 ether}(100 ether, lockDuration);
        vm.prank(stranger);
        veMON.depositManaged(childId, managedId);

        address[] memory gauges = new address[](1);
        gauges[0] = gaugeAddress;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;
        vm.prank(operator);
        voter.vote(managedId, gauges, weights);

        assertGt(voter.voterWeight(managedId, gaugeAddress, 0), 0);
        assertEq(voter.voterWeight(childId, gaugeAddress, 0), 0);
    }

    function test_createValidatorRequestsAndDeploysVaultAndGaugeAtomically() public {
        (uint256 id, address vaultAddress, address gaugeAddress) = _createValidatorStack();

        IValidatorVoter.ValidatorStack memory stack = voter.stackByRequest(id);
        assertEq(stack.vault, vaultAddress);
        assertEq(stack.gauge, gaugeAddress);
        assertEq(stack.validatorId, 0);
        assertEq(stack.operator, operator);

        StakingVault vault = StakingVault(payable(vaultAddress));
        ValidatorGauge gauge = ValidatorGauge(gaugeAddress);
        assertEq(vault.owner(), address(controller));
        assertEq(address(vault.registry()), address(registry));
        assertEq(vault.requestId(), id);
        assertEq(gauge.registry(), address(registry));
        assertEq(gauge.vault(), vaultAddress);
        assertEq(gauge.operator(), operator);
        assertEq(gauge.requestId(), id);
        assertEq(gauge.validatorId(), 0);
    }

    function test_createValidatorRejectsInvalidDataBeforeRequestOrDeployment() public {
        address invalidPrediction = controller.predictVaultAddress(operator, hex"01", blsPubkey);
        vm.prank(operator);
        vm.expectRevert(IValidatorRegistry.InvalidValidatorData.selector);
        voter.createValidator(invalidPrediction, hex"01", blsPubkey, secpSig, blsSig);

        assertEq(registry.nextId(), 1);
    }

    function test_onlyOperatorCanCancelThroughVoter() public {
        (uint256 id,,) = _createValidatorStack();

        vm.prank(address(this));
        vm.expectRevert(IValidatorVoter.NotRequestOperator.selector);
        voter.cancel(id);

        vm.prank(operator);
        voter.cancel(id);

        assertEq(uint256(registry.getProposal(id).status), uint256(IValidatorRegistry.Status.Cancelled));
        assertEq(voter.stackByRequest(id).vault, address(0));
    }

    function test_controllerFailureRollsBackGaugeAndRegistry() public {
        address predicted = controller.predictVaultAddress(operator, secpPubkey, blsPubkey);
        address predictedGauge = vm.computeCreateAddress(address(voter), vm.getNonce(address(voter)));
        vm.mockCallRevert(
            address(controller), abi.encodeWithSelector(StakingController.deployVault.selector), hex"12345678"
        );

        vm.prank(operator);
        vm.expectRevert(bytes4(hex"12345678"));
        voter.createValidator(initialVault, secpPubkey, blsPubkey, secpSig, blsSig);

        assertEq(predicted.code.length, 0);
        assertEq(predictedGauge.code.length, 0);
        assertEq(registry.nextId(), 1);
        assertEq(voter.stackByRequest(1).vault, address(0));
        vm.clearMockedCalls();
    }

    function test_onlyOwnerCanUpdateRewardTokenWhitelist() public {
        address token = makeAddr("token");
        vm.prank(stranger);
        vm.expectRevert();
        voter.setRewardTokenWhitelisted(token, true);

        voter.setRewardTokenWhitelisted(token, true);
        assertTrue(voter.isRewardTokenWhitelisted(token));
        voter.setRewardTokenWhitelisted(token, false);
        assertFalse(voter.isRewardTokenWhitelisted(token));
    }

    function test_onlyOwnerCanSetValidatorAcceptance() public {
        (uint256 id,,) = _createValidatorStack();
        _setEpoch(5, false);
        vm.prank(stranger);
        vm.expectRevert();
        voter.setValidatorAccepted(id, 1, true);

        voter.setValidatorAccepted(id, 1, true);
        assertTrue(voter.validatorAccepted(id, 1));
    }
}
