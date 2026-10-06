// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {Reward} from "./Reward.sol";

/// @title VotingReward
/// @notice Base reward contract for balances attributed by veMON votes.
/// @dev The voter owns the deposit and withdrawal path. Rewards are measured
///      against the voting balance checkpoint for each cycle.
abstract contract VotingReward is Reward {
    constructor(address voter_, address[] memory rewardTokens_) Reward(voter_) {
        if (voter_ == address(0)) revert InvalidReward();
        for (uint256 i; i < rewardTokens_.length; ++i) {
            address token = rewardTokens_[i];
            if (token == address(0) || isReward[token]) continue;
            isReward[token] = true;
            rewardTokens.push(token);
        }
        authorized = voter_;
    }

    function getReward(uint256 tokenId, address[] memory tokens) external override nonReentrant {
        if (!IVotingEscrow(ve).isApprovedOrOwner(msg.sender, tokenId) && msg.sender != voter) {
            revert NotAuthorized();
        }
        _getReward(IVotingEscrow(ve).ownerOf(tokenId), tokenId, tokens);
    }

    function notifyRewardAmount(address, uint256) external virtual override {}
}
