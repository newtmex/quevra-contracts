// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBaseVoter} from "../interfaces/IBaseVoter.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {Reward} from "./Reward.sol";

/// @title StakingRewards
/// @notice Cycle-scoped ERC20 rewards for veMON positions participating in staking.
/// @dev Customized from Tigris's FreeManagedReward. Reward tokens are added when
///      they are first notified, and the staking controller owns the balance
///      deposit/withdraw path.
contract StakingRewards is Reward {
    uint256 public immutable requestId;
    address public immutable operator;

    error InvalidStakingRewardsIdentity();

    constructor(address controller_, uint256 requestId_, address operator_) Reward(controller_) {
        if (controller_ == address(0) || requestId_ == 0 || operator_ == address(0)) {
            revert InvalidStakingRewardsIdentity();
        }
        requestId = requestId_;
        operator = operator_;
        authorized = controller_;
    }

    function getReward(uint256 tokenId, address[] memory tokens) external override nonReentrant {
        address sender = msg.sender;
        if (!IVotingEscrow(ve).isApprovedOrOwner(sender, tokenId)) revert NotAuthorized();

        _getReward(IVotingEscrow(ve).ownerOf(tokenId), tokenId, tokens);
    }

    function notifyRewardAmount(address token, uint256 amount) external override nonReentrant {
        if (!isReward[token]) {
            if (!IBaseVoter(voter).isWhitelistedToken(token)) revert NotWhitelisted();
            isReward[token] = true;
            rewardTokens.push(token);
        }

        _notifyRewardAmount(token, amount);
    }
}
