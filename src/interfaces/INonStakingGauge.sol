// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IGauge} from "./IGauge.sol";

/// @title Non-staking gauge
/// @notice Minimal interface describing a non-staking gauge. Unlike a standard
///         Gauge, the non-staking gauge does not require staking a token.
///         Since the token is not staked, the gauge does not claim the
///         generated fees and only bribes are distributed. Another difference
///         is that for a non-staking gauge, bribes are distributed to a single
///         beneficiary address that may - at their own discretion - share them
///         with voters on the gauge.
interface INonStakingGauge is IGauge {
    error ZeroAddress();

    event RewardsBeneficiarySwitched(address indexed oldBeneficiary, address indexed newBeneficiary);

    /// @notice Address of the current rewards beneficiary
    function rewardsBeneficiary() external view returns (address);

    /// @notice Switches the rewards beneficiary.
    /// @param newBeneficiary The new rewards beneficiary.
    /// @dev Requirements:
    /// - The caller must be the current rewards beneficiary.
    /// - The new beneficiary must not be the zero address.
    function switchRewardsBeneficiary(address newBeneficiary) external;
}
