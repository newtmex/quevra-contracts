// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IValidatorRegistry} from "./interfaces/IValidatorRegistry.sol";
import {StakingVault} from "./StakingVault.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title StakingController
/// @notice Owns validator vaults and routes MON weight through the bound vault.
/// @dev The controller never holds user deposits between calls. `addWeight` and
///      `delegate` forward MON in the same transaction that records the weight.
contract StakingController is Ownable2Step, ReentrancyGuardTransient {
    IValidatorRegistry public immutable registry;
    address public voter;
    address public immutable vaultImplementation;
    mapping(address requester => uint256 nonce) private _nonces;
    error UnexpectedAuthAddress();

    struct Pool {
        address vault;
        address gauge;
        address operator;
        uint256 totalWeight;
    }

    mapping(uint256 requestId => Pool) public pools;
    mapping(uint256 requestId => mapping(address account => uint256)) public weightOf;
    uint256 public commission;
    uint256 public validatorAmount;

    error InvalidAddress();
    error VoterAlreadySet();
    error NotVoter();
    error InvalidPool();
    error ZeroWeight();
    error InvalidValidatorAmount();
    error InvalidValidatorState();
    error InvalidWeightAmount();
    error WeightAlreadyAdded();

    event VoterSet(address indexed voter);
    event VaultRegistered(uint256 indexed requestId, address indexed vault, address indexed gauge, address operator);
    event ValidatorConfigSet(uint256 commission, uint256 amount);
    event WeightAdded(uint256 indexed requestId, address indexed account, uint256 amount);
    event ValidatorStakeRouted(uint256 indexed requestId, address indexed vault, uint256 amount);
    event DelegationRouted(uint256 indexed requestId, address indexed vault, uint256 amount);
    event PoolCancelled(uint256 indexed requestId, address indexed vault, address indexed gauge);

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
        if (requester == address(0) || gauge == address(0) || pools[requestId].vault != address(0)) {
            revert InvalidPool();
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
        pools[requestId] = Pool(vault, gauge, requester, 0);
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
    function validatorSigningConfig(uint256 requestId)
        external
        view
        returns (address authAddress, uint256 commission_, uint256 amount)
    {
        Pool memory pool = _pool(requestId);
        return (pool.vault, commission, validatorAmount);
    }

    /// @notice Configuration to sign BEFORE requesting a validator.
    /// @dev Submit the returned authAddress as expectedAuthAddress.
    function validatorSigningConfig(address requester, bytes calldata secpPubkey, bytes calldata blsPubkey)
        external
        view
        returns (address authAddress, uint256 commission_, uint256 amount)
    {
        if (voter == address(0) || requester == address(0)) revert InvalidAddress();
        if (validatorAmount == 0) revert InvalidValidatorAmount();
        authAddress = predictVaultAddress(requester, secpPubkey, blsPubkey);
        return (authAddress, commission, validatorAmount);
    }

    /// @notice Add MON weight, creating the validator if it is still proposed or delegating otherwise.
    function addWeight(uint256 requestId) external payable nonReentrant returns (uint64 validatorId) {
        Pool storage pool = _pool(requestId);
        if (msg.value == 0) revert ZeroWeight();
        IValidatorRegistry.Proposal memory proposal = registry.getProposal(requestId);
        if (proposal.status == IValidatorRegistry.Status.Proposed && proposal.validatorId == 0) {
            uint256 amount = validatorAmount;
            if (amount == 0) revert InvalidValidatorAmount();
            if (msg.value != amount) revert InvalidWeightAmount();
            validatorId = StakingVault(payable(pool.vault)).addValidator{value: msg.value}(commission);
            emit ValidatorStakeRouted(requestId, pool.vault, msg.value);
        } else if (proposal.status == IValidatorRegistry.Status.Executed && proposal.validatorId != 0) {
            _delegate(pool.vault, msg.value);
            validatorId = proposal.validatorId;
        } else {
            revert InvalidValidatorState();
        }

        weightOf[requestId][msg.sender] += msg.value;
        pool.totalWeight += msg.value;
        emit WeightAdded(requestId, msg.sender, msg.value);
    }

    /// @notice Delegate MON to an already-created validator. Permissionless by design.
    function delegate(uint256 requestId) external payable nonReentrant returns (bool success) {
        Pool storage pool = _pool(requestId);
        if (msg.value == 0) revert ZeroWeight();
        IValidatorRegistry.Proposal memory proposal = registry.getProposal(requestId);
        if (proposal.status != IValidatorRegistry.Status.Executed || proposal.validatorId == 0) {
            revert InvalidValidatorState();
        }
        success = _delegate(pool.vault, msg.value);
        weightOf[requestId][msg.sender] += msg.value;
        pool.totalWeight += msg.value;
        emit WeightAdded(requestId, msg.sender, msg.value);
    }

    function cancelPool(uint256 requestId) external {
        if (msg.sender != voter) revert NotVoter();
        Pool memory pool = _pool(requestId);
        if (pool.totalWeight != 0) revert WeightAlreadyAdded();
        delete pools[requestId];
        emit PoolCancelled(requestId, pool.vault, pool.gauge);
    }

    function _delegate(address vault, uint256 amount) private returns (bool success) {
        success = StakingVault(payable(vault)).delegate{value: amount}();
    }

    function _pool(uint256 requestId) internal view returns (Pool storage pool) {
        pool = pools[requestId];
        if (pool.vault == address(0)) revert InvalidPool();
    }
}
