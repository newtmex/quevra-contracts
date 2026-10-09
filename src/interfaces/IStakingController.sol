// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IStakingController {
    struct Position {
        address vault;
        address agent;
        uint64 validatorId;
        uint256 vaultAllocation;
        uint256 agentAllocation;
        uint256 vaultPending;
        uint256 agentPending;
    }

    struct PokeBatch {
        address agent;
        uint256 liquid;
        uint256 delegateCount;
        uint256 delegateValue;
        uint64[] delegateValidators;
        uint256[] delegateAmounts;
    }

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
    error NotVaultParticipant();
    error TransferFailed();
    error StakingCycleNotAdvanced();
    error DuplicateVault();
    error InvalidValidatorRequest();

    event VeSet(address indexed ve);
    event VaultRegistered(uint256 indexed tokenId, address indexed vault, address operator);
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
    function vaultImplementation() external view returns (address);
    function agentImplementation() external view returns (address);
    function isValidatorActive(address vault) external view returns (bool);
    function balanceOf(uint256 tokenId) external view returns (uint256);
    /// @notice Canonical locked principal for a veMON position, including staked MON.
    function veMONPrincipalOf(uint256 tokenId) external view returns (uint256);
    /// @notice Canonical active backing for a veValidator position.
    function validatorBackingOf(uint256 tokenId) external view returns (uint256);
    function stakingCycleOf(uint256 tokenId) external view returns (uint64);
    function intentOf(uint256 tokenId, address vault) external view returns (uint256);
    function agentByToken(uint256 tokenId) external view returns (address);
    function allocationOf(uint256 tokenId, address vault) external view returns (uint256);
    function pendingOf(uint256 tokenId, address vault) external view returns (uint256);

    function setVe(address ve_) external;
    function setValidatorVe(address veValidator_) external;
    function registerValidatorPosition(address vault, uint256 tokenId) external;
    function validatorVe() external view returns (address);
    function validatorTokenIdOf(address vault) external view returns (uint256);
    function predictVaultAddress(address requester, bytes32 saltSeed) external view returns (address);
    function predictAgentAddress(uint256 tokenId) external view returns (address);

    function deployValidatorVault(address operator, uint256 tokenId, bytes32 saltSeed, address expectedAuthAddress)
        external
        returns (address vault);

    function setCommission(uint256 commission_) external;
    function signingConfigFor(address requester, bytes32 saltSeed)
        external
        returns (address authAddress, uint256 commission, uint256 amount);
    function commission() external returns (uint256);

    function deposit(uint256 tokenId) external payable;
    function stake(uint256 tokenId, address[] calldata vaults, uint256[] calldata amounts) external;
    function poke(uint256 tokenId) external returns (bool satisfied);
    function unstake(uint256 tokenId, address[] calldata vaults, uint256[] calldata amounts) external;
    function compound(uint256 tokenId, address[] calldata vaults) external returns (uint256 amount);
    function withdraw(uint256 tokenId) external returns (uint256 amount);
    function isFullyUnstaked(uint256 tokenId) external view returns (bool);
    function claimRewards(uint256 tokenId, address[] calldata vaults) external;
}
