// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IGaugeFactory} from "../interfaces/factories/IGaugeFactory.sol";
import {NonStakingGauge} from "../gauges/NonStakingGauge.sol";

/// @notice Creates the non-staking gauges used for validator reward targets.
contract GaugeFactory is IGaugeFactory {
    function createNonStakingGauge(address forwarder, address rewardToken, address rewardsBeneficiary)
        external
        returns (address gauge)
    {
        gauge = address(new NonStakingGauge(forwarder, rewardToken, msg.sender, rewardsBeneficiary));
    }
}
