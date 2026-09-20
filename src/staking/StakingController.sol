// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IValidatorRegistry} from "../interfaces/IValidatorRegistry.sol";
import {IBaseVoter} from "../interfaces/IBaseVoter.sol";
import {StakingVault} from "./StakingVault.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title StakingController
/// @notice Owns validator vaults and routes MON deposits through the bound vault.
/// @dev Accepts MON only from the ve token configured on the voter. Admin-controlled staking flow is deferred.
contract StakingController is Ownable2Step, ReentrancyGuardTransient {
    IValidatorRegistry public immutable registry;
    address public voter;
    address public immutable vaultImplementation;
    mapping(address requester => uint256 nonce) private _nonces;
    error UnexpectedAuthAddress();

    mapping(uint256 requestId => address vault) public vaultByRequest;
    uint256 public commission;

    /// @notice Fixed stake amount committed to validator registration signatures.
    uint256 public constant VALIDATOR_STAKE_AMOUNT = 100_000 ether;
    /// @notice Maximum commission accepted by Monad's staking precompile (100%, scaled by 1e18).
    uint256 public constant MAX_COMMISSION = 1e18;

    error InvalidAddress();
    error InvalidCommission();
    error VoterAlreadySet();
    error NotVoter();
    error InvalidVault();
    error InvalidValidatorState();
    error InvalidDepositAmount();
    error NotVe();

    event VoterSet(address indexed voter);
    event VaultRegistered(uint256 indexed requestId, address indexed vault, address indexed gauge, address operator);
    event ValidatorCommissionSet(uint256 commission);
    event MONReceived(uint256 amount);
    event VaultCancelled(uint256 indexed requestId, address indexed vault);

    constructor(address registry_, address owner_) Ownable(owner_) {
        if (registry_ == address(0) || owner_ == address(0)) revert InvalidAddress();
        registry = IValidatorRegistry(registry_);
        vaultImplementation = address(new StakingVault());
    }

    /// @notice Bind the voter once. The owner must set this after both contracts are deployed.
    function setVoter(address voter_) external onlyOwner {
        if (voter != address(0)) revert VoterAlreadySet();
        if (voter_ == address(0)) revert InvalidAddress();
        voter = voter_;
        emit VoterSet(voter_);
    }

    /// @notice Deploy, initialize, and register a vault with its gauge, only through the voter.
    function deployVault(uint256 requestId, address requester, address expectedAuthAddress, address gauge)
        external
        returns (address vault)
    {
        if (msg.sender != voter) revert NotVoter();
        if (requester == address(0) || gauge == address(0) || vaultByRequest[requestId] != address(0)) {
            revert InvalidVault();
        }

        IValidatorRegistry.Submission memory submission = registry.getSubmission(requestId);
        if (submission.requester != voter || submission.status != IValidatorRegistry.Status.Submitted) {
            revert InvalidValidatorState();
        }
        if (predictVaultAddress(requester, submission.secpPubkey, submission.blsPubkey) != expectedAuthAddress) {
            revert UnexpectedAuthAddress();
        }

        uint256 nonce = _nonces[requester]++;
        bytes32 salt = _vaultSalt(requester, nonce, submission.secpPubkey, submission.blsPubkey);
        vault = Clones.cloneDeterministic(vaultImplementation, salt);
        StakingVault(payable(vault)).initialize(address(registry), requestId);
        vaultByRequest[requestId] = vault;
        emit VaultRegistered(requestId, vault, gauge, requester);
    }

    function predictVaultAddress(address requester, bytes memory secpPubkey, bytes memory blsPubkey)
        public
        view
        returns (address)
    {
        return Clones.predictDeterministicAddress(
            vaultImplementation, _vaultSalt(requester, _nonces[requester], secpPubkey, blsPubkey), address(this)
        );
    }

    function _vaultSalt(address requester, uint256 nonce, bytes memory secpPubkey, bytes memory blsPubkey)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(requester, nonce, keccak256(secpPubkey), keccak256(blsPubkey)));
    }

    /// @notice Set the commission encoded in a requester's signed messages.
    function setCommission(uint256 commission_) external onlyOwner {
        if (commission_ > MAX_COMMISSION) revert InvalidCommission();
        commission = commission_;
        emit ValidatorCommissionSet(commission_);
    }

    /// @notice Return the auth address, commission, and amount required by addValidator signatures.
    function signingConfig(uint256 requestId)
        external
        view
        returns (address authAddress, uint256 commission_, uint256 amount)
    {
        address vault = vaultByRequest[requestId];
        if (vault == address(0)) revert InvalidVault();
        return (vault, commission, VALIDATOR_STAKE_AMOUNT);
    }

    /// @notice Configuration to sign BEFORE requesting a validator.
    /// @dev Submit the returned authAddress as expectedAuthAddress.
    function signingConfigFor(address requester, bytes calldata secpPubkey, bytes calldata blsPubkey)
        external
        view
        returns (address authAddress, uint256 commission_, uint256 amount)
    {
        if (voter == address(0) || requester == address(0)) revert InvalidAddress();
        authAddress = predictVaultAddress(requester, secpPubkey, blsPubkey);
        return (authAddress, commission, VALIDATOR_STAKE_AMOUNT);
    }

    receive() external payable nonReentrant {
        if (voter == address(0) || msg.sender != IBaseVoter(voter).ve()) revert NotVe();
        if (msg.value == 0) revert InvalidDepositAmount();
        emit MONReceived(msg.value);
    }

    function cancelVault(uint256 requestId) external {
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
