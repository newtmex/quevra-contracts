// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VotingEscrow} from "./VotingEscrow.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
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

    /// @custom:storage-location erc7201:quevra.VeValidator
    struct VeValidatorStorage {
        address gaugeRewardToken;
        mapping(uint256 tokenId => ValidatorPosition) validatorPosition;
        mapping(address vault => uint256 tokenId) tokenIdForVault;
        mapping(uint256 tokenId => IVeValidator.ValidatorSubmission) validatorSubmissions;
    }

    bytes32 private constant VE_VALIDATOR_STORAGE_SLOT =
        0x1d255a1cb018179c4728947c6a2fb9a145247012a11581034e3e28ed36fa1100;

    function _veValidatorStorage() internal pure returns (VeValidatorStorage storage $) {
        bytes32 slot = VE_VALIDATOR_STORAGE_SLOT;
        assembly ("memory-safe") { $.slot := slot }
    }

    function gaugeRewardToken() public view returns (address) {
        return _veValidatorStorage().gaugeRewardToken;
    }

    /// @inheritdoc IVeValidator
    function validatorPosition(uint256 tokenId)
        public
        view
        override
        returns (uint64 validatorId, address operator, address vault, address gauge, address bribeVotingRewards)
    {
        ValidatorPosition storage position = _veValidatorStorage().validatorPosition[tokenId];
        return (position.validatorId, position.operator, position.vault, position.gauge, position.bribeVotingRewards);
    }

    function tokenIdForVault(address vault) public view returns (uint256) {
        return _veValidatorStorage().tokenIdForVault[vault];
    }

    error InvalidAddress();
    error ValidatorTokenNonTransferable();
    error ValidatorPositionExists();
    error InvalidValidatorPosition();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address controller_,
        address validatorsVoter_,
        address gaugeRewardToken_,
        uint64 maxLockCycles_,
        address owner_
    ) external initializer {
        if (
            controller_ == address(0) || controller_.code.length == 0 || validatorsVoter_ == address(0)
                || validatorsVoter_.code.length == 0 || gaugeRewardToken_ == address(0)
                || gaugeRewardToken_.code.length == 0
        ) {
            revert InvalidAddress();
        }
        __VotingEscrow_init(maxLockCycles_, "Validator", "veValidator", controller_, validatorsVoter_, owner_);
        _veValidatorStorage().gaugeRewardToken = gaugeRewardToken_;
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
        _veValidatorStorage().validatorSubmissions[tokenId] =
            IVeValidator.ValidatorSubmission(payload, signedSecpMessage, signedBlsMessage, operator, false, 0);
        address vault =
            IStakingController(controller()).deployValidatorVault(operator, tokenId, saltSeed, expectedAuthAddress);
        address gauge =
            IValidatorsVoter(voter()).createBoostGauge(tokenId, _veValidatorStorage().gaugeRewardToken, vault);
        address bribe = IValidatorsVoter(voter()).gaugeToBribe(gauge);
        _register(tokenId, operator, vault, gauge, bribe);
    }

    function createExistingValidator(uint64 validatorId, bytes32 saltSeed)
        external
        nonReentrant
        returns (uint256 tokenId)
    {
        address operator = msg.sender;
        tokenId = _mintPermanentPosition(operator);
        _veValidatorStorage().validatorSubmissions[tokenId] =
            IVeValidator.ValidatorSubmission("", "", "", operator, true, validatorId);
        address vault = IStakingController(controller())
            .deployValidatorVault(
                operator, tokenId, saltSeed, IStakingController(controller()).predictVaultAddress(operator, saltSeed)
            );
        address gauge =
            IValidatorsVoter(voter()).createBoostGauge(tokenId, _veValidatorStorage().gaugeRewardToken, vault);
        address bribe = IValidatorsVoter(voter()).gaugeToBribe(gauge);
        _register(tokenId, operator, vault, gauge, bribe);
    }

    /// @inheritdoc IVeValidator
    function validatorSubmission(uint256 tokenId) external view override returns (ValidatorSubmission memory) {
        return _veValidatorStorage().validatorSubmissions[tokenId];
    }

    function approve(address, uint256) public pure override(ERC721Upgradeable, IERC721) {
        revert ValidatorTokenNonTransferable();
    }

    function setApprovalForAll(address, bool) public pure override(ERC721Upgradeable, IERC721) {
        revert ValidatorTokenNonTransferable();
    }

    /// @inheritdoc IVeValidator
    function setValidatorIdFromController(uint256 tokenId, uint64 validatorId) external override {
        _requireController();
        ValidatorPosition storage position = _veValidatorStorage().validatorPosition[tokenId];
        if (position.operator == address(0) || validatorId == 0 || position.validatorId != 0) {
            revert InvalidValidatorPosition();
        }
        position.validatorId = validatorId;
    }

    function _amountOf(uint256 tokenId) internal view override returns (int128) {
        return IStakingController(controller()).validatorBackingOf(tokenId).toInt128();
    }

    function _mintPermanentPosition(address to) internal returns (uint256 tokenId) {
        if (to == address(0)) revert InvalidValidatorPosition();
        tokenId = _escrowStorage().nextId++;
        IVotingEscrow.LockedBalance memory newLock = IVotingEscrow.LockedBalance(0, 0, true, 0);
        _checkpointLock(tokenId, IVotingEscrow.LockedBalance(0, 0, false, 0), newLock);
        _escrowStorage().lockData[tokenId] = LockData(0, true, 0);
        _safeMint(to, tokenId);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = _ownerOf(tokenId);
        if (from != address(0)) revert ValidatorTokenNonTransferable();
        return super._update(to, tokenId, auth);
    }

    function _register(uint256 tokenId, address operator, address vault, address gauge, address bribe) private {
        if (_veValidatorStorage().tokenIdForVault[vault] != 0) {
            revert ValidatorPositionExists();
        }
        _veValidatorStorage().validatorPosition[tokenId] = ValidatorPosition(
            _veValidatorStorage().validatorSubmissions[tokenId].validatorId, operator, vault, gauge, bribe
        );
        _veValidatorStorage().tokenIdForVault[vault] = tokenId;
        IStakingController(controller()).registerValidatorPosition(vault, tokenId);
    }
}
