// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ValidatorPayloadLibrary
/// @notice Reads fixed fields from Monad's 165-byte addValidator payload.
library ValidatorPayloadLibrary {
    uint256 internal constant PAYLOAD_LENGTH = 165;
    uint256 private constant AUTH_ADDRESS_OFFSET = 81;
    uint256 private constant COMMISSION_OFFSET = 133;

    error InvalidPayloadLength();

    function authAddress(bytes memory payload) internal pure returns (address value) {
        _checkPayload(payload);
        assembly ("memory-safe") {
            value := shr(96, mload(add(payload, 113)))
        }
    }

    function commission(bytes memory payload) internal pure returns (uint256 value) {
        _checkPayload(payload);
        assembly ("memory-safe") {
            value := mload(add(payload, 189))
        }
    }

    function _checkPayload(bytes memory payload) private pure {
        if (payload.length != PAYLOAD_LENGTH) revert InvalidPayloadLength();
    }
}
