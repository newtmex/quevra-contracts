// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IVotingEscrowBooster
/// @notice Hook used by a boost voter to refresh a veNFT's stored multiplier.
interface IVotingEscrowBooster {
    function updateBoost(uint256 tokenId, uint256 boost) external;
    function notifyBoostableBurned(uint256 tokenId) external;
}
