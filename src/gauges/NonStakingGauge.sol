// SPDX-License-Identifier: MIT
// Derived from Tigris NonStakingGauge.sol by veldorome.finance, @figs999, and @pegahcarter.
pragma solidity ^0.8.24;

import {Gauge} from "./Gauge.sol";
import {INonStakingGauge} from "../interfaces/INonStakingGauge.sol";

/// @dev Adapted from Tigris's NonStakingGauge. On a beneficiary switch, this implementation settles
///      the outgoing account before clearing its virtual balance and settles the incoming account
///      before assigning that balance.
contract NonStakingGauge is Gauge, INonStakingGauge {
    /// @custom:storage-location erc7201:quevra.NonStakingGauge
    struct NonStakingGaugeStorage {
        address rewardsBeneficiary;
    }

    bytes32 private constant NON_STAKING_GAUGE_STORAGE_SLOT =
        0x6fff3f7bc49fd683e60930f7c658a8e557965f52d1492d3e14afcd61b94fe000;

    function _nonStakingGaugeStorage() private pure returns (NonStakingGaugeStorage storage $) {
        bytes32 slot = NON_STAKING_GAUGE_STORAGE_SLOT;
        assembly ("memory-safe") { $.slot := slot }
    }

    /// @inheritdoc INonStakingGauge
    function rewardsBeneficiary() public view override returns (address) {
        return _nonStakingGaugeStorage().rewardsBeneficiary;
    }

    /// @notice Creates the gauge and assigns its virtual unit to the initial beneficiary.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address rewardToken_, address voter_, address beneficiary_) external initializer {
        __Gauge_init(rewardToken_, voter_);
        if (beneficiary_ == address(0)) revert ZeroAmount();
        _switchRewardsBeneficiary(beneficiary_);
    }

    /// @inheritdoc INonStakingGauge
    function switchRewardsBeneficiary(address newBeneficiary) external override {
        if (msg.sender != rewardsBeneficiary()) revert NotAuthorized();
        if (newBeneficiary == address(0)) revert ZeroAmount();
        _switchRewardsBeneficiary(newBeneficiary);
    }

    /// @dev Settles the old beneficiary before moving the one-unit eligible balance.
    function _switchRewardsBeneficiary(address newBeneficiary) internal {
        address oldBeneficiary = rewardsBeneficiary();
        GaugeStorage storage gaugeState = _gaugeStorage();
        if (oldBeneficiary != address(0)) {
            _updateRewards(oldBeneficiary);
            gaugeState.totalSupply = 0;
            gaugeState.balanceOf[oldBeneficiary] = 0;
        }
        _nonStakingGaugeStorage().rewardsBeneficiary = newBeneficiary;
        emit RewardsBeneficiarySwitched(oldBeneficiary, newBeneficiary);
        _updateRewards(newBeneficiary);
        gaugeState.totalSupply = 1;
        gaugeState.balanceOf[newBeneficiary] = 1;
    }
}
