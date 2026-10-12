// SPDX-License-Identifier: MIT
// Derived from Tigris IVotingEscrowBooster.sol.
// Upstream: tigris/solidity/contracts/interfaces/IVotingEscrowBooster.sol @ fa9ba83d93d4ee362b0699e7bcd13d32e150afda
// Provenance: docs/provenance.md
pragma solidity ^0.8.24;

/// @title IVotingEscrowBooster
/// @notice Hook used by ValidatorsVoter to refresh a veNFT's stored multiplier.
interface IVotingEscrowBooster {
    function updateBoost(uint256 tokenId, uint256 boost) external;
    function notifyBoostableBurned(uint256 tokenId) external;
}
