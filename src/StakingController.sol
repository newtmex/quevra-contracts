// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IValidatorRegistry} from "./interfaces/IValidatorRegistry.sol";
import {StakingVault} from "./StakingVault.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title StakingController
/// @notice Deploys and owns the vault created alongside a validator request.
contract StakingController is Ownable2Step {
    IValidatorRegistry public immutable registry;
    address public voter;
    address public immutable vaultImplementation;
    mapping(address requester => uint256 nonce) private _nonces;

    error InvalidAddress();
    error VoterAlreadySet();
    error NotVoter();
    error InvalidPool();
    error InvalidValidatorState();
    error UnexpectedAuthAddress();

    struct Pool {
        address vault;
        address gauge;
        address operator;
    }

    mapping(uint256 requestId => Pool) public pools;

    event VoterSet(address indexed voter);
    event VaultRegistered(uint256 indexed requestId, address indexed vault, address indexed gauge, address operator);

    constructor(address registry_, address owner_) Ownable(owner_) {
        if (registry_ == address(0) || owner_ == address(0)) revert InvalidAddress();
        registry = IValidatorRegistry(registry_);
        vaultImplementation = address(new StakingVault());
    }

    /// @notice Bind the voter once so it can complete validator creation.
    function setVoter(address voter_) external onlyOwner {
        if (voter != address(0)) revert VoterAlreadySet();
        if (voter_ == address(0)) revert InvalidAddress();
        voter = voter_;
        emit VoterSet(voter_);
    }

    /// @notice Deploy and initialize the vault for a proposed registry request.
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
        pools[requestId] = Pool(vault, gauge, requester);
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
}
