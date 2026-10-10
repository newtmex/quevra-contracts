// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IStakingController {
    /// @notice Snapshot of one token's active and pending stake in a validator.
    struct Position {
        address vault;
        address agent;
        uint64 validatorId;
        uint256 vaultAllocation;
        uint256 agentAllocation;
        uint256 vaultPending;
        uint256 agentPending;
    }

    /// @notice Batch of delegated operations prepared while settling a token's staking intent.
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

    /// @notice veMON contract whose token IDs own deposited principal.
    function ve() external view returns (address);
    /// @notice Implementation used to clone validator-bound staking vaults.
    function vaultImplementation() external view returns (address);
    /// @notice Implementation used to clone token-bound staking agents.
    function agentImplementation() external view returns (address);
    /// @notice Whether `vault` is a registered validator vault.
    function isValidatorActive(address vault) external view returns (bool);
    /// @notice Liquid MON credited to a veMON token and not currently allocated or pending withdrawal.
    function balanceOf(uint256 tokenId) external view returns (uint256);
    /// @notice Canonical locked principal for a veMON position, including staked MON.
    function veMONPrincipalOf(uint256 tokenId) external view returns (uint256);
    /// @notice Canonical active backing for a veValidator position.
    function validatorBackingOf(uint256 tokenId) external view returns (uint256);
    /// @notice Most recent cycle in which a stake allocation was set for a token.
    function stakingCycleOf(uint256 tokenId) external view returns (uint64);
    /// @notice Current target allocation for a token and validator vault.
    function intentOf(uint256 tokenId, address vault) external view returns (uint256);
    /// @notice Token-specific staking agent, if one has been created.
    function agentByToken(uint256 tokenId) external view returns (address);
    /// @notice Active MON allocation across the vault and agent for a token and vault.
    function allocationOf(uint256 tokenId, address vault) external view returns (uint256);
    /// @notice MON pending withdrawal from the vault and agent for a token and vault.
    function pendingOf(uint256 tokenId, address vault) external view returns (uint256);

    /// @notice Binds the veMON contract once; callable by the owner.
    function setVe(address ve_) external;
    /// @notice Binds the veValidator contract once; callable by the owner.
    function setValidatorVe(address veValidator_) external;
    /// @notice Registers a validator token and its vault; callable by veValidator.
    function registerValidatorPosition(address vault, uint256 tokenId) external;
    /// @notice veValidator contract associated with this controller.
    function validatorVe() external view returns (address);
    /// @notice veValidator token ID registered for a vault, or zero if unbound.
    function validatorTokenIdOf(address vault) external view returns (uint256);
    /// @notice Predicts a requester's deterministic validator vault address.
    function predictVaultAddress(address requester, bytes32 saltSeed) external view returns (address);
    /// @notice Predicts a token ID's deterministic staking-agent address.
    function predictAgentAddress(uint256 tokenId) external view returns (address);

    /// @notice Deploys a vault for a validator submission created by veValidator.
    function deployValidatorVault(address operator, uint256 tokenId, bytes32 saltSeed, address expectedAuthAddress)
        external
        returns (address vault);

    /// @notice Schedules a commission update for its configured future cycle; owner only.
    function setCommission(uint256 commission_) external;
    /// @notice Returns signing parameters for the requested validator's auth address.
    function signingConfigFor(address requester, bytes32 saltSeed)
        external
        returns (address authAddress, uint256 commission, uint256 amount);
    /// @notice Current effective validator commission, applying any matured schedule.
    function commission() external returns (uint256);

    /// @notice Credits deposited MON to a veMON token; callable only by the veMON contract.
    function deposit(uint256 tokenId) external payable;
    /// @notice Sets the token's validator allocation for the current cycle and begins settlement.
    function stake(uint256 tokenId, address[] calldata vaults, uint256[] calldata amounts) external;
    /// @notice Advances a token's physical positions toward its current allocation intent.
    function poke(uint256 tokenId) external returns (bool satisfied);
    /// @notice Reclaims selected allocations after beginning any required undelegation.
    function unstake(uint256 tokenId, address[] calldata vaults, uint256[] calldata amounts) external;
    /// @notice Claims and compounds selected validator rewards into the token's principal.
    function compound(uint256 tokenId, address[] calldata vaults) external returns (uint256 amount);
    /// @notice Withdraws matured stake and returns liquid MON to the veMON token owner.
    function withdraw(uint256 tokenId) external returns (uint256 amount);
    /// @notice Whether the token has no active or pending stake and no remaining allocation intent.
    function isFullyUnstaked(uint256 tokenId) external view returns (bool);
    /// @notice Claims native rewards earned by selected validator positions for the token owner.
    function claimRewards(uint256 tokenId, address[] calldata vaults) external;
}
