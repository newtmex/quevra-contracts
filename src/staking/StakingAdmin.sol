// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IValidatorRegistry} from "../interfaces/IValidatorRegistry.sol";
import {IStakingController} from "../interfaces/IStakingController.sol";
import {StakingVault} from "./controlled/StakingVault.sol";
import {StakingAgent} from "./controlled/StakingAgent.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";
import {ValidatorPayloadLibrary} from "../libraries/ValidatorPayloadLibrary.sol";
import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";

/// @title StakingAdmin
/// @notice Administrative and validator-deployment layer for staking controllers.
abstract contract StakingAdmin is Ownable2Step, IStakingController {
    IValidatorRegistry public immutable override registry;
    address public override ve;
    address public immutable override vaultImplementation;
    address public immutable override agentImplementation;
    mapping(address => bool) internal _isVault;
    mapping(address => bool) internal _isAgent;
    uint256 internal _commission;
    uint256 internal _pendingCommission;
    uint64 internal _pendingCommissionCycle;

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
        agentImplementation = address(new StakingAgent());
    }

    /// @notice Bind veMON once. The owner sets this after both contracts are deployed.
    function setVe(address ve_) external override onlyOwner {
        if (ve != address(0)) revert VeAlreadySet();
        if (ve_ == address(0)) revert InvalidAddress();
        ve = ve_;
        emit VeSet(ve_);
    }

    function isWhitelistedToken(address) external pure override returns (bool) {
        return false;
    }

    /// @notice Admit a registry request and create its validator vault.
    /// @dev The vault address is derived from the requester's salt and, for a
    ///      new validator, must match the auth address committed in the payload.
    function admitValidatorRequest(uint256 requestId, bytes32 saltSeed) external override returns (address vault) {
        IValidatorRegistry.Submission memory submission = registry.getSubmission(requestId);
        if (msg.sender != submission.requester) revert NotRequester();
        address expectedAuthAddress = predictVaultAddress(submission.requester, saltSeed);
        vault = _deployValidatorRequest(
            requestId, submission.requester, submission.requester, address(0), saltSeed, expectedAuthAddress
        );
    }

    /// @dev Matches the operator/requester split used by the voter architecture:
    ///      the controller submits the request while the operator owns its vault.
    function _createValidator(
        address operator,
        bytes32 saltSeed,
        address expectedAuthAddress,
        bytes calldata payload,
        bytes calldata signedSecpMessage,
        bytes calldata signedBlsMessage
    ) internal returns (uint256 requestId, address vault) {
        requestId = registry.requestValidatorFor(operator, payload, signedSecpMessage, signedBlsMessage);
        vault = _deployValidatorRequest(requestId, operator, address(this), operator, saltSeed, expectedAuthAddress);
    }

    function _deployValidatorRequest(
        uint256 requestId,
        address requester,
        address submissionRequester,
        address expectedOperator,
        bytes32 saltSeed,
        address expectedAuthAddress
    ) private returns (address vault) {
        if (msg.sender != requester) revert NotRequester();
        if (requester == address(0)) revert InvalidVault();

        IValidatorRegistry.Submission memory submission = registry.getSubmission(requestId);
        if (
            submission.requester != submissionRequester || submission.status != IValidatorRegistry.Status.Submitted
                || (expectedOperator != address(0) && submission.operator != expectedOperator)
        ) {
            revert InvalidValidatorState();
        }
        if (predictVaultAddress(requester, saltSeed) != expectedAuthAddress) {
            revert UnexpectedAuthAddress();
        }

        uint64 validatorId = 0;
        if (submission.requestType == IValidatorRegistry.RequestType.NewValidator) {
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
        if (submission.requestType == IValidatorRegistry.RequestType.NewValidator) {
            StakingVault(payable(vault)).initialize(address(registry), requestId);
        } else {
            StakingVault(payable(vault)).initializeExisting(address(registry), requestId, validatorId);
        }

        _isVault[vault] = true;
        emit VaultRegistered(requestId, vault, requester);
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
