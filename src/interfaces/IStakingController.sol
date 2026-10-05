// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IValidatorRegistry} from "./IValidatorRegistry.sol";

interface IStakingController {
    error UnexpectedAuthAddress();
    error InvalidAddress();
    error InvalidCommission();
    error VeAlreadySet();
    error NotRequester();
    error InvalidVault();
    error InvalidValidatorState();
    error InvalidDepositAmount();
    error NotVe();
    error EmptyArray();
    error LengthMismatch();
    error ZeroAmount();
    error InsufficientBalance();
    error ValidatorNotActivated();
    error InvalidUnstakeAmount();
    error InvalidStakeAttribution();
    error UnexpectedEtherSender();
    error NotTokenOwner();
    error NotGaugeParticipant();
    error TransferFailed();
    error StakingCycleNotAdvanced();
    error DuplicateGauge();

    event VeSet(address indexed ve);
    event VaultRegistered(uint256 indexed requestId, address indexed vault, address indexed gauge, address operator);
    event ValidatorCommissionSet(uint256 commission);
    event ValidatorCommissionScheduled(uint256 commission, uint64 effectiveCycle);
    event MONDeposited(uint256 indexed tokenId, uint256 amount);
    event AgentCreated(uint256 indexed tokenId, address indexed agent);
    event Staked(uint256 indexed tokenId, uint256 amount);
    event StakingIntentSet(uint256 indexed tokenId, uint64 indexed cycle);
    event StakingPoked(uint256 indexed tokenId, uint64 indexed cycle, bool satisfied);
    event Unstaked(uint256 indexed tokenId, uint256 amount);
    event Compounded(uint256 indexed tokenId, uint256 amount);
    event Withdrawn(uint256 indexed tokenId, uint256 amount);
    event RewardsClaimed(uint256 indexed tokenId, uint256 amount);

    function ve() external view returns (address);
    function registry() external view returns (IValidatorRegistry);
    function vaultImplementation() external view returns (address);
    function agentImplementation() external view returns (address);
    function vaultByGauge(address gauge) external view returns (address);
    function isValidatorActive(address gauge) external view returns (bool);
    function balanceOf(uint256 tokenId) external view returns (uint256);
    function stakingCycleOf(uint256 tokenId) external view returns (uint64);
    function intentOf(uint256 tokenId, address gauge) external view returns (uint256);
    function agentByToken(uint256 tokenId) external view returns (address);
    function allocationOf(uint256 tokenId, address gauge) external view returns (uint256);
    function pendingOf(uint256 tokenId, address gauge) external view returns (uint256);

    function setVe(address ve_) external;

    function predictVaultAddress(address requester, bytes32 saltSeed) external view returns (address);
    function predictAgentAddress(uint256 tokenId) external view returns (address);

    function admitValidatorRequest(uint256 requestId, bytes32 saltSeed) external returns (address vault, address gauge);
    function createValidator(
        bytes32 saltSeed,
        address expectedAuthAddress,
        bytes calldata payload,
        bytes calldata signedSecpMessage,
        bytes calldata signedBlsMessage
    ) external returns (uint256 requestId, address vault, address gauge);

    function setCommission(uint256 commission_) external;
    function signingConfigFor(address requester, bytes32 saltSeed)
        external
        returns (address authAddress, uint256 commission, uint256 amount);
    function commission() external returns (uint256);

    function deposit(uint256 tokenId) external payable;
    function stake(uint256 tokenId, address[] calldata gauges, uint256[] calldata amounts) external;
    function poke(uint256 tokenId) external returns (bool satisfied);
    function unstake(uint256 tokenId, address[] calldata gauges, uint256[] calldata amounts) external;
    function compound(uint256 tokenId) external returns (uint256 amount);
    function withdraw(uint256 tokenId) external returns (uint256 amount);
    function isFullyUnstaked(uint256 tokenId) external view returns (bool);
    function claimRewards(uint256 tokenId, address[] calldata gauges) external;
}
