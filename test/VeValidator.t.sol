// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ValidatorsVoter} from "../src/voting/ValidatorsVoter.sol";
import {StakingController} from "../src/staking/StakingController.sol";
import {IReward} from "../src/interfaces/IReward.sol";
import {IVotingEscrow} from "../src/interfaces/IVotingEscrow.sol";
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

    function test_escrowsExposeTheirConfiguredVoter() public view {
        assertEq(veMON.controller(), address(controller));
        assertEq(veValidator.controller(), address(controller));
        assertEq(veMON.voter(), address(0));
        assertEq(veValidator.voter(), address(validatorsVoter));
    }

    function test_configuredVoterCanUpdateVeValidatorBoost() public {
        uint256 tokenId = _createValidator(keccak256("boost-authorization"));

        validatorsVoter.poke(tokenId);

        (,,, uint256 boost) = veValidator.locked(tokenId);
        assertEq(boost, 1 ether);
    }

    function test_unconfiguredCallerCannotUpdateVeValidatorBoost() public {
        uint256 tokenId = _createValidator(keccak256("unauthorized-boost"));

        vm.expectRevert(IVotingEscrow.NotVoter.selector);
        vm.prank(stranger);
        veValidator.updateBoost(tokenId, 1 ether);
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
        assertEq(controller.validatorBackingOf(validatorTokenId), validatorStake);
        assertEq(veValidator.votingPowerOf(validatorTokenId), validatorStake);
        assertEq(veValidator.totalVotingPower(), validatorStake);
        (uint64 validatorId,,,,) = veValidator.validatorPosition(validatorTokenId);
        assertGt(validatorId, 0);

        _setEpoch(5, false);
        vm.prank(operator);
        controller.unstake(veTokenId, _one(vault), _oneAmount(validatorStake));
        (activeAmount,,,) = veValidator.locked(validatorTokenId);
        assertEq(activeAmount, 0);
        assertEq(controller.validatorBackingOf(validatorTokenId), 0);
        assertEq(veValidator.votingPowerOf(validatorTokenId), 0);
        assertEq(veValidator.totalVotingPower(), 0);
        assertEq(veValidator.votingPowerOfAt(validatorTokenId, 0), validatorStake);
        assertEq(veValidator.votingPowerOfAt(validatorTokenId, 5), 0);
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
        assertEq(totalVoteWeight, veMON.votingPowerOf(veTokenId));
        assertEq(controller.intentOf(veTokenId, firstVault), 0);
        assertEq(controller.intentOf(veTokenId, secondVault), 0);
        assertEq(controller.allocationOf(veTokenId, firstVault), 0);
        assertEq(controller.allocationOf(veTokenId, secondVault), 0);
        assertEq(IReward(validatorsVoter.gaugeToBribe(firstGauge)).balanceOf(veTokenId), 0);
        assertEq(IReward(validatorsVoter.gaugeToBribe(secondGauge)).balanceOf(veTokenId), 0);

        // Voting power is recorded by the voter without changing controller allocations.
        (int128 firstBacking,,,) = veValidator.locked(firstValidator);
        (int128 secondBacking,,,) = veValidator.locked(secondValidator);
        assertEq(firstBacking, 0);
        assertEq(secondBacking, 0);
    }

    function test_bribeWeightFollowsControllerStakeAndUndelegation() public {
        _setEpoch(5, false);
        uint256 validatorTokenId = _createValidator(keccak256("agent-vote-target"));
        (,, address vault, address gauge,) = veValidator.validatorPosition(validatorTokenId);
        IReward bribe = IReward(validatorsVoter.gaugeToBribe(gauge));
        uint256 principal = validatorStake + 10 ether;
        vm.prank(operator);
        uint256 veTokenId = veMON.createLock{value: principal}(principal, lockDuration);

        vm.prank(operator);
        validatorsVoter.vote(veTokenId, _one(gauge), _oneAmount(1));

        assertEq(validatorsVoter.votes(veTokenId, gauge), veMON.votingPowerOf(veTokenId));
        assertEq(bribe.balanceOf(veTokenId), 0);
        assertEq(controller.balanceOf(veTokenId), principal);
        assertEq(controller.intentOf(veTokenId, vault), 0);
        assertEq(controller.allocationOf(veTokenId, vault), 0);
        assertEq(controller.agentByToken(veTokenId), address(0));
        (int128 activeBacking,,,) = veValidator.locked(validatorTokenId);
        assertEq(activeBacking, 0);

        vm.prank(operator);
        controller.stake(veTokenId, _one(vault), _oneAmount(principal));
        uint256 voteWeight = validatorsVoter.votes(veTokenId, gauge);
        assertEq(bribe.balanceOf(veTokenId), voteWeight);
        assertEq(validatorsVoter.stakeRewardWeight(veTokenId, gauge), voteWeight);

        _setEpoch(10, false);
        vm.prank(operator);
        validatorsVoter.reset(veTokenId);

        assertEq(validatorsVoter.votes(veTokenId, gauge), 0);
        assertEq(validatorsVoter.usedWeights(veTokenId), 0);
        // The bribe weight remains while the MON is still allocated to the validator.
        assertEq(bribe.balanceOf(veTokenId), voteWeight);

        vm.prank(operator);
        controller.unstake(veTokenId, _one(vault), _oneAmount(principal));

        assertEq(bribe.balanceOf(veTokenId), 0);
        assertEq(validatorsVoter.stakeRewardWeight(veTokenId, gauge), 0);
        assertEq(controller.pendingOf(veTokenId, vault), principal);
        (activeBacking,,,) = veValidator.locked(validatorTokenId);
        assertEq(activeBacking, 0);
    }

    function test_validatorActivationDepositsBribeWeightForExistingVaultBackers() public {
        _setEpoch(5, false);
        uint256 validatorTokenId = _createValidator(keccak256("shared-vault-votes"));
        (,, address vault, address gauge,) = veValidator.validatorPosition(validatorTokenId);
        IReward bribe = IReward(validatorsVoter.gaugeToBribe(gauge));

        vm.prank(operator);
        uint256 firstTokenId = veMON.createLock{value: validatorStake / 2}(validatorStake / 2, lockDuration);
        vm.prank(stranger);
        uint256 secondTokenId = veMON.createLock{value: validatorStake / 2}(validatorStake / 2, lockDuration);
        vm.prank(operator);
        validatorsVoter.vote(firstTokenId, _one(gauge), _oneAmount(1));
        vm.prank(stranger);
        validatorsVoter.vote(secondTokenId, _one(gauge), _oneAmount(1));

        vm.prank(operator);
        controller.stake(firstTokenId, _one(vault), _oneAmount(validatorStake / 2));
        assertEq(bribe.balanceOf(firstTokenId), 0);
        assertEq(bribe.balanceOf(secondTokenId), 0);

        vm.prank(stranger);
        controller.stake(secondTokenId, _one(vault), _oneAmount(validatorStake / 2));

        assertEq(bribe.balanceOf(firstTokenId), validatorsVoter.votes(firstTokenId, gauge));
        assertEq(bribe.balanceOf(secondTokenId), validatorsVoter.votes(secondTokenId, gauge));
    }

    function test_onlyControllerCanSyncStakeRewardWeight() public {
        vm.expectRevert(ValidatorsVoter.NotStakingController.selector);
        vm.prank(operator);
        validatorsVoter.syncStakeWeight(1, address(0xdead));
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
}
