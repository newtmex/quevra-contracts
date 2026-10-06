// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeCastLibrary} from "./SafeCastLibrary.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";

/// @title BoostLibrary
/// @notice Calculates boosted veMON amounts using a 1e18 multiplier.
library BoostLibrary {
    using SafeCastLibrary for uint256;
    using SafeCastLibrary for int128;

    uint256 internal constant PRECISION = 1e18;

    function boostedAmount(IVotingEscrow.LockedBalance memory lockedBalance) internal pure returns (int128) {
        return boostedAmount(lockedBalance.amount.toUint256(), lockedBalance.boost).toInt128();
    }

    function boostedAmount(uint256 amount, uint256 boost) internal pure returns (uint256) {
        if (boost == 0) return amount;
        return amount * boost / PRECISION;
    }
}
