// SPDX-License-Identifier: MIT
// Derived from Tigris IGauge.sol by veldorome.finance, @figs999, and @pegahcarter.
pragma solidity ^0.8.24;

/// @title Quevra Gauge Interface
/// @author Tigris contributors (veldorome.finance, @figs999, and @pegahcarter); adapted by Quevra contributors
/// @notice Read and action API for epoch-based ERC-20 gauge emissions.
/// @dev Reward periods use Monad staking epochs and Quevra cycle boundaries. This interface describes
///      gauge emissions; veMON vote checkpoints, validator incentives, and native staking rewards are
///      accounted for by separate protocol modules.
interface IGauge {
    error NotAuthorized();
    error NotVoter();
    error RewardRateTooHigh();
    error ZeroAmount();
    error ZeroRewardRate();

    /// @notice Emission tokens were funded by the voter.
    event NotifyReward(address indexed from, uint256 amount);
    /// @notice An account's accrued emission tokens were paid to it.
    event ClaimRewards(address indexed account, uint256 amount);

    /// @notice ERC-20 token distributed by this gauge.
    function rewardToken() external view returns (address);
    /// @notice Voter authorized to fund emissions and claim for an account.
    function voter() external view returns (address);
    /// @notice Voting-escrow contract configured on the voter.
    function ve() external view returns (address);
    /// @notice Exclusive end epoch of the current emission period.
    function periodFinish() external view returns (uint256);
    /// @notice Current emission rate in reward tokens per Monad staking epoch.
    function rewardRate() external view returns (uint256);
    /// @notice Last epoch included in stored reward accounting.
    function lastUpdateTime() external view returns (uint256);
    /// @notice Stored cumulative emissions per unit of eligible gauge balance, scaled by 1e18.
    function rewardPerTokenStored() external view returns (uint256);
    /// @notice Total eligible gauge balance.
    function totalSupply() external view returns (uint256);
    /// @notice Eligible gauge balance assigned to an account.
    function balanceOf(address account) external view returns (uint256);
    /// @notice Cumulative reward-per-token value already accounted for an account.
    function userRewardPerTokenPaid(address account) external view returns (uint256);
    /// @notice Emissions accrued and not yet claimed by an account.
    function rewards(address account) external view returns (uint256);
    /// @notice Emission rate recorded for a cycle's starting epoch.
    function rewardRateByEpoch(uint256 epoch) external view returns (uint256);

    /// @notice Returns cumulative emissions per unit of eligible gauge balance.
    /// @dev Not `view` because reading the current epoch calls Monad's staking precompile.
    function rewardPerToken() external returns (uint256);
    /// @notice Returns the final epoch eligible for accrual in the active period.
    function lastTimeRewardApplicable() external returns (uint256);
    /// @notice Returns an account's accrued and currently accruing emissions.
    function earned(address account) external returns (uint256);
    /// @notice Returns the undistributed emission amount remaining in the active period.
    function left() external returns (uint256);
    /// @notice Claims an account's accrued emissions, paying the account itself.
    /// @dev The account or configured voter may initiate the claim.
    function getReward(address account) external;
    /// @notice Funds emissions from the configured voter through the next cycle boundary.
    /// @dev The voter must approve this gauge to transfer `amount` of `rewardToken`.
    function notifyRewardAmount(uint256 amount) external;
}
