// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMonadStaking} from "../interfaces/IMonadStaking.sol";

/// @title ProtocolTimeLibrary
/// @notice Vote cycles mapped from Monad staking epochs at `0x1000`.
/// @dev One cycle is `EPOCHS_PER_CYCLE` consecutive Monad epochs. Cycle `k` covers
///      `[5k, 5k+5)`. A 1-epoch buffer at each end is the vote window analogue of
///      Velodrome's ±1 hour. "Epoch" in this library always means a Monad staking epoch.
library ProtocolTimeLibrary {
    uint64 internal constant EPOCHS_PER_CYCLE = 5;
    uint64 internal constant VOTE_BUFFER_EPOCHS = 1;
    address internal constant STAKING_PRECOMPILE = 0x0000000000000000000000000000000000001000;

    /// @dev Monad epochs in one vote cycle (`EPOCHS_PER_CYCLE`).
    function cycleDuration() internal pure returns (uint64) {
        return EPOCHS_PER_CYCLE;
    }

    /// @dev Cycle index containing `epoch` (`epoch / 5`).
    function cycleOf(uint64 epoch) internal pure returns (uint64) {
        return epoch / EPOCHS_PER_CYCLE;
    }

    /// @dev First Monad epoch of the cycle containing `epoch`.
    function cycleStart(uint64 epoch) internal pure returns (uint64) {
        unchecked {
            return epoch - (epoch % EPOCHS_PER_CYCLE);
        }
    }

    /// @dev First Monad epoch of the next cycle (exclusive end of this cycle).
    function cycleNext(uint64 epoch) internal pure returns (uint64) {
        unchecked {
            return cycleStart(epoch) + EPOCHS_PER_CYCLE;
        }
    }

    /// @dev First Monad epoch at which anyone may vote this cycle.
    function cycleVoteStart(uint64 epoch) internal pure returns (uint64) {
        return cycleStart(epoch) + VOTE_BUFFER_EPOCHS;
    }

    /// @dev First Monad epoch of the end-of-cycle vote blackout (whitelist-only).
    function cycleVoteEnd(uint64 epoch) internal pure returns (uint64) {
        return cycleNext(epoch) - VOTE_BUFFER_EPOCHS;
    }

    /// @dev True during the start-of-cycle buffer (`epoch < cycleVoteStart`).
    function inDistributeWindow(uint64 epoch) internal pure returns (bool) {
        return epoch < cycleVoteStart(epoch);
    }

    /// @dev True during the end-of-cycle whitelist-only buffer (`epoch >= cycleVoteEnd`).
    function inWhitelistWindow(uint64 epoch) internal pure returns (bool) {
        return epoch >= cycleVoteEnd(epoch);
    }

    /// @dev Current Monad staking epoch from the precompile. Not `view` (`getEpoch` is CALL-only).
    function currentEpoch() internal returns (uint64 epoch, bool inEpochDelayPeriod) {
        return IMonadStaking(STAKING_PRECOMPILE).getEpoch();
    }

    /// @dev Cycle index of the current Monad staking epoch.
    function currentCycle() internal returns (uint64) {
        (uint64 epoch,) = currentEpoch();
        return cycleOf(epoch);
    }
}
