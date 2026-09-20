// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IGauge {
    error NotAuthorized();
    error NotVoter();
    error RewardRateTooHigh();
    error ZeroAmount();
    error ZeroRewardRate();

    event NotifyReward(address indexed from, uint256 amount);
    event ClaimRewards(address indexed from, uint256 amount);

    /// @notice Address of the token rewarded to stakers
    function rewardToken() external view returns (address);

    /// @notice Address of Protocol Voter
    function voter() external view returns (address);

    /// @notice Address of Protocol Voting Escrow
    function ve() external view returns (address);

    /// @notice Monad epoch at the end of the current reward cycle
    function periodFinish() external view returns (uint256);

    /// @notice Current reward rate of rewardToken to distribute per Monad epoch
    function rewardRate() external view returns (uint256);

    /// @notice Most recent Monad epoch contract has updated state
    function lastUpdateTime() external view returns (uint256);

    /// @notice Most recent stored value of rewardPerToken
    function rewardPerTokenStored() external view returns (uint256);

    /// @notice Amount of stakingToken deposited for rewards
    function totalSupply() external view returns (uint256);

    /// @notice Get the amount of stakingToken deposited by an account
    function balanceOf(address) external view returns (uint256);

    /// @notice Cached rewardPerTokenStored for an account based on their most recent action
    function userRewardPerTokenPaid(address) external view returns (uint256);

    /// @notice Cached amount of rewardToken earned for an account
    function rewards(address) external view returns (uint256);

    /// @notice Gets the latest rewardRate for a given Monad epoch.
    /// @dev Returns the most recent reward rate for the epoch. If additional
    ///      rewards were added mid-epoch, this reflects the updated rate for
    ///      distributing remaining rewards over remaining time. The rewards
    ///      already distributed are not included.
    function rewardRateByEpoch(uint256) external view returns (uint256);

    /// @notice Get the current reward rate per unit of stakingToken deposited
    function rewardPerToken() external view returns (uint256 _rewardPerToken);

    /// @notice Returns the current applicable Monad epoch for reward calculations.
    /// @dev Returns current Monad epoch if rewards are active, or periodFinish if
    ///      reward period has ended
    function lastTimeRewardApplicable() external view returns (uint256 _time);

    /// @notice Returns accrued balance to date from last claim / first deposit.
    function earned(address _account) external view returns (uint256 _earned);

    /// @notice Total amount of rewardToken to distribute for the current rewards period
    function left() external view returns (uint256 _left);

    /// @notice Retrieve rewards for an address.
    /// @dev Throws if not called by same address or voter.
    /// @param _account .
    function getReward(address _account) external;

    /// @dev Notifies gauge of gauge rewards. Assumes gauge reward tokens is 18 decimals.
    ///      If not 18 decimals, rewardRate may have rounding issues.
    function notifyRewardAmount(uint256 amount) external;
}
