// SPDX-License-Identifier: BUSL-1.1
// Adapted from Tigris NonStakingVoter.sol (BUSL-1.1).
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBaseVoter} from "../interfaces/IBaseVoter.sol";
import {INonStakingVoter} from "../interfaces/INonStakingVoter.sol";
import {IGauge} from "../interfaces/IGauge.sol";
import {IReward} from "../interfaces/IReward.sol";

/// @dev Tigris-derived abstract layer for token whitelisting and reward funding. Concrete voters
///      provide gauge creation and vote-weight transitions.
abstract contract NonStakingVoter is Ownable2Step, ReentrancyGuardTransient, INonStakingVoter {
    using SafeERC20 for IERC20;

    /// @inheritdoc IBaseVoter
    address public immutable override ve;
    /// @inheritdoc IBaseVoter
    mapping(address token => bool) public override isWhitelistedToken;

    /// @inheritdoc INonStakingVoter
    mapping(address gauge => bool) public override isGauge;
    /// @inheritdoc INonStakingVoter
    mapping(address gauge => address bribeVotingRewards) public override gaugeToBribe;
    /// @inheritdoc INonStakingVoter
    mapping(address gauge => uint256 amount) public override weights;
    /// @inheritdoc INonStakingVoter
    mapping(uint256 tokenId => mapping(address gauge => uint256 amount)) public override votes;
    /// @inheritdoc INonStakingVoter
    mapping(uint256 tokenId => uint256 amount) public override usedWeights;
    /// @inheritdoc INonStakingVoter
    mapping(uint256 tokenId => address[]) public gaugeVote;

    constructor(address votingVe_, address owner_) Ownable(owner_) {
        if (votingVe_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        ve = votingVe_;
    }

    // External state-changing API

    /// @inheritdoc INonStakingVoter
    function whitelistToken(address token, bool whitelisted) external virtual override onlyOwner {
        if (token == address(0) || token.code.length == 0) revert ZeroAddress();
        isWhitelistedToken[token] = whitelisted;
        emit WhitelistToken(msg.sender, token, whitelisted);
    }

    /// @inheritdoc INonStakingVoter
    function notifyGaugeReward(address gauge, uint256 amount) external virtual override nonReentrant {
        if (!isGauge[gauge]) revert GaugeDoesNotExist(gauge);
        address token = IGauge(gauge).rewardToken();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(token).forceApprove(gauge, amount);
        IGauge(gauge).notifyRewardAmount(amount);
    }

    /// @dev Notifies the gauge's bribe rewards contract of a vote weight.
    ///      Derived voters may override this to customize gauge weight handling.
    function _notifyGaugeWeight(address gauge, uint256 amount, uint256 tokenId) internal virtual {
        IReward(gaugeToBribe[gauge])._deposit(amount, tokenId);
    }

    /// @dev Withdraws a previously deposited gauge weight.
    function _withdrawGaugeWeight(address gauge, uint256 amount, uint256 tokenId) internal virtual {
        IReward(gaugeToBribe[gauge])._withdraw(amount, tokenId);
    }

    function _registerGauge(address gauge, address bribeVotingRewards) internal virtual {
        if (gauge == address(0) || bribeVotingRewards == address(0)) revert ZeroAddress();
        if (isGauge[gauge]) revert GaugeExists();
        isGauge[gauge] = true;
        gaugeToBribe[gauge] = bribeVotingRewards;
    }

    function _unregisterGauge(address gauge) internal virtual {
        delete isGauge[gauge];
        delete gaugeToBribe[gauge];
    }
}
