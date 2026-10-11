// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {IStakingController} from "../interfaces/IStakingController.sol";
import {IVeValidator} from "../interfaces/IVeValidator.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {StakingVault} from "./controlled/StakingVault.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";
import {ValidatorPayloadLibrary} from "../libraries/ValidatorPayloadLibrary.sol";
import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";

/// @title StakingAdmin
/// @notice Administrative and validator-deployment layer for staking controllers.
abstract contract StakingAdmin is Initializable, Ownable2StepUpgradeable, IStakingController {
    /// @custom:storage-location erc7201:quevra.StakingAdmin
    struct StakingAdminStorage {
        address ve;
        address validatorVe;
        address vaultBeacon;
        address agentBeacon;
        mapping(address => bool) isVault;
        mapping(address => bool) isAgent;
        mapping(address vault => uint256 tokenId) validatorTokenId;
        mapping(uint256 tokenId => uint256 amount) validatorBackingOf;
        mapping(uint256 tokenId => uint256 amount) veMONPrincipalOf;
        mapping(uint64 validatorId => address vault) vaultByValidatorId;
        uint256 commission;
        uint256 pendingCommission;
        uint64 pendingCommissionCycle;
    }

    bytes32 private constant STAKING_ADMIN_STORAGE_SLOT =
        0x41d6508fcea290a3c6ce828b896c5cf91da3d83f3c6ceac02c329b962ecfe300;

    function _adminStorage() internal pure returns (StakingAdminStorage storage $) {
        bytes32 slot = STAKING_ADMIN_STORAGE_SLOT;
        assembly ("memory-safe") {
            $.slot := slot
        }
    }

    /// @notice Fixed stake amount committed to validator registration signatures.
    uint256 public constant VALIDATOR_STAKE_AMOUNT = 100_000 ether;
    /// @notice Maximum commission accepted by Monad's staking precompile (100%, scaled by 1e18).
    uint256 public constant MAX_COMMISSION = 1e18;

    function __StakingAdmin_init(address owner_, uint256 initialCommission_, address vaultBeacon_, address agentBeacon_)
        internal
        onlyInitializing
    {
        if (owner_ == address(0) || !_validBeacon(vaultBeacon_) || !_validBeacon(agentBeacon_)) {
            revert InvalidAddress();
        }
        if (initialCommission_ > MAX_COMMISSION) revert InvalidCommission();
        __Ownable_init(owner_);
        __Ownable2Step_init();
        StakingAdminStorage storage $ = _adminStorage();
        $.commission = initialCommission_;
        $.vaultBeacon = vaultBeacon_;
        $.agentBeacon = agentBeacon_;
    }

    /// @inheritdoc IStakingController
    function ve() public view override returns (address) {
        return _adminStorage().ve;
    }

    /// @inheritdoc IStakingController
    function validatorVe() public view override returns (address) {
        return _adminStorage().validatorVe;
    }

    /// @inheritdoc IStakingController
    function vaultBeacon() public view override returns (address) {
        return _adminStorage().vaultBeacon;
    }

    /// @inheritdoc IStakingController
    function agentBeacon() public view override returns (address) {
        return _adminStorage().agentBeacon;
    }

    /// @inheritdoc IStakingController
    function validatorBackingOf(uint256 tokenId) public view override returns (uint256) {
        return _adminStorage().validatorBackingOf[tokenId];
    }

    /// @inheritdoc IStakingController
    function veMONPrincipalOf(uint256 tokenId) public view override returns (uint256) {
        return _adminStorage().veMONPrincipalOf[tokenId];
    }

    /// @inheritdoc IStakingController
    function setVe(address ve_) external override onlyOwner {
        StakingAdminStorage storage $ = _adminStorage();
        if ($.ve != address(0)) revert VeAlreadySet();
        if (ve_ == address(0) || ve_.code.length == 0) revert InvalidAddress();
        $.ve = ve_;
        emit VeSet(ve_);
    }

    /// @inheritdoc IStakingController
    function setValidatorVe(address veValidator_) external override onlyOwner {
        StakingAdminStorage storage $ = _adminStorage();
        if ($.validatorVe != address(0) || veValidator_ == address(0) || veValidator_.code.length == 0) {
            revert InvalidAddress();
        }
        $.validatorVe = veValidator_;
    }

    /// @inheritdoc IStakingController
    function validatorTokenIdOf(address vault) external view override returns (uint256) {
        return _adminStorage().validatorTokenId[vault];
    }

    /// @inheritdoc IStakingController
    function registerValidatorPosition(address vault, uint256 tokenId) external override {
        StakingAdminStorage storage $ = _adminStorage();
        if (msg.sender != $.validatorVe || !$.isVault[vault] || tokenId == 0 || $.validatorTokenId[vault] != 0) {
            revert InvalidValidatorState();
        }
        $.validatorTokenId[vault] = tokenId;
    }

    function _setValidatorBacking(address vault, uint256 backing) internal {
        StakingAdminStorage storage $ = _adminStorage();
        uint256 tokenId = $.validatorTokenId[vault];
        if (tokenId == 0 || $.validatorVe == address(0)) return;
        uint256 current = $.validatorBackingOf[tokenId];
        $.validatorBackingOf[tokenId] = backing;
        if (current != backing) IVotingEscrow($.validatorVe).syncAmountFromController(tokenId, current, backing);
    }

    function _setValidatorId(address vault, uint64 validatorId) internal {
        StakingAdminStorage storage $ = _adminStorage();
        uint256 tokenId = $.validatorTokenId[vault];
        if (tokenId == 0 || $.validatorVe == address(0) || validatorId == 0) return;
        IVeValidator($.validatorVe).setValidatorIdFromController(tokenId, validatorId);
    }

    function _decreaseValidatorBacking(address vault, uint256 amount) internal {
        StakingAdminStorage storage $ = _adminStorage();
        uint256 tokenId = $.validatorTokenId[vault];
        uint256 current = tokenId == 0 ? 0 : $.validatorBackingOf[tokenId];
        _setValidatorBacking(vault, amount >= current ? 0 : current - amount);
    }

    function _deployValidatorRequest(
        uint256 tokenId,
        address requester,
        address submissionRequester,
        address expectedOperator,
        bytes32 saltSeed,
        address expectedAuthAddress
    ) internal returns (address vault) {
        StakingAdminStorage storage $ = _adminStorage();
        if (msg.sender != requester && msg.sender != $.validatorVe) revert NotRequester();
        if (requester == address(0)) revert InvalidVault();

        IVeValidator.ValidatorSubmission memory submission = IVeValidator($.validatorVe).validatorSubmission(tokenId);
        if (submission.operator != submissionRequester || submission.operator != expectedOperator) {
            revert InvalidValidatorState();
        }
        if (predictVaultAddress(requester, saltSeed) != expectedAuthAddress) {
            revert UnexpectedAuthAddress();
        }

        uint64 validatorId = 0;
        if (!submission.existing) {
            if (ValidatorPayloadLibrary.authAddress(submission.payload) != expectedAuthAddress) {
                revert UnexpectedAuthAddress();
            }
        } else {
            validatorId = submission.validatorId;
            if (validatorId == 0) revert InvalidValidatorState();
            (bool success, bytes memory validatorData) =
                address(0x1000).call(abi.encodeWithSelector(IMonadStaking.getValidator.selector, validatorId));
            if (!success || validatorData.length < 32) revert InvalidValidatorState();
            address authAddress;
            assembly ("memory-safe") {
                authAddress := mload(add(validatorData, 32))
            }
            if (authAddress == address(0)) revert InvalidValidatorState();
        }

        vault = address(new BeaconProxy{salt: _vaultSalt(requester, saltSeed)}($.vaultBeacon, bytes("")));
        StakingVault(payable(vault)).initialize(address(this), $.validatorVe, tokenId, validatorId);

        $.isVault[vault] = true;
        emit VaultRegistered(tokenId, vault, requester);
    }

    /// @inheritdoc IStakingController
    function predictVaultAddress(address requester, bytes32 saltSeed) public view override returns (address) {
        return _predictBeaconProxy(_adminStorage().vaultBeacon, _vaultSalt(requester, saltSeed));
    }

    /// @inheritdoc IStakingController
    function predictAgentAddress(uint256 tokenId) public view override returns (address) {
        return _predictBeaconProxy(_adminStorage().agentBeacon, bytes32(tokenId));
    }

    function _predictBeaconProxy(address beacon, bytes32 salt) private view returns (address) {
        bytes32 initCodeHash = keccak256(bytes.concat(type(BeaconProxy).creationCode, abi.encode(beacon, bytes(""))));
        return Create2.computeAddress(salt, initCodeHash, address(this));
    }

    function _validBeacon(address beacon) private view returns (bool) {
        if (beacon == address(0) || beacon.code.length == 0) return false;
        try IBeacon(beacon).implementation() returns (address implementation) {
            return implementation.code.length != 0;
        } catch {
            return false;
        }
    }

    function _vaultSalt(address requester, bytes32 saltSeed) private pure returns (bytes32) {
        return keccak256(abi.encode(requester, saltSeed));
    }

    /// @inheritdoc IStakingController
    function setCommission(uint256 commission_) external override onlyOwner {
        if (commission_ > MAX_COMMISSION) revert InvalidCommission();
        uint64 effectiveCycle = ProtocolTimeLibrary.currentCycle() + 2;
        StakingAdminStorage storage $ = _adminStorage();
        $.pendingCommission = commission_;
        $.pendingCommissionCycle = effectiveCycle;
        emit ValidatorCommissionSet(commission_);
        emit ValidatorCommissionScheduled(commission_, effectiveCycle);
    }

    /// @inheritdoc IStakingController
    function signingConfigFor(address requester, bytes32 saltSeed)
        external
        override
        returns (address authAddress, uint256 commission_, uint256 amount)
    {
        if (_adminStorage().ve == address(0) || requester == address(0)) revert InvalidAddress();
        authAddress = predictVaultAddress(requester, saltSeed);
        return (authAddress, _effectiveCommission(), VALIDATOR_STAKE_AMOUNT);
    }

    function _effectiveCommission() private returns (uint256) {
        StakingAdminStorage storage $ = _adminStorage();
        uint64 pendingCycle = $.pendingCommissionCycle;
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        if (pendingCycle != 0 && ProtocolTimeLibrary.cycleOf(epoch) >= pendingCycle) {
            $.commission = $.pendingCommission;
            $.pendingCommission = 0;
            $.pendingCommissionCycle = 0;
        }
        return $.commission;
    }

    /// @inheritdoc IStakingController
    function commission() external override returns (uint256) {
        return _effectiveCommission();
    }
}
