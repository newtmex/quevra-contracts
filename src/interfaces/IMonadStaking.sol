// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Monad staking precompile interface for validator creation.
/// @dev Precompile at 0x1000. Only CALL is allowed.
interface IMonadStaking {
    function addValidator(bytes calldata payload, bytes calldata signedSecpMessage, bytes calldata signedBlsMessage)
        external
        payable
        returns (uint64 validatorId);
}
