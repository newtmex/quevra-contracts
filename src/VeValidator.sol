// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VotingEscrow} from "./VotingEscrow.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IStakingController} from "./interfaces/IStakingController.sol";
import {IValidatorsVoter} from "./interfaces/IValidatorsVoter.sol";
import {IVeValidator} from "./interfaces/IVeValidator.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {SafeCastLibrary} from "./libraries/SafeCastLibrary.sol";

/// @title veValidator
/// @notice Soulbound permanent veNFTs representing Quevra validator identities.
/// @dev Validator positions are minted only by the registration flow. Their
///      amount is active validator backing, managed by the staking controller.
contract VeValidator is VotingEscrow, IVeValidator {
    using SafeCastLibrary for uint256;
    using SafeCastLibrary for int128;

    struct ValidatorPosition {
        uint64 validatorId;
        address operator;
        address vault;
        address gauge;
        address bribeVotingRewards;
    }

    IStakingController public immutable controller;
    IValidatorsVoter public immutable validatorsVoter;
    address public immutable gaugeRewardToken;

    mapping(uint256 tokenId => ValidatorPosition) public override validatorPosition;
    mapping(address vault => uint256 tokenId) public tokenIdForVault;
    mapping(uint256 tokenId => IVeValidator.ValidatorSubmission) private _validatorSubmissions;

    error InvalidAddress();
    error NotController();
    error ValidatorTokenNonTransferable();
    error ValidatorPositionExists();
    error InvalidValidatorPosition();

    constructor(address controller_, address validatorsVoter_, address gaugeRewardToken_, uint64 maxLockCycles_)
        VotingEscrow(maxLockCycles_, "Validator", "veValidator")
    {
        if (controller_ == address(0) || validatorsVoter_ == address(0) || gaugeRewardToken_ == address(0)) {
            revert InvalidAddress();
        }
        controller = IStakingController(controller_);
        validatorsVoter = IValidatorsVoter(validatorsVoter_);
        gaugeRewardToken = gaugeRewardToken_;
    }

    function createValidator(
        bytes32 saltSeed,
        address expectedAuthAddress,
        bytes calldata payload,
        bytes calldata signedSecpMessage,
        bytes calldata signedBlsMessage
    ) external nonReentrant returns (uint256 tokenId) {
        address operator = msg.sender;
        tokenId = _mintPermanentPosition(operator);
        _validatorSubmissions[tokenId] =
            IVeValidator.ValidatorSubmission(payload, signedSecpMessage, signedBlsMessage, operator, false, 0);
        address vault = controller.deployValidatorVault(operator, tokenId, saltSeed, expectedAuthAddress);
        address gauge = validatorsVoter.createBoostGauge(tokenId, gaugeRewardToken, vault);
        address bribe = validatorsVoter.gaugeToBribe(gauge);
        _register(tokenId, operator, vault, gauge, bribe);
    }

    function createExistingValidator(uint64 validatorId, bytes32 saltSeed)
        external
        nonReentrant
        returns (uint256 tokenId)
    {
        address operator = msg.sender;
        tokenId = _mintPermanentPosition(operator);
        _validatorSubmissions[tokenId] = IVeValidator.ValidatorSubmission("", "", "", operator, true, validatorId);
        address vault = controller.deployValidatorVault(
            operator, tokenId, saltSeed, controller.predictVaultAddress(operator, saltSeed)
        );
        address gauge = validatorsVoter.createBoostGauge(tokenId, gaugeRewardToken, vault);
        address bribe = validatorsVoter.gaugeToBribe(gauge);
        _register(tokenId, operator, vault, gauge, bribe);
    }

    function validatorSubmission(uint256 tokenId) external view override returns (ValidatorSubmission memory) {
        return _validatorSubmissions[tokenId];
    }

    function approve(address, uint256) public pure override(ERC721, IERC721) {
        revert ValidatorTokenNonTransferable();
    }

    function setApprovalForAll(address, bool) public pure override(ERC721, IERC721) {
        revert ValidatorTokenNonTransferable();
    }

    function setValidatorIdFromController(uint256 tokenId, uint64 validatorId) external override {
        _requireController();
        ValidatorPosition storage position = validatorPosition[tokenId];
        if (position.operator == address(0) || validatorId == 0 || position.validatorId != 0) {
            revert InvalidValidatorPosition();
        }
        position.validatorId = validatorId;
    }

    function _requireController() internal view override {
        if (msg.sender != address(controller)) revert NotController();
    }

    function _amountOf(uint256 tokenId) internal view override returns (int128) {
        return controller.validatorBackingOf(tokenId).toInt128();
    }

    function _mintPermanentPosition(address to) internal returns (uint256 tokenId) {
        if (to == address(0)) revert InvalidValidatorPosition();
        tokenId = nextId++;
        IVotingEscrow.LockedBalance memory newLock = IVotingEscrow.LockedBalance(0, 0, true, 0);
        _checkpointLock(tokenId, IVotingEscrow.LockedBalance(0, 0, false, 0), newLock);
        _lockData[tokenId] = LockData(0, true, 0);
        _safeMint(to, tokenId);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = _ownerOf(tokenId);
        if (from != address(0)) revert ValidatorTokenNonTransferable();
        return super._update(to, tokenId, auth);
    }

    function _register(uint256 tokenId, address operator, address vault, address gauge, address bribe) private {
        if (tokenIdForVault[vault] != 0) {
            revert ValidatorPositionExists();
        }
        validatorPosition[tokenId] =
            ValidatorPosition(_validatorSubmissions[tokenId].validatorId, operator, vault, gauge, bribe);
        tokenIdForVault[vault] = tokenId;
        controller.registerValidatorPosition(vault, tokenId);
    }
}
