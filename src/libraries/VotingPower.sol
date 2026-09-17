// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title VotingPower
/// @notice Linear-decay vote weight: `amount * remaining / maxLockTime`.
library VotingPower {
    function votingPower(uint256 amount, uint256 end, uint256 timestamp, uint256 maxLockTime)
        internal
        pure
        returns (uint256)
    {
        if (amount == 0 || maxLockTime == 0 || timestamp >= end) return 0;
        uint256 remaining = end - timestamp;
        if (remaining > maxLockTime) remaining = maxLockTime;
        return amount * remaining / maxLockTime;
    }
}
