// SPDX-License-Identifier: MIT
// Derived from Tigris IBaseVoter.sol.
// Upstream: tigris/solidity/contracts/interfaces/IBaseVoter.sol @ fa9ba83d93d4ee362b0699e7bcd13d32e150afda
// Provenance: docs/provenance.md
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
