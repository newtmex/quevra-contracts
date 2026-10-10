// SPDX-License-Identifier: MIT
// Derived from Tigris IVotingEscrowBooster.sol.
pragma solidity ^0.8.24;

/// @title IVotingEscrowBooster
/// @notice Hook used by ValidatorsVoter to refresh a veNFT's stored multiplier.
interface IVotingEscrowBooster {
    function updateBoost(uint256 tokenId, uint256 boost) external;
    function notifyBoostableBurned(uint256 tokenId) external;
}
