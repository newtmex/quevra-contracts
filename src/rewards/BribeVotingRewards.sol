// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBaseVoter} from "../interfaces/IBaseVoter.sol";
import {VotingReward} from "./VotingReward.sol";

/// @title BribeVotingRewards
/// @notice Whitelisted token rewards paid to veMON voters for a target.
/// @dev Anyone may fund a bribe. The voter remains the only account that can
///      change the voting balances through {VotingReward}.
contract BribeVotingRewards is VotingReward {
    constructor(address voter_, address[] memory rewardTokens_) VotingReward(voter_, rewardTokens_) {}

    function notifyRewardAmount(address token, uint256 amount) external override nonReentrant {
        if (!isReward[token]) {
            if (!IBaseVoter(voter).isWhitelistedToken(token)) revert NotWhitelisted();
            isReward[token] = true;
            rewardTokens.push(token);
        }
        _notifyRewardAmount(token, amount);
    }
}
