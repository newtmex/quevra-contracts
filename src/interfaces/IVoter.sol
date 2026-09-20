// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBaseVoter} from "./IBaseVoter.sol";

interface IVoter is IBaseVoter {
    /// @notice Update voting weights for a veNFT.
    function poke(uint256 _tokenId) external;

    /// @notice Allocate a veNFT's voting weight across the selected gauges.
    /// @param _tokenId Id of the voting veNFT.
    /// @param _poolVote Gauges receiving votes.
    /// @param _weights Relative voting weights.
    function vote(uint256 _tokenId, address[] calldata _poolVote, uint256[] calldata _weights) external;

    /// @notice Reset a veNFT's votes.
    function reset(uint256 _tokenId) external;
}
