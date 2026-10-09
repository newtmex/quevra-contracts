// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {INonStakingVoter} from "../interfaces/INonStakingVoter.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {IGauge} from "../interfaces/IGauge.sol";
import {IReward} from "../interfaces/IReward.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";

/// @title NonStakingVoter
/// @notice Shared voting, gauge reward, and reward token administration for non-staking voters.
/// @dev Derived voters provide gauge creation and domain-specific lifecycle behavior.
abstract contract NonStakingVoter is Ownable2Step, ReentrancyGuardTransient, INonStakingVoter {
    using SafeERC20 for IERC20;

    address public immutable override ve;
    mapping(address token => bool) public override isWhitelistedToken;

    mapping(address gauge => bool) public override isGauge;
    mapping(address gauge => address bribeVotingRewards) public override gaugeToBribe;
    mapping(address gauge => uint256 amount) public override weights;
    mapping(uint256 tokenId => mapping(address gauge => uint256 amount)) public override votes;
    mapping(uint256 tokenId => uint256 amount) public override usedWeights;
    mapping(uint256 tokenId => uint256 cycle) public override lastVoted;
    mapping(uint256 tokenId => address[]) public gaugeVote;

    constructor(address votingVe_, address owner_) Ownable(owner_) {
        if (votingVe_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        ve = votingVe_;
    }

    // External state-changing API

    function whitelistToken(address token, bool whitelisted) external virtual override onlyOwner {
        if (token == address(0) || token.code.length == 0) revert ZeroAddress();
        isWhitelistedToken[token] = whitelisted;
        emit WhitelistToken(msg.sender, token, whitelisted);
    }

    function notifyGaugeReward(address gauge, uint256 amount) external virtual override nonReentrant {
        if (!isGauge[gauge]) revert GaugeDoesNotExist(gauge);
        address token = IGauge(gauge).rewardToken();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(token).forceApprove(gauge, amount);
        IGauge(gauge).notifyRewardAmount(amount);
    }

    function vote(uint256 tokenId, address[] calldata targets, uint256[] calldata weights_)
        external
        virtual
        override
        nonReentrant
    {
        if (!IVotingEscrow(ve).isApprovedOrOwner(msg.sender, tokenId)) revert NotApprovedOrOwner();
        if (targets.length == 0) revert ZeroBalance();
        if (targets.length != weights_.length) revert UnequalLengths();
        uint64 cycle = ProtocolTimeLibrary.currentCycle();
        if (lastVoted[tokenId] == cycle) revert AlreadyVotedOrDeposited();
        _vote(tokenId, targets, weights_, cycle);
    }

    function reset(uint256 tokenId) external virtual override nonReentrant {
        if (!IVotingEscrow(ve).isApprovedOrOwner(msg.sender, tokenId)) revert NotApprovedOrOwner();
        _reset(tokenId);
    }

    // Internal vote and reset state transitions

    function _vote(uint256 tokenId, address[] calldata targets, uint256[] calldata weights_, uint64 cycle) internal {
        _reset(tokenId);
        uint256 total = 0;
        for (uint256 i; i < targets.length; ++i) {
            if (weights_[i] == 0) revert ZeroBalance();
            if (!isGauge[targets[i]]) revert GaugeDoesNotExist(targets[i]);
            total += weights_[i];
        }
        uint256 votingPower = IVotingEscrow(ve).votingPowerOf(tokenId);
        for (uint256 i; i < targets.length; ++i) {
            uint256 amount = votingPower * weights_[i] / total;
            if (amount == 0) revert ZeroBalance();
            votes[tokenId][targets[i]] = amount;
            weights[targets[i]] += amount;
            usedWeights[tokenId] += amount;
            gaugeVote[tokenId].push(targets[i]);
            emit Voted(msg.sender, targets[i], tokenId, amount);
        }
        lastVoted[tokenId] = cycle;
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

    function _reset(uint256 tokenId) internal virtual {
        address[] storage targets = gaugeVote[tokenId];
        for (uint256 i; i < targets.length; ++i) {
            address target = targets[i];
            uint256 amount = votes[tokenId][target];
            if (amount == 0) continue;
            weights[target] -= amount;
            delete votes[tokenId][target];
            emit Abstained(msg.sender, target, tokenId, amount);
        }
        delete gaugeVote[tokenId];
        usedWeights[tokenId] = 0;
    }
}
