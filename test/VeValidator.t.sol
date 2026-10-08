// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {BoostVoter} from "../src/voting/BoostVoter.sol";
import {StakingController} from "../src/staking/StakingController.sol";
import {VeMON} from "../src/VeMON.sol";
import {VeValidator} from "../src/VeValidator.sol";
import {VeValidatorFixture} from "./fixtures/VeValidatorFixture.sol";

contract VeValidatorTest is VeValidatorFixture {
    StakingController internal controller;
    VeMON internal veMON;
    VeValidator internal veValidator;
    BoostVoter internal boostVoter;
    ERC20Mock internal gaugeRewardToken;

    function setUp() public override {
        super.setUp();
        controller = new StakingController(address(this), 0);
        veMON = new VeMON(address(controller), 4);
        controller.setVe(address(veMON));

        boostVoter = new BoostVoter(address(veMON), address(0), address(this));
        gaugeRewardToken = new ERC20Mock();
        veValidator = new VeValidator(address(controller), address(boostVoter), address(gaugeRewardToken), 4);
        boostVoter.setBoostableVe(address(veValidator));
        boostVoter.whitelistToken(address(gaugeRewardToken), true);
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
