// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IValidatorRegistry} from "../interfaces/IValidatorRegistry.sol";
import {IBaseVoter} from "../interfaces/IBaseVoter.sol";
import {IStakingController} from "../interfaces/IStakingController.sol";
import {StakingVault} from "./controlled/StakingVault.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";
import {ValidatorPayloadLibrary} from "../libraries/ValidatorPayloadLibrary.sol";

/// @title StakingController
/// @notice Owns validator vaults and routes MON deposits through the bound vault.
/// @dev Accepts MON only through the ve token's explicit deposit call. Admin-controlled staking flow is deferred.
contract StakingController is Ownable2Step, ReentrancyGuardTransient, IStakingController {
    IValidatorRegistry public immutable override registry;
    address public override voter;
    address public immutable override vaultImplementation;
    mapping(uint256 requestId => address vault) public override vaultByRequest;
    mapping(uint256 tokenId => uint256 amount) public override balanceOf;
    uint256 private _commission;
    uint256 private _pendingCommission;
    uint64 private _pendingCommissionCycle;

    /// @notice Fixed stake amount committed to validator registration signatures.
    uint256 public constant VALIDATOR_STAKE_AMOUNT = 100_000 ether;
    /// @notice Maximum commission accepted by Monad's staking precompile (100%, scaled by 1e18).
    uint256 public constant MAX_COMMISSION = 1e18;

    constructor(address registry_, address owner_, uint256 initialCommission_) Ownable(owner_) {
        if (registry_ == address(0) || owner_ == address(0)) revert InvalidAddress();
        if (initialCommission_ > MAX_COMMISSION) revert InvalidCommission();
        registry = IValidatorRegistry(registry_);
        _commission = initialCommission_;
        vaultImplementation = address(new StakingVault());
    }

    /// @notice Bind the voter once. The owner must set this after both contracts are deployed.
    function setVoter(address voter_) external override onlyOwner {
        if (voter != address(0)) revert VoterAlreadySet();
        if (voter_ == address(0)) revert InvalidAddress();
        voter = voter_;
        emit VoterSet(voter_);
    }

    /// @notice Deploy, initialize, and register a vault with its gauge, only through the voter.
    function deployVault(
        uint256 requestId,
        address requester,
        bytes32 saltSeed,
        address expectedAuthAddress,
        address gauge
    ) external override returns (address vault) {
        if (msg.sender != voter) revert NotVoter();
        if (requester == address(0) || gauge == address(0) || vaultByRequest[requestId] != address(0)) {
            revert InvalidVault();
        }

        IValidatorRegistry.Submission memory submission = registry.getSubmission(requestId);
        if (submission.requester != voter || submission.status != IValidatorRegistry.Status.Submitted) {
            revert InvalidValidatorState();
        }
        if (ValidatorPayloadLibrary.authAddress(submission.payload) != expectedAuthAddress) {
            revert UnexpectedAuthAddress();
        }
        if (predictVaultAddress(requester, saltSeed) != expectedAuthAddress) {
            revert UnexpectedAuthAddress();
        }

        bytes32 salt = _vaultSalt(requester, saltSeed);
        vault = Clones.cloneDeterministic(vaultImplementation, salt);
        StakingVault(payable(vault)).initialize(address(registry), requestId);
        vaultByRequest[requestId] = vault;
        emit VaultRegistered(requestId, vault, gauge, requester);
    }

    function predictVaultAddress(address requester, bytes32 saltSeed) public view override returns (address) {
        return Clones.predictDeterministicAddress(vaultImplementation, _vaultSalt(requester, saltSeed), address(this));
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

    /// @notice Return the auth address, commission, and amount required by addValidator signatures.
    function signingConfig(uint256 requestId)
        external
        override
        returns (address authAddress, uint256 commission_, uint256 amount)
    {
        address vault = vaultByRequest[requestId];
        if (vault == address(0)) revert InvalidVault();
        return (vault, _effectiveCommission(), VALIDATOR_STAKE_AMOUNT);
    }

    /// @notice Configuration to sign BEFORE requesting a validator.
    /// @dev Submit the returned authAddress as expectedAuthAddress.
    function signingConfigFor(address requester, bytes32 saltSeed)
        external
        override
        returns (address authAddress, uint256 commission_, uint256 amount)
    {
        if (voter == address(0) || requester == address(0)) revert InvalidAddress();
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

    function deposit(uint256 tokenId) external payable override nonReentrant {
        if (voter == address(0) || msg.sender != _ve()) revert NotVe();
        if (msg.value == 0) revert InvalidDepositAmount();
        balanceOf[tokenId] += msg.value;
        emit MONDeposited(tokenId, msg.value);
    }

    function _ve() private view returns (address) {
        return IBaseVoter(voter).ve();
    }

    function cancelVault(uint256 requestId) external override {
        if (msg.sender != voter) revert NotVoter();
        address vault = vaultByRequest[requestId];
        if (vault == address(0)) revert InvalidVault();
        IValidatorRegistry.Submission memory submission = registry.getSubmission(requestId);
        if (submission.status != IValidatorRegistry.Status.Submitted || submission.validatorId != 0) {
            revert InvalidValidatorState();
        }
        delete vaultByRequest[requestId];
        emit VaultCancelled(requestId, vault);
    }
}
