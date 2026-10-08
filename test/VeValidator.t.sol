// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ValidatorsVoter} from "../src/voting/ValidatorsVoter.sol";
import {StakingController} from "../src/staking/StakingController.sol";
import {IStakingController} from "../src/interfaces/IStakingController.sol";
import {StakingAgent} from "../src/staking/controlled/StakingAgent.sol";
import {StakingVault} from "../src/staking/controlled/StakingVault.sol";
import {VeMON} from "../src/VeMON.sol";
import {VeValidator} from "../src/VeValidator.sol";
import {VeValidatorFixture} from "./fixtures/VeValidatorFixture.sol";

contract VeValidatorTest is VeValidatorFixture {
    StakingController internal controller;
    VeMON internal veMON;
    VeValidator internal veValidator;
    ValidatorsVoter internal validatorsVoter;
    ERC20Mock internal gaugeRewardToken;

    function setUp() public override {
        super.setUp();
        controller = new StakingController(address(this), 0);
        veMON = new VeMON(address(controller), 4);
        controller.setVe(address(veMON));

        validatorsVoter = new ValidatorsVoter(address(veMON), address(0), address(this));
        controller.setBooster(address(validatorsVoter));
        gaugeRewardToken = new ERC20Mock();
        veValidator = new VeValidator(address(controller), address(validatorsVoter), address(gaugeRewardToken), 4);
        validatorsVoter.setBoostableVe(address(veValidator));
        validatorsVoter.whitelistToken(address(gaugeRewardToken), true);
        controller.setValidatorVe(address(veValidator));
    }

    function test_createValidatorCreatesCanonicalPermanentPosition() public {
        bytes32 saltSeed = keccak256("validator");
        address expectedAuthAddress = controller.predictVaultAddress(operator, saltSeed);
        bytes memory payload = _payload(expectedAuthAddress);

        vm.prank(operator);
        uint256 tokenId = veValidator.createValidator(saltSeed, expectedAuthAddress, payload, secpSig, blsSig);

        (uint64 validatorId, address positionOperator, address vault, address gauge, address bribe) =
            veValidator.validatorPosition(tokenId);
        assertEq(veValidator.ownerOf(tokenId), operator);
        assertEq(positionOperator, operator);
        assertEq(validatorId, 0);
        assertTrue(vault != address(0));
        assertTrue(gauge != address(0));
        assertTrue(bribe != address(0));

        (int128 amount, uint256 end, bool permanent,) = veValidator.locked(tokenId);
        assertEq(amount, 0);
        assertEq(end, 0);
        assertTrue(permanent);
    }

    function test_validatorPositionIsSoulboundAndCannotBeApproved() public {
        bytes32 saltSeed = keccak256("soulbound");
        address expectedAuthAddress = controller.predictVaultAddress(operator, saltSeed);
        vm.prank(operator);
        uint256 tokenId =
            veValidator.createValidator(saltSeed, expectedAuthAddress, _payload(expectedAuthAddress), secpSig, blsSig);

        vm.prank(operator);
        vm.expectRevert(VeValidator.ValidatorTokenNonTransferable.selector);
        veValidator.transferFrom(operator, stranger, tokenId);

        vm.prank(operator);
        vm.expectRevert(VeValidator.ValidatorTokenNonTransferable.selector);
        veValidator.approve(stranger, tokenId);
    }

    function test_activeBackingFollowsStakeAndImmediateUnstake() public {
        bytes32 saltSeed = keccak256("backing");
        address expectedAuthAddress = controller.predictVaultAddress(operator, saltSeed);
        vm.prank(operator);
        uint256 validatorTokenId =
            veValidator.createValidator(saltSeed, expectedAuthAddress, _payload(expectedAuthAddress), secpSig, blsSig);

        vm.prank(operator);
        uint256 veTokenId = veMON.createLock{value: validatorStake}(validatorStake, lockDuration);
        (,, address vault,,) = veValidator.validatorPosition(validatorTokenId);
        vm.prank(operator);
        controller.stake(veTokenId, _one(vault), _oneAmount(validatorStake));

        (int128 activeAmount,,,) = veValidator.locked(validatorTokenId);
        assertEq(activeAmount, int128(uint128(validatorStake)));
        (uint64 validatorId,,,,) = veValidator.validatorPosition(validatorTokenId);
        assertGt(validatorId, 0);

        _setEpoch(5, false);
        vm.prank(operator);
        controller.unstake(veTokenId, _one(vault), _oneAmount(validatorStake));
        (activeAmount,,,) = veValidator.locked(validatorTokenId);
        assertEq(activeAmount, 0);
    }

    function test_voteDistributesLockedPrincipalAcrossValidatorGauges() public {
        _setEpoch(5, false);
        uint256 firstValidator = _createValidator(keccak256("first-vote-target"));
        uint256 secondValidator = _createValidator(keccak256("second-vote-target"));
        (,, address firstVault, address firstGauge,) = veValidator.validatorPosition(firstValidator);
        (,, address secondVault, address secondGauge,) = veValidator.validatorPosition(secondValidator);

        uint256 principal = 110_000 ether;
        vm.prank(operator);
        uint256 veTokenId = veMON.createLock{value: principal}(principal, lockDuration);
        address[] memory gauges = new address[](2);
        gauges[0] = firstGauge;
        gauges[1] = secondGauge;
        uint256[] memory voteWeights = new uint256[](2);
        voteWeights[0] = 3;
        voteWeights[1] = 2;

        vm.prank(operator);
        validatorsVoter.vote(veTokenId, gauges, voteWeights);

        uint256 totalVoteWeight =
            validatorsVoter.votes(veTokenId, firstGauge) + validatorsVoter.votes(veTokenId, secondGauge);
        uint256 expectedFirst = principal * validatorsVoter.votes(veTokenId, firstGauge) / totalVoteWeight;
        uint256 expectedSecond = principal - expectedFirst;
        assertEq(controller.intentOf(veTokenId, firstVault), expectedFirst);
        assertEq(controller.intentOf(veTokenId, secondVault), expectedSecond);
        assertEq(controller.allocationOf(veTokenId, firstVault), expectedFirst);
        assertEq(controller.allocationOf(veTokenId, secondVault), expectedSecond);

        // Both shares remain below the per-validator activation minimum, so
        // they are held in their vaults without active validator backing yet.
        (int128 firstBacking,,,) = veValidator.locked(firstValidator);
        (int128 secondBacking,,,) = veValidator.locked(secondValidator);
        assertEq(firstBacking, 0);
        assertEq(secondBacking, 0);
    }

    function test_votePokesVaultAndAgentAllocation() public {
        _setEpoch(5, false);
        uint256 validatorTokenId = _createValidator(keccak256("agent-vote-target"));
        (,, address vault, address gauge,) = veValidator.validatorPosition(validatorTokenId);
        uint256 principal = validatorStake + 10 ether;
        vm.prank(operator);
        uint256 veTokenId = veMON.createLock{value: principal}(principal, lockDuration);

        vm.prank(operator);
        validatorsVoter.vote(veTokenId, _one(gauge), _oneAmount(1));

        (uint64 validatorId,,,,) = veValidator.validatorPosition(validatorTokenId);
        address agent = controller.agentByToken(veTokenId);
        assertEq(controller.intentOf(veTokenId, vault), principal);
        assertEq(controller.allocationOf(veTokenId, vault), principal);
        assertEq(StakingVault(payable(vault)).balanceOf(veTokenId), validatorStake);
        assertEq(StakingAgent(payable(agent)).balanceOf(validatorId), 10 ether);
        (int128 activeBacking,,,) = veValidator.locked(validatorTokenId);
        assertEq(uint256(uint128(activeBacking)), principal);

        _setEpoch(10, false);
        vm.prank(operator);
        validatorsVoter.reset(veTokenId);

        assertEq(controller.intentOf(veTokenId, vault), 0);
        assertEq(controller.pendingOf(veTokenId, vault), principal);
        (activeBacking,,,) = veValidator.locked(validatorTokenId);
        assertEq(activeBacking, 0);
    }

    function test_voteIntentSyncChecksCallerAndAllocationInputs() public {
        _setEpoch(5, false);
        uint256 validatorTokenId = _createValidator(keccak256("intent-validation"));
        (,, address vault,,) = veValidator.validatorPosition(validatorTokenId);

        vm.expectRevert(IStakingController.NotIntentVoter.selector);
        controller.setStakeIntentFromVotes(1, new address[](0), new uint256[](0));

        vm.prank(address(validatorsVoter));
        vm.expectRevert(IStakingController.LengthMismatch.selector);
        controller.setStakeIntentFromVotes(1, _one(vault), new uint256[](0));

        vm.prank(address(validatorsVoter));
        vm.expectRevert(IStakingController.ZeroAmount.selector);
        controller.setStakeIntentFromVotes(1, _one(vault), _oneAmount(0));

        vm.prank(address(validatorsVoter));
        vm.expectRevert(IStakingController.InvalidVault.selector);
        controller.setStakeIntentFromVotes(1, _one(address(0xdead)), _oneAmount(1));

        vm.prank(address(validatorsVoter));
        vm.expectRevert(IStakingController.DuplicateVault.selector);
        controller.setStakeIntentFromVotes(1, _two(vault, vault), _twoAmounts(1, 1));
    }

    function _createValidator(bytes32 saltSeed) private returns (uint256 tokenId) {
        address expectedAuthAddress = controller.predictVaultAddress(operator, saltSeed);
        vm.prank(operator);
        tokenId =
            veValidator.createValidator(saltSeed, expectedAuthAddress, _payload(expectedAuthAddress), secpSig, blsSig);
    }

    function _payload(address authAddress) private view returns (bytes memory) {
        return bytes.concat(
            secpPubkey, blsPubkey, bytes20(authAddress), bytes32(uint256(100_000 ether)), bytes32(uint256(1e17))
        );
    }

    function _one(address value) private pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }

    function _oneAmount(uint256 value) private pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }

    function _two(address first, address second) private pure returns (address[] memory values) {
        values = new address[](2);
        values[0] = first;
        values[1] = second;
    }

    function _twoAmounts(uint256 first, uint256 second) private pure returns (uint256[] memory values) {
        values = new uint256[](2);
        values[0] = first;
        values[1] = second;
    }
}
