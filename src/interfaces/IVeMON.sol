// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVotingEscrow} from "./IVotingEscrow.sol";

/// @notice veMON-specific links used by the staking controller and its voter.
interface IVeMON is IVotingEscrow {
    function controller() external view returns (address);
    function booster() external view returns (address);
    function setBooster(address booster_) external;
}
