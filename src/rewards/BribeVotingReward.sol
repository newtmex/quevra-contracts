// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IVoter} from "../interfaces/IVoter.sol";
import {Reward} from "./Reward.sol";
import {VotingReward} from "./VotingReward.sol";

/// @notice Holds incentives for distribution to a pool's voters.
contract BribeVotingReward is VotingReward {
    constructor(address _forwarder, address _voter, address[] memory _rewards)
        VotingReward(_forwarder, _voter, _rewards)
    {}

    /// @inheritdoc Reward
    function notifyRewardAmount(address token, uint256 amount) external override nonReentrant {
        address sender = _msgSender();

        if (!isReward[token]) {
            if (!IVoter(voter).isWhitelistedToken(token)) {
                revert NotWhitelisted();
            }
            isReward[token] = true;
            rewards.push(token);
        }

        _notifyRewardAmount(sender, token, amount);
    }
}
