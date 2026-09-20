// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IVotingRewardsFactory {
    function createBribeReward(address forwarder, address[] memory rewards) external returns (address bribeVotingReward);
}
