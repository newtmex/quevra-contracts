// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IGauge {
    error NotAuthorized();
    error NotVoter();
    error RewardRateTooHigh();
    error ZeroAmount();
    error ZeroRewardRate();

    event NotifyReward(address indexed from, uint256 amount);
    event ClaimRewards(address indexed account, uint256 amount);

    function rewardToken() external view returns (address);
    function voter() external view returns (address);
    function ve() external view returns (address);
    function periodFinish() external view returns (uint256);
    function rewardRate() external view returns (uint256);
    function lastUpdateTime() external view returns (uint256);
    function rewardPerTokenStored() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function userRewardPerTokenPaid(address account) external view returns (uint256);
    function rewards(address account) external view returns (uint256);
    function rewardRateByEpoch(uint256 epoch) external view returns (uint256);

    // These functions read the Monad staking precompile and are therefore not view.
    function rewardPerToken() external returns (uint256);
    function lastTimeRewardApplicable() external returns (uint256);
    function earned(address account) external returns (uint256);
    function left() external returns (uint256);
    function getReward(address account) external;
    function notifyRewardAmount(uint256 amount) external;
}
