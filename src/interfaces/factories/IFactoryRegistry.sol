// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IFactoryRegistry {
    function isGaugeFactoryApproved(address gaugeFactory) external view returns (bool);
    function gaugeFactoryToVotingRewardsFactory(address gaugeFactory) external view returns (address);
}
