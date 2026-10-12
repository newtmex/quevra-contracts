// SPDX-License-Identifier: MIT
// Adapted from Tigris Reward.sol by velodrome.finance, @figs999, and @pegahcarter.
// Upstream: tigris/solidity/contracts/rewards/Reward.sol @ fa9ba83d93d4ee362b0699e7bcd13d32e150afda
// Provenance: docs/provenance.md
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBaseVoter} from "../interfaces/IBaseVoter.sol";
import {IReward} from "../interfaces/IReward.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @title Reward
/// @author Adapted from Tigris by velodrome.finance, @figs999, and @pegahcarter
/// @notice Base cycle-scoped reward accounting for veMON positions.
/// @dev Quevra replaces Tigris timestamp periods with Monad staking epochs and cycle checkpoints.
abstract contract Reward is Initializable, IReward, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 internal constant CYCLE_EPOCHS = ProtocolTimeLibrary.EPOCHS_PER_CYCLE;

    /// @custom:storage-location erc7201:quevra.Reward
    struct RewardStorage {
        address voter;
        address ve;
        address authorized;
        uint256 totalSupply;
        mapping(uint256 tokenId => uint256 amount) balanceOf;
        mapping(address token => mapping(uint256 cycle => uint256 amount)) tokenRewardsPerCycle;
        mapping(address token => mapping(uint256 tokenId => uint256 epoch)) lastEarnEpoch;
        address[] rewardTokens;
        mapping(address token => bool registered) isReward;
        mapping(uint256 tokenId => mapping(uint256 index => Checkpoint)) checkpoints;
        mapping(uint256 tokenId => uint256 count) numCheckpoints;
        mapping(uint256 index => SupplyCheckpoint) supplyCheckpoints;
        uint256 supplyNumCheckpoints;
    }

    bytes32 private constant REWARD_STORAGE_SLOT = 0xcb18eaf18c53b1ae10814b10e1fb777dd167d90779198bb46b16c1b174398c00;

    function _rewardStorage() internal pure returns (RewardStorage storage $) {
        bytes32 slot = REWARD_STORAGE_SLOT;
        assembly ("memory-safe") { $.slot := slot }
    }

    /// @inheritdoc IReward
    function voter() public view override returns (address) {
        return _rewardStorage().voter;
    }

    /// @inheritdoc IReward
    function ve() public view override returns (address) {
        return _rewardStorage().ve;
    }

    /// @inheritdoc IReward
    function authorized() public view override returns (address) {
        return _rewardStorage().authorized;
    }

    /// @inheritdoc IReward
    function totalSupply() public view override returns (uint256) {
        return _rewardStorage().totalSupply;
    }

    /// @inheritdoc IReward
    function balanceOf(uint256 tokenId) public view override returns (uint256) {
        return _rewardStorage().balanceOf[tokenId];
    }

    /// @inheritdoc IReward
    function tokenRewardsPerCycle(address token, uint256 cycle) public view override returns (uint256) {
        return _rewardStorage().tokenRewardsPerCycle[token][cycle];
    }

    /// @inheritdoc IReward
    function lastEarnEpoch(address token, uint256 tokenId) public view override returns (uint256) {
        return _rewardStorage().lastEarnEpoch[token][tokenId];
    }

    function rewardTokens(uint256 index) public view returns (address) {
        return _rewardStorage().rewardTokens[index];
    }

    /// @inheritdoc IReward
    function isReward(address token) public view override returns (bool) {
        return _rewardStorage().isReward[token];
    }

    function checkpoints(uint256 tokenId, uint256 index) public view returns (uint256 cycle, uint256 balanceOf) {
        Checkpoint storage point = _rewardStorage().checkpoints[tokenId][index];
        return (point.cycle, point.balanceOf);
    }

    /// @inheritdoc IReward
    function numCheckpoints(uint256 tokenId) public view override returns (uint256) {
        return _rewardStorage().numCheckpoints[tokenId];
    }

    function supplyCheckpoints(uint256 index) public view returns (uint256 cycle, uint256 supply) {
        SupplyCheckpoint storage point = _rewardStorage().supplyCheckpoints[index];
        return (point.cycle, point.supply);
    }

    /// @inheritdoc IReward
    function supplyNumCheckpoints() public view override returns (uint256) {
        return _rewardStorage().supplyNumCheckpoints;
    }

    function __Reward_init(address voter_) internal onlyInitializing {
        if (voter_ == address(0) || voter_.code.length == 0) revert InvalidReward();
        address votingEscrow = IBaseVoter(voter_).ve();
        if (votingEscrow == address(0)) revert InvalidReward();
        _rewardStorage().voter = voter_;
        _rewardStorage().ve = votingEscrow;
    }

    /// @inheritdoc IReward
    function getPriorBalanceIndex(uint256 tokenId, uint256 cycle) public view override returns (uint256) {
        uint256 count = _rewardStorage().numCheckpoints[tokenId];
        if (count == 0) return 0;
        if (_rewardStorage().checkpoints[tokenId][count - 1].cycle <= cycle) return count - 1;
        if (_rewardStorage().checkpoints[tokenId][0].cycle > cycle) return 0;

        uint256 lower = 0;
        uint256 upper = count - 1;
        while (upper > lower) {
            uint256 center = upper - (upper - lower) / 2;
            Checkpoint memory checkpoint = _rewardStorage().checkpoints[tokenId][center];
            if (checkpoint.cycle == cycle) return center;
            if (checkpoint.cycle < cycle) lower = center;
            else upper = center - 1;
        }
        return lower;
    }

    /// @inheritdoc IReward
    function getPriorSupplyIndex(uint256 cycle) public view override returns (uint256) {
        uint256 count = _rewardStorage().supplyNumCheckpoints;
        if (count == 0) return 0;
        if (_rewardStorage().supplyCheckpoints[count - 1].cycle <= cycle) return count - 1;
        if (_rewardStorage().supplyCheckpoints[0].cycle > cycle) return 0;

        uint256 lower = 0;
        uint256 upper = count - 1;
        while (upper > lower) {
            uint256 center = upper - (upper - lower) / 2;
            SupplyCheckpoint memory checkpoint = _rewardStorage().supplyCheckpoints[center];
            if (checkpoint.cycle == cycle) return center;
            if (checkpoint.cycle < cycle) lower = center;
            else upper = center - 1;
        }
        return lower;
    }

    function _writeCheckpoint(uint256 tokenId, uint256 balance) internal {
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        uint64 cycle = ProtocolTimeLibrary.cycleStart(epoch);
        uint256 count = _rewardStorage().numCheckpoints[tokenId];
        if (count > 0 && _rewardStorage().checkpoints[tokenId][count - 1].cycle == cycle) {
            _rewardStorage().checkpoints[tokenId][count - 1] = Checkpoint(cycle, balance);
        } else {
            _rewardStorage().checkpoints[tokenId][count] = Checkpoint(cycle, balance);
            _rewardStorage().numCheckpoints[tokenId] = count + 1;
        }
    }

    function _writeSupplyCheckpoint() internal {
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        uint64 cycle = ProtocolTimeLibrary.cycleStart(epoch);
        uint256 count = _rewardStorage().supplyNumCheckpoints;
        if (count > 0 && _rewardStorage().supplyCheckpoints[count - 1].cycle == cycle) {
            _rewardStorage().supplyCheckpoints[count - 1] = SupplyCheckpoint(cycle, _rewardStorage().totalSupply);
        } else {
            _rewardStorage().supplyCheckpoints[count] = SupplyCheckpoint(cycle, _rewardStorage().totalSupply);
            _rewardStorage().supplyNumCheckpoints = count + 1;
        }
    }

    /// @inheritdoc IReward
    function rewardsListLength() external view override returns (uint256) {
        return _rewardStorage().rewardTokens.length;
    }

    /// @inheritdoc IReward
    function duration() external pure override returns (uint256) {
        return CYCLE_EPOCHS;
    }

    /// @inheritdoc IReward
    function earned(address token, uint256 tokenId) public override returns (uint256) {
        if (_rewardStorage().numCheckpoints[tokenId] == 0) return 0;

        (uint64 currentEpoch,) = ProtocolTimeLibrary.currentEpoch();
        uint256 currentCycle = ProtocolTimeLibrary.cycleStart(currentEpoch);
        uint256 cursor = ProtocolTimeLibrary.cycleStart(uint64(_rewardStorage().lastEarnEpoch[token][tokenId]));
        uint256 index = getPriorBalanceIndex(tokenId, cursor);
        Checkpoint memory checkpoint = _rewardStorage().checkpoints[tokenId][index];
        cursor = Math.max(cursor, checkpoint.cycle);

        uint256 reward = 0;
        uint256 supply = 1;
        uint256 cycles = (currentCycle - cursor) / CYCLE_EPOCHS;
        for (uint256 i; i < cycles; ++i) {
            uint256 cycleEnd = cursor + CYCLE_EPOCHS - 1;
            index = getPriorBalanceIndex(tokenId, cycleEnd);
            checkpoint = _rewardStorage().checkpoints[tokenId][index];
            supply = Math.max(_rewardStorage().supplyCheckpoints[getPriorSupplyIndex(cycleEnd)].supply, 1);
            reward += (checkpoint.balanceOf * _rewardStorage().tokenRewardsPerCycle[token][cursor]) / supply;
            cursor += CYCLE_EPOCHS;
        }
        return reward;
    }

    /// @inheritdoc IReward
    function _deposit(uint256 amount, uint256 tokenId) external override {
        if (msg.sender != authorized()) revert NotAuthorized();
        _rewardStorage().totalSupply += amount;
        _rewardStorage().balanceOf[tokenId] += amount;
        _writeCheckpoint(tokenId, _rewardStorage().balanceOf[tokenId]);
        _writeSupplyCheckpoint();
        emit Deposit(msg.sender, tokenId, amount);
    }

    /// @inheritdoc IReward
    function _withdraw(uint256 amount, uint256 tokenId) external override {
        if (msg.sender != authorized()) revert NotAuthorized();
        _rewardStorage().totalSupply -= amount;
        _rewardStorage().balanceOf[tokenId] -= amount;
        _writeCheckpoint(tokenId, _rewardStorage().balanceOf[tokenId]);
        _writeSupplyCheckpoint();
        emit Withdraw(msg.sender, tokenId, amount);
    }

    /// @inheritdoc IReward
    function getReward(uint256, address[] memory) external virtual override nonReentrant {}

    function _getReward(address recipient, uint256 tokenId, address[] memory tokens) internal {
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        for (uint256 i; i < tokens.length; ++i) {
            uint256 amount = earned(tokens[i], tokenId);
            _rewardStorage().lastEarnEpoch[tokens[i]][tokenId] = epoch;
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
        _rewardStorage().tokenRewardsPerCycle[token][cycle] += amount;
        emit NotifyReward(msg.sender, token, cycle, amount);
    }
}
