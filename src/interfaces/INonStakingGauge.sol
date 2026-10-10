// SPDX-License-Identifier: MIT
// Derived from Tigris INonStakingGauge.sol by veldorome.finance, @figs999, and @pegahcarter.
pragma solidity ^0.8.24;

/// @title Quevra Non-Staking Gauge Interface
/// @author Tigris contributors (veldorome.finance, @figs999, and @pegahcarter); adapted by Quevra contributors
/// @notice Beneficiary management API for a gauge that distributes emissions without staked positions.
/// @dev The implementation assigns one virtual unit of gauge balance to a beneficiary. This interface
///      does not describe veMON voting, validator stake, or native Monad staking reward accounting.
interface INonStakingGauge {
    /// @notice The beneficiary controlling the virtual gauge balance changed.
    event RewardsBeneficiarySwitched(address indexed oldBeneficiary, address indexed newBeneficiary);

    /// @notice Current recipient of the gauge's emissions.
    function rewardsBeneficiary() external view returns (address);

    /// @notice Moves the virtual gauge balance and future emissions to a new beneficiary.
    /// @dev Only the current beneficiary may call; implementations reject the zero address.
    function switchRewardsBeneficiary(address newBeneficiary) external;
}
