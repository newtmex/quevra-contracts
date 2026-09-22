// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IValidatorRegistry} from "./IValidatorRegistry.sol";

interface IStakingController {
    error UnexpectedAuthAddress();
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
    event ValidatorCommissionScheduled(uint256 commission, uint64 effectiveCycle);
    event MONDeposited(uint256 indexed tokenId, uint256 amount);
    event VaultCancelled(uint256 indexed requestId, address indexed vault);

    function voter() external view returns (address);
    function registry() external view returns (IValidatorRegistry);
    function vaultImplementation() external view returns (address);
    function vaultByRequest(uint256 requestId) external view returns (address);
    function balanceOf(uint256 tokenId) external view returns (uint256);

    function setVoter(address voter_) external;

    function deployVault(
        uint256 requestId,
        address requester,
        bytes32 saltSeed,
        address expectedAuthAddress,
        address gauge
    ) external returns (address vault);

    function predictVaultAddress(address requester, bytes32 saltSeed) external view returns (address);

    function setCommission(uint256 commission_) external;
    function signingConfig(uint256 requestId) external returns (address authAddress, uint256 commission, uint256 amount);
    function signingConfigFor(address requester, bytes32 saltSeed)
        external
        returns (address authAddress, uint256 commission, uint256 amount);
    function commission() external returns (uint256);

    function deposit(uint256 tokenId) external payable;
    function cancelVault(uint256 requestId) external;
}
