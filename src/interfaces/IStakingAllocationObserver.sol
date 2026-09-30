// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Callback used by the staking controller when active validator backing changes.
/// @dev This deliberately carries no voting-weight information. Voting power and active
///      stake are independent pieces of voter state.
interface IStakingAllocationObserver {
    function notifyActiveAllocation(uint256 tokenId, address gauge, uint256 activeAmount) external;
}
