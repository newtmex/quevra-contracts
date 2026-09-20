// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IReward} from "../interfaces/IReward.sol";
import {IBaseVoter} from "../interfaces/IBaseVoter.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";

/// @title Reward
/// @author velodrome.finance, @figs999, @pegahcarter
/// @notice Base reward contract for distribution of rewards
abstract contract Reward is IReward, ERC2771Context, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint64 constant DURATION = ProtocolTimeLibrary.EPOCHS_PER_CYCLE;

    /// @inheritdoc IReward
    address public immutable voter;
    /// @inheritdoc IReward
    address public immutable ve;
    /// @inheritdoc IReward
    address public authorized;

    /// @inheritdoc IReward
    uint256 public totalSupply;
    /// @inheritdoc IReward
    mapping(uint256 => uint256) public balanceOf;
    /// @inheritdoc IReward
    mapping(address => mapping(uint256 => uint256)) public tokenRewardsPerCycle;
    /// @inheritdoc IReward
    mapping(address => mapping(uint256 => uint64)) public lastEarn;

    address[] public rewards;
    /// @inheritdoc IReward
    mapping(address => bool) public isReward;

    /// @notice A record of balance checkpoints for each account, by index
    mapping(uint256 => mapping(uint256 => Checkpoint)) public checkpoints;
    /// @inheritdoc IReward
    mapping(uint256 => uint256) public numCheckpoints;
    /// @notice A record of balance checkpoints for each token, by index
    mapping(uint256 => SupplyCheckpoint) public supplyCheckpoints;
    /// @inheritdoc IReward
    uint256 public supplyNumCheckpoints;

    constructor(address _forwarder, address _voter) ERC2771Context(_forwarder) {
        voter = _voter;
        ve = IBaseVoter(_voter).ve();
    }

    /// @inheritdoc IReward
    function getPriorBalanceIndex(uint256 tokenId, uint64 epoch) public view returns (uint256) {
        uint256 nCheckpoints = numCheckpoints[tokenId];
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (checkpoints[tokenId][nCheckpoints - 1].epoch <= epoch) {
            return (nCheckpoints - 1);
        }

        // Next check implicit zero balance
        if (checkpoints[tokenId][0].epoch > epoch) {
            return 0;
        }

        uint256 lower = 0;
        uint256 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint256 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            Checkpoint memory cp = checkpoints[tokenId][center];
            if (cp.epoch == epoch) {
                return center;
            } else if (cp.epoch < epoch) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

    /// @inheritdoc IReward
    function getPriorSupplyIndex(uint64 epoch) public view returns (uint256) {
        uint256 nCheckpoints = supplyNumCheckpoints;
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (supplyCheckpoints[nCheckpoints - 1].epoch <= epoch) {
            return (nCheckpoints - 1);
        }

        // Next check implicit zero balance
        if (supplyCheckpoints[0].epoch > epoch) {
            return 0;
        }

        uint256 lower = 0;
        uint256 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint256 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            SupplyCheckpoint memory cp = supplyCheckpoints[center];
            if (cp.epoch == epoch) {
                return center;
            } else if (cp.epoch < epoch) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

    function _writeCheckpoint(uint256 tokenId, uint256 balance) internal {
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        uint256 nCheckpoints = numCheckpoints[tokenId];
        uint64 currentCycleStart = ProtocolTimeLibrary.cycleStart(epoch);
        // Tigris stores one balance checkpoint per reward epoch. Quevra's
        // corresponding economic boundary is a cycle, while checkpoint values
        // remain indexed by the Monad epoch at which the change was made.
        if (
            nCheckpoints > 0
                && ProtocolTimeLibrary.cycleStart(checkpoints[tokenId][nCheckpoints - 1].epoch) == currentCycleStart
        ) {
            checkpoints[tokenId][nCheckpoints - 1] = Checkpoint(epoch, balance);
        } else {
            checkpoints[tokenId][nCheckpoints] = Checkpoint(epoch, balance);
            numCheckpoints[tokenId] = nCheckpoints + 1;
        }
    }

    function _writeSupplyCheckpoint() internal {
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        uint256 nCheckpoints = supplyNumCheckpoints;
        uint64 currentCycleStart = ProtocolTimeLibrary.cycleStart(epoch);
        if (
            nCheckpoints > 0
                && ProtocolTimeLibrary.cycleStart(supplyCheckpoints[nCheckpoints - 1].epoch) == currentCycleStart
        ) {
            supplyCheckpoints[nCheckpoints - 1] = SupplyCheckpoint(epoch, totalSupply);
        } else {
            supplyCheckpoints[nCheckpoints] = SupplyCheckpoint(epoch, totalSupply);
            supplyNumCheckpoints = nCheckpoints + 1;
        }
    }

    /// @inheritdoc IReward
    function rewardsListLength() external view returns (uint256) {
        return rewards.length;
    }

    /// @inheritdoc IReward
    function duration() external pure returns (uint64) {
        return DURATION;
    }

    /// @inheritdoc IReward
    function earned(address token, uint256 tokenId) public returns (uint256) {
        if (numCheckpoints[tokenId] == 0) {
            return 0;
        }

        uint256 reward = 0;
        uint256 _supply = 1;
        uint64 _currCycle = ProtocolTimeLibrary.cycleStart(lastEarn[token][tokenId]); // take epoch last claimed in as starting point
        uint256 _index = getPriorBalanceIndex(tokenId, _currCycle);
        Checkpoint memory cp0 = checkpoints[tokenId][_index];

        // accounts for case where lastEarn is before first checkpoint
        _currCycle = uint64(Math.max(uint256(_currCycle), uint256(ProtocolTimeLibrary.cycleStart(cp0.epoch))));

        // get epochs between current epoch and first checkpoint in same epoch as last claim
        uint256 numEpochs = (ProtocolTimeLibrary.currentCycleStart() - _currCycle) / DURATION;

        if (numEpochs > 0) {
            for (uint256 i = 0; i < numEpochs; i++) {
                // get index of last checkpoint in this epoch
                _index = getPriorBalanceIndex(tokenId, _currCycle + DURATION - 1);
                // get checkpoint in this epoch
                cp0 = checkpoints[tokenId][_index];
                // get supply of last checkpoint in this epoch
                _supply = Math.max(supplyCheckpoints[getPriorSupplyIndex(_currCycle + DURATION - 1)].supply, 1);
                reward += (cp0.balanceOf * tokenRewardsPerCycle[token][_currCycle]) / _supply;
                _currCycle += DURATION;
            }
        }

        return reward;
    }

    /// @inheritdoc IReward
    function _deposit(uint256 amount, uint256 tokenId) external {
        address sender = _msgSender();
        if (sender != authorized) revert NotAuthorized();

        totalSupply += amount;
        balanceOf[tokenId] += amount;

        _writeCheckpoint(tokenId, balanceOf[tokenId]);
        _writeSupplyCheckpoint();

        emit Deposit(sender, tokenId, amount);
    }

    /// @inheritdoc IReward
    function _withdraw(uint256 amount, uint256 tokenId) external {
        address sender = _msgSender();
        if (sender != authorized) revert NotAuthorized();

        totalSupply -= amount;
        balanceOf[tokenId] -= amount;

        _writeCheckpoint(tokenId, balanceOf[tokenId]);
        _writeSupplyCheckpoint();

        emit Withdraw(sender, tokenId, amount);
    }

    /// @inheritdoc IReward
    function getReward(uint256 tokenId, address[] memory tokens) external virtual nonReentrant {}

    /// @dev used with all getReward implementations
    function _getReward(address recipient, uint256 tokenId, address[] memory tokens) internal {
        uint256 _length = tokens.length;
        (uint64 currentEpoch,) = ProtocolTimeLibrary.currentEpoch();
        for (uint256 i = 0; i < _length; i++) {
            uint256 _reward = earned(tokens[i], tokenId);
            lastEarn[tokens[i]][tokenId] = currentEpoch;
            if (_reward > 0) IERC20(tokens[i]).safeTransfer(recipient, _reward);

            emit ClaimRewards(recipient, tokens[i], _reward);
        }
    }

    /// @inheritdoc IReward
    function notifyRewardAmount(address token, uint256 amount) external virtual nonReentrant {}

    /// @dev used within all notifyRewardAmount implementations
    function _notifyRewardAmount(address sender, address token, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransferFrom(sender, address(this), amount);

        uint256 cycle = ProtocolTimeLibrary.currentCycleStart();
        tokenRewardsPerCycle[token][cycle] += amount;

        emit NotifyReward(sender, token, cycle, amount);
    }
}
