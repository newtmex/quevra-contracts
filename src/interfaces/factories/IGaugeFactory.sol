// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IGaugeFactory {
    function createNonStakingGauge(address forwarder, address rewardToken, address rewardsBeneficiary)
        external
        returns (address);
}
