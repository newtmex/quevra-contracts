// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {INonStakingGauge} from "../interfaces/INonStakingGauge.sol";
import {Gauge} from "./Gauge.sol";

/// @title Non-staking gauge
/// @notice Simplified version of the gauge with the following features:
///         - No staking required. The gauge assumes there is 1 unit of a virtual
///           token deposited for rewards.
///         - All rewards go to a single beneficiary address that controls the 1
///           unit of virtual token.
///         - This contract DOES NOT assume any incentives for voters. An
///           arbitrary incentives mechanism can be used inside the `voter` that
///           controls the non-staking gauges.
contract NonStakingGauge is INonStakingGauge, Gauge {
    /// @inheritdoc INonStakingGauge
    address public rewardsBeneficiary;

    /// @dev Constructor DOES NOT validate input parameters.
    ///      The caller must ensure their validity.
    constructor(address _forwarder, address _rewardToken, address _voter, address _rewardsBeneficiary)
        Gauge(_forwarder, _rewardToken, _voter)
    {
        _switchRewardsBeneficiary(_rewardsBeneficiary);
    }

    /// @inheritdoc INonStakingGauge
    function switchRewardsBeneficiary(address newBeneficiary) external {
        if (_msgSender() != rewardsBeneficiary) revert NotAuthorized();

        // Do not allow the beneficiary to be set to the zero address.
        if (newBeneficiary == address(0)) revert ZeroAddress();

        _switchRewardsBeneficiary(newBeneficiary);
    }

    /// @dev Switches the rewards beneficiary. To adhere to the existing rewards
    /// distribution logic, we pretend the beneficiary maintains a position
    /// of 1 unit of a virtual token and controls the whole supply.
    /// This ensures 100% of rewards go to the beneficiary.
    function _switchRewardsBeneficiary(address newBeneficiary) internal {
        uint256 virtualAmount = 1;
        address oldBeneficiary = rewardsBeneficiary;

        // Cleanup if the old beneficiary was set.
        if (oldBeneficiary != address(0)) {
            _updateRewards(oldBeneficiary);
            totalSupply = 0;
            balanceOf[oldBeneficiary] = 0;
        }

        rewardsBeneficiary = newBeneficiary;
        emit RewardsBeneficiarySwitched(oldBeneficiary, newBeneficiary);

        // If this is beneficiary update but not cleanup, perform
        // the necessary bookkeeping.
        if (newBeneficiary != address(0)) {
            // With no virtual supply there is no new reward interval to accrue.
            // Avoid reading the epoch precompile during initial gauge creation.
            if (totalSupply != 0) {
                _updateRewards(newBeneficiary);
            } else {
                userRewardPerTokenPaid[newBeneficiary] = rewardPerTokenStored;
            }
            totalSupply = virtualAmount;
            balanceOf[newBeneficiary] = virtualAmount;
        }
    }
}
