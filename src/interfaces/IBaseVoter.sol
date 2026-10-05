// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IBaseVoter
/// @notice Minimal voter surface shared by cycle-scoped reward contracts.
/// @dev Quevra intentionally omits Tigris's governor and emergency-council
///      administration hooks from this base interface.
interface IBaseVoter {
    /// @notice The ve token governed by this voter/controller.
    function ve() external view returns (address);

    /// @notice Whether a token may be used as a protocol reward.
    function isWhitelistedToken(address token) external view returns (bool);
}
