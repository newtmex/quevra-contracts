// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBaseVoter} from "../interfaces/IBaseVoter.sol";
import {IReward} from "../interfaces/IReward.sol";
import {VotingReward} from "./VotingReward.sol";

/// @title BribeVotingRewards
/// @notice Whitelisted token rewards paid to veMON voters for a target.
/// @dev Anyone may fund a bribe. The voter() remains the only account that can
///      change the voting balances through {VotingReward}.
contract BribeVotingRewards is VotingReward {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address voter_, address[] memory rewardTokens_) external initializer {
        __VotingReward_init(voter_, rewardTokens_);
    }

    /// @inheritdoc IReward
    /// @dev Anyone may fund a whitelisted reward token for the current cycle.
    function notifyRewardAmount(address token, uint256 amount) external override nonReentrant {
        if (!_rewardStorage().isReward[token]) {
            if (!IBaseVoter(voter()).isWhitelistedToken(token)) revert NotWhitelisted();
            _rewardStorage().isReward[token] = true;
            _rewardStorage().rewardTokens.push(token);
        }
        _notifyRewardAmount(token, amount);
    }
}
