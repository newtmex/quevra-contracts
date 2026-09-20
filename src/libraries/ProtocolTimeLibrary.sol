// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";

/// @title ProtocolTimeLibrary
/// @notice Vote-cycle windows aligned to Monad staking epochs.
/// @dev One cycle is `EPOCHS_PER_CYCLE` consecutive epochs from `getEpoch()` at `0x1000`.
///      Cycle `k` covers Monad epochs `[5k, 5k+5)`. A 1-epoch buffer at each end is the
///      discrete analogue of Velodrome's ±1 hour vote window.
library ProtocolTimeLibrary {
    uint64 internal constant EPOCHS_PER_CYCLE = 5; // 5 is good for testnet; 40 will be more practical for mainnet
    uint64 internal constant VOTE_BUFFER_EPOCHS = 1;
    address internal constant STAKING_PRECOMPILE = 0x0000000000000000000000000000000000001000;

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

    /// @dev Current Monad staking epoch from the precompile. Not `view` (`getEpoch` is CALL-only).
    function currentEpoch() internal returns (uint64 epoch, bool inEpochDelayPeriod) {
        return IMonadStaking(STAKING_PRECOMPILE).getEpoch();
    }

    /// @dev Read-only counterpart for view APIs that need the current epoch.
    ///      The staking precompile exposes getEpoch as CALL-only on some runtimes;
    ///      this static call preserves Solidity view compatibility where supported.
    function currentEpochView() internal view returns (uint64 epoch, bool inEpochDelayPeriod) {
        (bool success, bytes memory data) =
            STAKING_PRECOMPILE.staticcall(abi.encodeWithSelector(IMonadStaking.getEpoch.selector));
        require(success && data.length >= 64, "EPOCH_READ_FAILED");
        return abi.decode(data, (uint64, bool));
    }

    /// @notice First Monad epoch in which a staking state change takes effect.
    /// @dev Monad applies changes submitted before the delay period in epoch + 1,
    ///      and changes submitted during it in epoch + 2.
    function effectiveEpoch(uint64 epoch, bool inEpochDelayPeriod) internal pure returns (uint64) {
        return epoch + (inEpochDelayPeriod ? 2 : 1);
    }

    /// @notice First Monad epoch in which a staking state change takes effect now.
    function currentEffectiveEpoch() internal returns (uint64) {
        (uint64 epoch, bool inEpochDelayPeriod) = currentEpoch();
        return effectiveEpoch(epoch, inEpochDelayPeriod);
    }

    /// @dev Cycle index of the current Monad staking epoch.
    function currentCycle() internal returns (uint64) {
        (uint64 epoch,) = currentEpoch();
        return cycleOf(epoch);
    }

    function currentCycleStart() internal returns (uint64) {
        (uint64 epoch,) = currentEpoch();
        return cycleStart(epoch);
    }
}
