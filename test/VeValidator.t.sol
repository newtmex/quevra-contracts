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

    function test_stakeAllocatesVeMONVotingPowerAcrossValidatorGauges() public {
        _setEpoch(5, false);
        uint256 principal = 110_000 ether;
        vm.prank(operator);
        uint256 veTokenId = veMON.createLock{value: principal}(principal, lockDuration);
        _stakeAcrossTwoPreActivationVaults(veTokenId, principal);
    }

    function test_bribeWeightFollowsControllerStakeAndUndelegation() public {
        _setEpoch(5, false);
        uint256 validatorTokenId = _createValidator(keccak256("agent-vote-target"));
        (,, address vault, address gauge,) = veValidator.validatorPosition(validatorTokenId);
        IReward bribe = IReward(validatorsVoter.gaugeToBribe(gauge));
        uint256 principal = validatorStake + 10 ether;
        vm.prank(operator);
        uint256 veTokenId = veMON.createLock{value: principal}(principal, lockDuration);

        assertEq(validatorsVoter.votes(veTokenId, gauge), 0);
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
        assertEq(voteWeight, veMON.votingPowerOf(veTokenId));
        assertEq(bribe.balanceOf(veTokenId), voteWeight);

        _setEpoch(10, false);
        // Voting power decay is picked up the next time staking allocations sync.
        assertEq(validatorsVoter.votes(veTokenId, gauge), voteWeight);
        assertEq(bribe.balanceOf(veTokenId), voteWeight);
        vm.prank(stranger);
        controller.poke(veTokenId);
        voteWeight = veMON.votingPowerOf(veTokenId);
        assertEq(validatorsVoter.votes(veTokenId, gauge), voteWeight);
        assertEq(bribe.balanceOf(veTokenId), voteWeight);

        vm.prank(operator);
        controller.unstake(veTokenId, _one(vault), _oneAmount(principal));

        assertEq(bribe.balanceOf(veTokenId), 0);
        assertEq(validatorsVoter.votes(veTokenId, gauge), 0);
        assertEq(validatorsVoter.weights(gauge), 0);
        assertEq(validatorsVoter.usedWeights(veTokenId), 0);
        assertEq(controller.pendingOf(veTokenId, vault), principal);
        (activeBacking,,,) = veValidator.locked(validatorTokenId);
        assertEq(activeBacking, 0);
    }

    function test_rebalancePokeMovesVoteWeightWithPhysicalStake() public {
        _setEpoch(5, false);
        uint256 firstValidator = _createValidator(keccak256("rebalance-vote-a"));
        uint256 secondValidator = _createValidatorWithKey(keccak256("rebalance-vote-b"), 2);
        (,, address firstVault, address firstGauge,) = veValidator.validatorPosition(firstValidator);
        (,, address secondVault, address secondGauge,) = veValidator.validatorPosition(secondValidator);

        uint256 principal = validatorStake;
        vm.prank(operator);
        uint256 veTokenId = veMON.createLock{value: principal}(principal, lockDuration);
        vm.prank(operator);
        controller.stake(veTokenId, _one(firstVault), _oneAmount(principal));
        (uint64 firstValidatorId,,,,) = veValidator.validatorPosition(firstValidator);

        uint256 initialWeight = veMON.votingPowerOf(veTokenId);
        assertEq(validatorsVoter.votes(veTokenId, firstGauge), initialWeight);
        assertEq(validatorsVoter.votes(veTokenId, secondGauge), 0);

        _setEpoch(10, false);
        vm.prank(operator);
        controller.stake(veTokenId, _one(secondVault), _oneAmount(principal));
        assertEq(controller.allocationOf(veTokenId, firstVault), 0);
        assertEq(controller.allocationOf(veTokenId, secondVault), 0);
        assertEq(validatorsVoter.votes(veTokenId, firstGauge), 0);
        assertEq(validatorsVoter.votes(veTokenId, secondGauge), 0);

        (,, uint64 withdrawEpoch) = staking.getWithdrawalRequest(firstValidatorId, firstVault, 0);
        _setEpoch(withdrawEpoch + 1, false);
        vm.prank(stranger);
        assertTrue(controller.poke(veTokenId));

        uint256 refreshedWeight = veMON.votingPowerOf(veTokenId);
        assertEq(controller.allocationOf(veTokenId, secondVault), principal);
        assertEq(validatorsVoter.votes(veTokenId, firstGauge), 0);
        assertEq(validatorsVoter.votes(veTokenId, secondGauge), refreshedWeight);
        assertEq(IReward(validatorsVoter.gaugeToBribe(firstGauge)).balanceOf(veTokenId), 0);
        assertEq(IReward(validatorsVoter.gaugeToBribe(secondGauge)).balanceOf(veTokenId), refreshedWeight);
    }

    function test_preActivationVaultDepositsImmediatelyAccrueVoteWeight() public {
        _setEpoch(5, false);
        uint256 validatorTokenId = _createValidator(keccak256("shared-vault-votes"));
        (,, address vault, address gauge,) = veValidator.validatorPosition(validatorTokenId);
        IReward bribe = IReward(validatorsVoter.gaugeToBribe(gauge));

        vm.prank(operator);
        uint256 firstTokenId = veMON.createLock{value: validatorStake / 2}(validatorStake / 2, lockDuration);
        vm.prank(stranger);
        uint256 secondTokenId = veMON.createLock{value: validatorStake / 2}(validatorStake / 2, lockDuration);
        vm.prank(operator);
        controller.stake(firstTokenId, _one(vault), _oneAmount(validatorStake / 2));
        uint256 firstWeight = veMON.votingPowerOf(firstTokenId);
        assertEq(validatorsVoter.votes(firstTokenId, gauge), firstWeight);
        assertEq(bribe.balanceOf(firstTokenId), firstWeight);
        assertEq(bribe.balanceOf(secondTokenId), 0);

        vm.prank(stranger);
        controller.stake(secondTokenId, _one(vault), _oneAmount(validatorStake / 2));

        assertEq(bribe.balanceOf(firstTokenId), firstWeight);
        assertEq(validatorsVoter.votes(firstTokenId, gauge), firstWeight);
        assertEq(bribe.balanceOf(secondTokenId), validatorsVoter.votes(secondTokenId, gauge));
        assertEq(validatorsVoter.votes(secondTokenId, gauge), veMON.votingPowerOf(secondTokenId));
    }

    function test_onlyControllerCanSyncStakeAllocation() public {
        vm.expectRevert(ValidatorsVoter.NotStakingController.selector);
        vm.prank(operator);
        validatorsVoter.syncStakeAllocation(1, address(0xdead), 0);
    }

    function _createValidator(bytes32 saltSeed) private returns (uint256 tokenId) {
        address expectedAuthAddress = controller.predictVaultAddress(operator, saltSeed);
        vm.prank(operator);
        tokenId =
            veValidator.createValidator(saltSeed, expectedAuthAddress, _payload(expectedAuthAddress), secpSig, blsSig);
    }

    function _createValidatorWithKey(bytes32 saltSeed, uint8 keyNumber) private returns (uint256 tokenId) {
        address expectedAuthAddress = controller.predictVaultAddress(operator, saltSeed);
        vm.prank(operator);
        tokenId = veValidator.createValidator(
            saltSeed, expectedAuthAddress, _payloadWithKey(expectedAuthAddress, keyNumber), secpSig, blsSig
        );
    }

    function _stakeAcrossTwoPreActivationVaults(uint256 veTokenId, uint256 principal) private {
        uint256 firstValidator = _createValidator(keccak256("first-vote-target"));
        uint256 secondValidator = _createValidator(keccak256("second-vote-target"));
        (,, address firstVault, address firstGauge,) = veValidator.validatorPosition(firstValidator);
        (,, address secondVault, address secondGauge,) = veValidator.validatorPosition(secondValidator);

        address[] memory vaults = new address[](2);
        vaults[0] = firstVault;
        vaults[1] = secondVault;
        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 60_000 ether;
        allocations[1] = principal - allocations[0];

        vm.prank(operator);
        controller.stake(veTokenId, vaults, allocations);

        _assertVoteShare(veTokenId, firstGauge, allocations[0], principal);
        _assertVoteShare(veTokenId, secondGauge, allocations[1], principal);
        assertEq(controller.allocationOf(veTokenId, firstVault), allocations[0]);
        assertEq(controller.allocationOf(veTokenId, secondVault), allocations[1]);

        // Deposits count while the validator vault is still building its
        // minimum activation stake.
        (int128 firstBacking,,,) = veValidator.locked(firstValidator);
        (int128 secondBacking,,,) = veValidator.locked(secondValidator);
        assertEq(firstBacking, 0);
        assertEq(secondBacking, 0);
    }

    function _assertVoteShare(uint256 veTokenId, address gauge, uint256 allocation, uint256 principal) private view {
        uint256 expected = veMON.votingPowerOf(veTokenId) * allocation / principal;
        assertEq(validatorsVoter.votes(veTokenId, gauge), expected);
        assertEq(validatorsVoter.weights(gauge), expected);
        assertEq(IReward(validatorsVoter.gaugeToBribe(gauge)).balanceOf(veTokenId), expected);
    }

    function _payload(address authAddress) private view returns (bytes memory) {
        return bytes.concat(
            secpPubkey, blsPubkey, bytes20(authAddress), bytes32(uint256(100_000 ether)), bytes32(uint256(1e17))
        );
    }

    function _payloadWithKey(address authAddress, uint8 keyNumber) private view returns (bytes memory) {
        bytes memory uniqueSecpPubkey = hex"02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5";
        bytes memory uniqueBlsPubkey =
            hex"a572cbea904d67468808c8eb50a9450c9721db309128012543902d0ac358a62ae28f75bb8f1c7c42c39a8c5529bf0f4e";
        if (keyNumber == 1) return _payload(authAddress);
        return bytes.concat(
            uniqueSecpPubkey,
            uniqueBlsPubkey,
            bytes20(authAddress),
            bytes32(uint256(100_000 ether)),
            bytes32(uint256(1e17))
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
