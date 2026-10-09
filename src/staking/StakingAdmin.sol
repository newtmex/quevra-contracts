// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IStakingController} from "../interfaces/IStakingController.sol";
import {IVeValidator} from "../interfaces/IVeValidator.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {IVeMON} from "../interfaces/IVeMON.sol";
import {StakingVault} from "./controlled/StakingVault.sol";
import {StakingAgent} from "./controlled/StakingAgent.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";
import {ValidatorPayloadLibrary} from "../libraries/ValidatorPayloadLibrary.sol";
import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";

/// @title StakingAdmin
/// @notice Administrative and validator-deployment layer for staking controllers.
abstract contract StakingAdmin is Ownable2Step, IStakingController {
    address public override ve;
    address public override validatorVe;
    address public immutable override vaultImplementation;
    address public immutable override agentImplementation;
    mapping(address => bool) internal _isVault;
    mapping(address => bool) internal _isAgent;
    mapping(address vault => uint256 tokenId) internal _validatorTokenId;
    mapping(uint256 tokenId => uint256 amount) public override validatorBackingOf;
    mapping(uint256 tokenId => uint256 amount) public override veMONPrincipalOf;
    mapping(uint64 validatorId => address vault) internal _vaultByValidatorId;
    uint256 internal _commission;
    uint256 internal _pendingCommission;
    uint64 internal _pendingCommissionCycle;

    /// @notice Fixed stake amount committed to validator registration signatures.
    uint256 public constant VALIDATOR_STAKE_AMOUNT = 100_000 ether;
    /// @notice Maximum commission accepted by Monad's staking precompile (100%, scaled by 1e18).
    uint256 public constant MAX_COMMISSION = 1e18;

    constructor(address owner_, uint256 initialCommission_) Ownable(owner_) {
        if (owner_ == address(0)) revert InvalidAddress();
        if (initialCommission_ > MAX_COMMISSION) revert InvalidCommission();
        _commission = initialCommission_;
        vaultImplementation = address(new StakingVault());
        agentImplementation = address(new StakingAgent());
    }

    /// @notice Bind veMON once. The owner sets this after both contracts are deployed.
    function setVe(address ve_) external override onlyOwner {
        if (ve != address(0)) revert VeAlreadySet();
        if (ve_ == address(0)) revert InvalidAddress();
        ve = ve_;
        emit VeSet(ve_);
    }

    function setValidatorVe(address veValidator_) external override onlyOwner {
        if (validatorVe != address(0) || veValidator_ == address(0)) revert InvalidAddress();
        validatorVe = veValidator_;
    }

    /// @notice Bind the vote-syncing ValidatorsVoter through veMON.
    function setBooster(address booster_) external override onlyOwner {
        if (ve == address(0) || booster_ == address(0)) revert InvalidAddress();
        IVeMON(ve).setBooster(booster_);
    }

    function validatorTokenIdOf(address vault) external view override returns (uint256) {
        return _validatorTokenId[vault];
    }

    function registerValidatorPosition(address vault, uint256 tokenId) external override {
        if (msg.sender != validatorVe || !_isVault[vault] || tokenId == 0 || _validatorTokenId[vault] != 0) {
            revert InvalidValidatorState();
        }
        _validatorTokenId[vault] = tokenId;
    }

    function _setValidatorBacking(address vault, uint256 backing) internal {
        uint256 tokenId = _validatorTokenId[vault];
        if (tokenId == 0 || validatorVe == address(0)) return;
        uint256 current = validatorBackingOf[tokenId];
        validatorBackingOf[tokenId] = backing;
        if (current != backing) IVotingEscrow(validatorVe).syncAmountFromController(tokenId, current, backing);
    }

    function _setValidatorId(address vault, uint64 validatorId) internal {
        uint256 tokenId = _validatorTokenId[vault];
        if (tokenId == 0 || validatorVe == address(0) || validatorId == 0) return;
        IVeValidator(validatorVe).setValidatorIdFromController(tokenId, validatorId);
    }

    function _decreaseValidatorBacking(address vault, uint256 amount) internal {
        uint256 tokenId = _validatorTokenId[vault];
        uint256 current = tokenId == 0 ? 0 : validatorBackingOf[tokenId];
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
        if (msg.sender != requester && msg.sender != validatorVe) revert NotRequester();
        if (requester == address(0)) revert InvalidVault();

        IVeValidator.ValidatorSubmission memory submission = IVeValidator(validatorVe).validatorSubmission(tokenId);
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

        vault = Clones.cloneDeterministic(vaultImplementation, _vaultSalt(requester, saltSeed));
        StakingVault(payable(vault)).initialize(validatorVe, tokenId, validatorId);

        _isVault[vault] = true;
        emit VaultRegistered(tokenId, vault, requester);
    }

    function predictVaultAddress(address requester, bytes32 saltSeed) public view override returns (address) {
        return Clones.predictDeterministicAddress(vaultImplementation, _vaultSalt(requester, saltSeed), address(this));
    }

    function predictAgentAddress(uint256 tokenId) public view override returns (address) {
        return Clones.predictDeterministicAddress(agentImplementation, bytes32(tokenId), address(this));
    }

    function _vaultSalt(address requester, bytes32 saltSeed) private pure returns (bytes32) {
        return keccak256(abi.encode(requester, saltSeed));
    }

    /// @notice Schedule commission for the cycle two cycles after the current cycle.
    function setCommission(uint256 commission_) external override onlyOwner {
        if (commission_ > MAX_COMMISSION) revert InvalidCommission();
        uint64 effectiveCycle = ProtocolTimeLibrary.currentCycle() + 2;
        _pendingCommission = commission_;
        _pendingCommissionCycle = effectiveCycle;
        emit ValidatorCommissionSet(commission_);
        emit ValidatorCommissionScheduled(commission_, effectiveCycle);
    }

    /// @notice Configuration to sign BEFORE requesting a validator.
    /// @dev Submit the returned authAddress as expectedAuthAddress.
    function signingConfigFor(address requester, bytes32 saltSeed)
        external
        override
        returns (address authAddress, uint256 commission_, uint256 amount)
    {
        if (ve == address(0) || requester == address(0)) revert InvalidAddress();
        authAddress = predictVaultAddress(requester, saltSeed);
        return (authAddress, _effectiveCommission(), VALIDATOR_STAKE_AMOUNT);
    }

    function _effectiveCommission() private returns (uint256) {
        uint64 pendingCycle = _pendingCommissionCycle;
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        if (pendingCycle != 0 && ProtocolTimeLibrary.cycleOf(epoch) >= pendingCycle) {
            _commission = _pendingCommission;
            _pendingCommission = 0;
            _pendingCommissionCycle = 0;
        }
        return _commission;
    }

    function commission() external override returns (uint256) {
        return _effectiveCommission();
    }
}
