// SPDX-License-Identifier: MIT
// Adapted from Tigris Reward.sol by velodrome.finance, @figs999, and @pegahcarter.
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBaseVoter} from "../interfaces/IBaseVoter.sol";
import {IReward} from "../interfaces/IReward.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";

/// @title Reward
/// @author Adapted from Tigris by velodrome.finance, @figs999, and @pegahcarter
/// @notice Base cycle-scoped reward accounting for veMON positions.
/// @dev Quevra replaces Tigris timestamp periods with Monad staking epochs and cycle checkpoints.
abstract contract Reward is IReward, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 internal constant CYCLE_EPOCHS = ProtocolTimeLibrary.EPOCHS_PER_CYCLE;

    /// @inheritdoc IReward
    address public immutable override voter;
    /// @inheritdoc IReward
    address public immutable override ve;
    /// @inheritdoc IReward
    address public override authorized;

    /// @inheritdoc IReward
    uint256 public override totalSupply;
    /// @inheritdoc IReward
    mapping(uint256 tokenId => uint256 amount) public override balanceOf;
    /// @inheritdoc IReward
    mapping(address token => mapping(uint256 cycle => uint256 amount)) public override tokenRewardsPerCycle;
    /// @inheritdoc IReward
    mapping(address token => mapping(uint256 tokenId => uint256 epoch)) public override lastEarnEpoch;

    address[] public rewardTokens;
    /// @inheritdoc IReward
    mapping(address token => bool registered) public override isReward;

    mapping(uint256 tokenId => mapping(uint256 index => Checkpoint)) public checkpoints;
    /// @inheritdoc IReward
    mapping(uint256 tokenId => uint256 count) public override numCheckpoints;
    mapping(uint256 index => SupplyCheckpoint) public supplyCheckpoints;
    /// @inheritdoc IReward
    uint256 public override supplyNumCheckpoints;

    constructor(address voter_) {
        if (voter_ == address(0)) revert InvalidReward();
        voter = voter_;
        ve = IBaseVoter(voter_).ve();
    }

    /// @inheritdoc IReward
    function getPriorBalanceIndex(uint256 tokenId, uint256 cycle) public view override returns (uint256) {
        uint256 count = numCheckpoints[tokenId];
        if (count == 0) return 0;
        if (checkpoints[tokenId][count - 1].cycle <= cycle) return count - 1;
        if (checkpoints[tokenId][0].cycle > cycle) return 0;

        uint256 lower = 0;
        uint256 upper = count - 1;
        while (upper > lower) {
            uint256 center = upper - (upper - lower) / 2;
            Checkpoint memory checkpoint = checkpoints[tokenId][center];
            if (checkpoint.cycle == cycle) return center;
            if (checkpoint.cycle < cycle) lower = center;
            else upper = center - 1;
        }
        return lower;
    }

    /// @inheritdoc IReward
    function getPriorSupplyIndex(uint256 cycle) public view override returns (uint256) {
        uint256 count = supplyNumCheckpoints;
        if (count == 0) return 0;
        if (supplyCheckpoints[count - 1].cycle <= cycle) return count - 1;
        if (supplyCheckpoints[0].cycle > cycle) return 0;

        uint256 lower = 0;
        uint256 upper = count - 1;
        while (upper > lower) {
            uint256 center = upper - (upper - lower) / 2;
            SupplyCheckpoint memory checkpoint = supplyCheckpoints[center];
            if (checkpoint.cycle == cycle) return center;
            if (checkpoint.cycle < cycle) lower = center;
            else upper = center - 1;
        }
        return lower;
    }

    function _writeCheckpoint(uint256 tokenId, uint256 balance) internal {
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        uint64 cycle = ProtocolTimeLibrary.cycleStart(epoch);
        uint256 count = numCheckpoints[tokenId];
        if (count > 0 && checkpoints[tokenId][count - 1].cycle == cycle) {
            checkpoints[tokenId][count - 1] = Checkpoint(cycle, balance);
        } else {
            checkpoints[tokenId][count] = Checkpoint(cycle, balance);
            numCheckpoints[tokenId] = count + 1;
        }
    }

    function _writeSupplyCheckpoint() internal {
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        uint64 cycle = ProtocolTimeLibrary.cycleStart(epoch);
        uint256 count = supplyNumCheckpoints;
        if (count > 0 && supplyCheckpoints[count - 1].cycle == cycle) {
            supplyCheckpoints[count - 1] = SupplyCheckpoint(cycle, totalSupply);
        } else {
            supplyCheckpoints[count] = SupplyCheckpoint(cycle, totalSupply);
            supplyNumCheckpoints = count + 1;
        }
    }

    /// @inheritdoc IReward
    function rewardsListLength() external view override returns (uint256) {
        return rewardTokens.length;
    }

    /// @inheritdoc IReward
    function duration() external pure override returns (uint256) {
        return CYCLE_EPOCHS;
    }

    /// @inheritdoc IReward
    function earned(address token, uint256 tokenId) public override returns (uint256) {
        if (numCheckpoints[tokenId] == 0) return 0;

        (uint64 currentEpoch,) = ProtocolTimeLibrary.currentEpoch();
        uint256 currentCycle = ProtocolTimeLibrary.cycleStart(currentEpoch);
        uint256 cursor = ProtocolTimeLibrary.cycleStart(uint64(lastEarnEpoch[token][tokenId]));
        uint256 index = getPriorBalanceIndex(tokenId, cursor);
        Checkpoint memory checkpoint = checkpoints[tokenId][index];
        cursor = Math.max(cursor, checkpoint.cycle);

        uint256 reward = 0;
        uint256 supply = 1;
        uint256 cycles = (currentCycle - cursor) / CYCLE_EPOCHS;
        for (uint256 i; i < cycles; ++i) {
            uint256 cycleEnd = cursor + CYCLE_EPOCHS - 1;
            index = getPriorBalanceIndex(tokenId, cycleEnd);
            checkpoint = checkpoints[tokenId][index];
            supply = Math.max(supplyCheckpoints[getPriorSupplyIndex(cycleEnd)].supply, 1);
            reward += (checkpoint.balanceOf * tokenRewardsPerCycle[token][cursor]) / supply;
            cursor += CYCLE_EPOCHS;
        }
        return reward;
    }

    /// @inheritdoc IReward
    function _deposit(uint256 amount, uint256 tokenId) external override {
        if (msg.sender != authorized) revert NotAuthorized();
        totalSupply += amount;
        balanceOf[tokenId] += amount;
        _writeCheckpoint(tokenId, balanceOf[tokenId]);
        _writeSupplyCheckpoint();
        emit Deposit(msg.sender, tokenId, amount);
    }

    /// @inheritdoc IReward
    function _withdraw(uint256 amount, uint256 tokenId) external override {
        if (msg.sender != authorized) revert NotAuthorized();
        totalSupply -= amount;
        balanceOf[tokenId] -= amount;
        _writeCheckpoint(tokenId, balanceOf[tokenId]);
        _writeSupplyCheckpoint();
        emit Withdraw(msg.sender, tokenId, amount);
    }

    /// @inheritdoc IReward
    function getReward(uint256, address[] memory) external virtual override nonReentrant {}

    function _getReward(address recipient, uint256 tokenId, address[] memory tokens) internal {
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        for (uint256 i; i < tokens.length; ++i) {
            uint256 amount = earned(tokens[i], tokenId);
            lastEarnEpoch[tokens[i]][tokenId] = epoch;
            if (amount > 0) IERC20(tokens[i]).safeTransfer(recipient, amount);
            emit ClaimRewards(recipient, tokens[i], amount);
        }
    }

    /// @inheritdoc IReward
    function notifyRewardAmount(address, uint256) external virtual override nonReentrant {}

    function _notifyRewardAmount(address token, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        uint64 cycle = ProtocolTimeLibrary.cycleStart(epoch);
        tokenRewardsPerCycle[token][cycle] += amount;
        emit NotifyReward(msg.sender, token, cycle, amount);
    }
}
