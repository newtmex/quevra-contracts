// SPDX-License-Identifier: MIT
// Derived from Tigris IReward.sol.
pragma solidity ^0.8.24;

interface IReward {
    error InvalidReward();
    error NotAuthorized();
    error NotEscrowToken();
    error NotSingleToken();
    error NotVotingEscrow();
    error NotWhitelisted();
    error ZeroAmount();

    /// @notice A voter deposited voting balance for a token ID.
    event Deposit(address indexed from, uint256 indexed tokenId, uint256 amount);
    /// @notice A voter withdrew voting balance for a token ID.
    event Withdraw(address indexed from, uint256 indexed tokenId, uint256 amount);
    /// @notice Reward tokens were funded for the indexed Quevra cycle.
    event NotifyReward(address indexed from, address indexed reward, uint256 indexed cycle, uint256 amount);
    /// @notice A token ID's earned reward was paid to its owner.
    event ClaimRewards(address indexed from, address indexed reward, uint256 amount);

    struct Checkpoint {
        uint256 cycle;
        uint256 balanceOf;
    }

    struct SupplyCheckpoint {
        uint256 cycle;
        uint256 supply;
    }

    /// @notice Number of Monad staking epochs in one Quevra accounting cycle.
    function duration() external pure returns (uint256);
    /// @notice Voter authorized to change balances and cycle reward weights.
    function voter() external view returns (address);
    /// @notice Voting-escrow NFT contract whose positions earn rewards.
    function ve() external view returns (address);
    /// @notice Account authorized by the voter to deposit and withdraw balance.
    function authorized() external view returns (address);
    /// @notice Total eligible balance across all token IDs.
    function totalSupply() external view returns (uint256);
    /// @notice Eligible balance assigned to a token ID.
    function balanceOf(uint256 tokenId) external view returns (uint256);
    /// @notice Amount of `token` funded for a cycle start epoch.
    function tokenRewardsPerCycle(address token, uint256 cycle) external view returns (uint256);
    /// @notice Last Monad epoch included in reward claims for this token and position.
    function lastEarnEpoch(address token, uint256 tokenId) external view returns (uint256);
    /// @notice Whether a token is enabled for this reward contract.
    function isReward(address token) external view returns (bool);
    /// @notice Number of balance checkpoints stored for a token ID.
    function numCheckpoints(uint256 tokenId) external view returns (uint256);
    /// @notice Number of total-supply checkpoints stored.
    function supplyNumCheckpoints() external view returns (uint256);

    /// @notice Adds eligible balance for a token ID; callable only by `authorized`.
    function _deposit(uint256 amount, uint256 tokenId) external;
    /// @notice Removes eligible balance for a token ID; callable only by `authorized`.
    function _withdraw(uint256 amount, uint256 tokenId) external;
    /// @notice Claims selected reward tokens for a token ID, paying its current owner.
    function getReward(uint256 tokenId, address[] memory tokens) external;
    /// @notice Funds reward tokens for the current Quevra cycle.
    function notifyRewardAmount(address token, uint256 amount) external;
    /// @notice Finds the latest balance checkpoint at or before a cycle boundary.
    function getPriorBalanceIndex(uint256 tokenId, uint256 cycle) external view returns (uint256);
    /// @notice Finds the latest supply checkpoint at or before a cycle boundary.
    function getPriorSupplyIndex(uint256 cycle) external view returns (uint256);
    /// @notice Number of reward tokens registered with this contract.
    function rewardsListLength() external view returns (uint256);
    /// @notice Calculates the token ID's unclaimed reward using completed cycle checkpoints.
    /// @dev This is intentionally non-view because Monad's getEpoch precompile
    ///      endpoint is CALL-only. RPC eth_call remains safe for consumers.
    function earned(address token, uint256 tokenId) external returns (uint256);
}
