// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Gauge} from "./Gauge.sol";
import {INonStakingGauge} from "../interfaces/INonStakingGauge.sol";

/// @notice Gauge with one virtual unit and a single rewards beneficiary.
contract NonStakingGauge is Gauge, INonStakingGauge {
    address public override rewardsBeneficiary;

    constructor(address rewardToken_, address voter_, address beneficiary_) Gauge(rewardToken_, voter_) {
        _switchRewardsBeneficiary(beneficiary_);
    }

    function switchRewardsBeneficiary(address newBeneficiary) external override {
        if (msg.sender != rewardsBeneficiary) revert NotAuthorized();
        if (newBeneficiary == address(0)) revert ZeroAmount();
        _switchRewardsBeneficiary(newBeneficiary);
    }

    function _switchRewardsBeneficiary(address newBeneficiary) internal {
        address oldBeneficiary = rewardsBeneficiary;
        if (oldBeneficiary != address(0)) {
            _updateRewards(oldBeneficiary);
            totalSupply = 0;
            balanceOf[oldBeneficiary] = 0;
        }
        rewardsBeneficiary = newBeneficiary;
        emit RewardsBeneficiarySwitched(oldBeneficiary, newBeneficiary);
        _updateRewards(newBeneficiary);
        totalSupply = 1;
        balanceOf[newBeneficiary] = 1;
    }
}
