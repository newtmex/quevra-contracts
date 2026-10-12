// SPDX-License-Identifier: BUSL-1.1
// Adapted from Tigris SafeCastLibrary.sol (BUSL-1.1).
// Upstream: tigris/solidity/contracts/libraries/SafeCastLibrary.sol @ fa9ba83d93d4ee362b0699e7bcd13d32e150afda
// License text: LICENSE-BUSL-1.1.txt — provenance: docs/provenance.md
pragma solidity ^0.8.24;

/// @title SafeCastLibrary
/// @author Adapted from Tigris by velodrome.finance
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
