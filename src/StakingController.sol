// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IValidatorRegistry} from "./interfaces/IValidatorRegistry.sol";
import {StakingVault} from "./StakingVault.sol";
import {VeMON} from "./VeMON.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title StakingController
/// @notice Owns validator vaults and routes MON deposits through the bound vault.
/// @dev Accepts MON only from veMON. Admin-controlled staking flow is deferred.
contract StakingController is Ownable2Step, ReentrancyGuardTransient {
    IValidatorRegistry public immutable registry;
    address public voter;
    address public immutable vaultImplementation;
    VeMON public immutable veMON;
    mapping(address requester => uint256 nonce) private _nonces;
    error UnexpectedAuthAddress();

    mapping(uint256 requestId => address vault) public vaultByRequest;
    uint256 public commission;
    uint256 public validatorAmount;

    error InvalidAddress();
    error VoterAlreadySet();
    error NotVoter();
    error InvalidVault();
    error InvalidValidatorAmount();
    error InvalidValidatorState();
    error InvalidDepositAmount();
    error NotVeMON();

    event VoterSet(address indexed voter);
    event VaultRegistered(uint256 indexed requestId, address indexed vault, address indexed gauge, address operator);
    event ValidatorConfigSet(uint256 commission, uint256 amount);
    event MONReceived(uint256 amount);
    event VaultCancelled(uint256 indexed requestId, address indexed vault);

    constructor(address registry_, address owner_) Ownable(owner_) {
        if (registry_ == address(0) || owner_ == address(0)) revert InvalidAddress();
        registry = IValidatorRegistry(registry_);
        vaultImplementation = address(new StakingVault());
        veMON = new VeMON(address(this));
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

        IValidatorRegistry.Proposal memory proposal = registry.getProposal(requestId);
        if (proposal.operator != voter || proposal.status != IValidatorRegistry.Status.Proposed) {
            revert InvalidValidatorState();
        }
        if (predictVaultAddress(requester, proposal.secpPubkey, proposal.blsPubkey) != expectedAuthAddress) {
            revert UnexpectedAuthAddress();
        }

        uint256 nonce = _nonces[requester]++;
        bytes32 salt = _vaultSalt(requester, nonce, proposal.secpPubkey, proposal.blsPubkey);
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

    /// @notice Set the exact economics encoded in a requester's signed messages.
    function setValidatorConfig(uint256 amount, uint256 commission_) external onlyOwner {
        if (amount == 0) revert InvalidValidatorAmount();
        validatorAmount = amount;
        commission = commission_;
        emit ValidatorConfigSet(commission_, amount);
    }

    /// @notice Return the auth address, commission, and amount required by addValidator signatures.
    function signingConfig(uint256 requestId)
        external
        view
        returns (address authAddress, uint256 commission_, uint256 amount)
    {
        address vault = vaultByRequest[requestId];
        if (vault == address(0)) revert InvalidVault();
        return (vault, commission, validatorAmount);
    }

    /// @notice Configuration to sign BEFORE requesting a validator.
    /// @dev Submit the returned authAddress as expectedAuthAddress.
    function signingConfigFor(address requester, bytes calldata secpPubkey, bytes calldata blsPubkey)
        external
        view
        returns (address authAddress, uint256 commission_, uint256 amount)
    {
        if (voter == address(0) || requester == address(0)) revert InvalidAddress();
        if (validatorAmount == 0) revert InvalidValidatorAmount();
        authAddress = predictVaultAddress(requester, secpPubkey, blsPubkey);
        return (authAddress, commission, validatorAmount);
    }

    receive() external payable nonReentrant {
        if (msg.sender != address(veMON)) revert NotVeMON();
        if (msg.value == 0) revert InvalidDepositAmount();
        emit MONReceived(msg.value);
    }

    function cancelVault(uint256 requestId) external {
        if (msg.sender != voter) revert NotVoter();
        address vault = vaultByRequest[requestId];
        if (vault == address(0)) revert InvalidVault();
        IValidatorRegistry.Proposal memory proposal = registry.getProposal(requestId);
        if (proposal.status != IValidatorRegistry.Status.Proposed || proposal.validatorId != 0) {
            revert InvalidValidatorState();
        }
        delete vaultByRequest[requestId];
        emit VaultCancelled(requestId, vault);
    }
}
