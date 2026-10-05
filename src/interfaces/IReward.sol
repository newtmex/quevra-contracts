// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IReward {
    error InvalidReward();
    error NotAuthorized();
    error NotGauge();
    error NotEscrowToken();
    error NotSingleToken();
    error NotVotingEscrow();
    error NotWhitelisted();
    error ZeroAmount();

    event Deposit(address indexed from, uint256 indexed tokenId, uint256 amount);
    event Withdraw(address indexed from, uint256 indexed tokenId, uint256 amount);
    event NotifyReward(address indexed from, address indexed reward, uint256 indexed cycle, uint256 amount);
    event ClaimRewards(address indexed from, address indexed reward, uint256 amount);

    struct Checkpoint {
        uint256 cycle;
        uint256 balanceOf;
    }

    struct SupplyCheckpoint {
        uint256 cycle;
        uint256 supply;
    }

    function duration() external pure returns (uint256);
    function voter() external view returns (address);
    function ve() external view returns (address);
    function authorized() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(uint256 tokenId) external view returns (uint256);
    function tokenRewardsPerCycle(address token, uint256 cycle) external view returns (uint256);
    function lastEarnEpoch(address token, uint256 tokenId) external view returns (uint256);
    function isReward(address token) external view returns (bool);
    function numCheckpoints(uint256 tokenId) external view returns (uint256);
    function supplyNumCheckpoints() external view returns (uint256);

    function _deposit(uint256 amount, uint256 tokenId) external;
    function _withdraw(uint256 amount, uint256 tokenId) external;
    function getReward(uint256 tokenId, address[] memory tokens) external;
    function notifyRewardAmount(address token, uint256 amount) external;
    function getPriorBalanceIndex(uint256 tokenId, uint256 cycle) external view returns (uint256);
    function getPriorSupplyIndex(uint256 cycle) external view returns (uint256);
    function rewardsListLength() external view returns (uint256);
    function earned(address token, uint256 tokenId) external view returns (uint256);
}
