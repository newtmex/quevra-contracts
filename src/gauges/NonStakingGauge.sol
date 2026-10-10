// SPDX-License-Identifier: MIT
// Derived from Tigris NonStakingGauge.sol by veldorome.finance, @figs999, and @pegahcarter.
pragma solidity ^0.8.24;

import {Gauge} from "./Gauge.sol";
import {INonStakingGauge} from "../interfaces/INonStakingGauge.sol";

/// @dev Adapted from Tigris's NonStakingGauge. On a beneficiary switch, this implementation settles
///      the outgoing account before clearing its virtual balance and settles the incoming account
///      before assigning that balance.
contract NonStakingGauge is Gauge, INonStakingGauge {
    /// @inheritdoc INonStakingGauge
    address public override rewardsBeneficiary;

    /// @notice Creates the gauge and assigns its virtual unit to the initial beneficiary.
    constructor(address rewardToken_, address voter_, address beneficiary_) Gauge(rewardToken_, voter_) {
        _switchRewardsBeneficiary(beneficiary_);
    }

    /// @inheritdoc INonStakingGauge
    function switchRewardsBeneficiary(address newBeneficiary) external override {
        if (msg.sender != rewardsBeneficiary) revert NotAuthorized();
        if (newBeneficiary == address(0)) revert ZeroAmount();
        _switchRewardsBeneficiary(newBeneficiary);
    }

    /// @dev Settles the old beneficiary before moving the one-unit eligible balance.
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
