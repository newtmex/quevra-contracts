// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVotingRewardsFactory} from "../interfaces/factories/IVotingRewardsFactory.sol";
import {BribeVotingReward} from "../rewards/BribeVotingReward.sol";

/// @notice Creates the bribe reward contract paired with a validator gauge.
contract VotingRewardsFactory is IVotingRewardsFactory {
    function createBribeReward(address forwarder, address[] memory rewards)
        external
        returns (address bribeVotingReward)
    {
        bribeVotingReward = address(new BribeVotingReward(forwarder, msg.sender, rewards));
    }
}
