// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IBaseVoter {
    /// @notice The ve token that governs these contracts
    function ve() external view returns (address);

    /// @notice Standard OZ IGovernor using ve for vote weights.
    function governor() external view returns (address);

    /// @notice credibly neutral party similar to Curve's Emergency DAO
    function emergencyCouncil() external view returns (address);

    /// @dev Token => Whitelisted status
    function isWhitelistedToken(address token) external view returns (bool);
}
