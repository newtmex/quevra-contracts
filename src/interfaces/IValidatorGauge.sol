// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IValidatorGauge {
    error NotAuthorized();
    error ZeroAddress();
    error RewardTokenNotWhitelisted();
    error InvalidRewardToken();
    error ZeroRewardRate();

    function voter() external view returns (address);
    function ve() external view returns (address);
    function totalActiveLiquidity() external view returns (uint256);
    function activeLiquidity(uint256 tokenId) external view returns (uint256);
    function updateLiquidity(uint256 tokenId, uint256 amount) external;
    function notifyRewardAmount(address token, uint256 amount) external;
    function earned(address token, uint256 tokenId) external view returns (uint256 amount);
    function claimTokenReward(uint256 tokenId) external returns (uint256 amount);
}
