// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SafeCastLibrary
/// @notice Checked conversions for the signed lock amounts used by veMON.
library SafeCastLibrary {
    error SafeCastOverflow();
    error SafeCastUnderflow();

    function toInt128(uint256 value) internal pure returns (int128) {
        if (value > uint256(uint128(type(int128).max))) revert SafeCastOverflow();
        return int128(uint128(value));
    }

    function toUint256(int128 value) internal pure returns (uint256) {
        if (value < 0) revert SafeCastUnderflow();
        return uint256(int256(value));
    }
}
