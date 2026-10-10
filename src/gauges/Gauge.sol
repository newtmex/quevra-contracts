// SPDX-License-Identifier: MIT
// Derived from Tigris Gauge.sol by veldorome.finance, @figs999, and @pegahcarter.
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBaseVoter} from "../interfaces/IBaseVoter.sol";
import {IGauge} from "../interfaces/IGauge.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";

/// @dev Adapted from Tigris's Gauge. Monad's CALL-only staking epoch precompile supplies the reward
///      clock; rates are recorded at the start of each Quevra cycle.
abstract contract Gauge is IGauge, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @dev Fixed-point scale used for per-token reward accounting.
    uint256 internal constant PRECISION = 1e18;

    /// @inheritdoc IGauge
    address public immutable override rewardToken;
    /// @inheritdoc IGauge
    address public immutable override voter;
    /// @inheritdoc IGauge
    address public immutable override ve;

    /// @inheritdoc IGauge
    uint256 public override periodFinish;
    /// @inheritdoc IGauge
    uint256 public override rewardRate;
    /// @inheritdoc IGauge
    uint256 public override lastUpdateTime;
    /// @inheritdoc IGauge
    uint256 public override rewardPerTokenStored;
    /// @inheritdoc IGauge
    uint256 public override totalSupply;
    /// @inheritdoc IGauge
    mapping(address account => uint256) public override balanceOf;
    /// @inheritdoc IGauge
    mapping(address account => uint256) public override userRewardPerTokenPaid;
    /// @inheritdoc IGauge
    mapping(address account => uint256) public override rewards;
    /// @inheritdoc IGauge
    mapping(uint256 epoch => uint256) public override rewardRateByEpoch;

    constructor(address rewardToken_, address voter_) {
        if (rewardToken_ == address(0) || voter_ == address(0)) revert NotAuthorized();
        rewardToken = rewardToken_;
        voter = voter_;
        ve = IBaseVoter(voter_).ve();
    }

    /// @inheritdoc IGauge
    function rewardPerToken() public override returns (uint256) {
        if (totalSupply == 0) return rewardPerTokenStored;
        return
            rewardPerTokenStored + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * PRECISION)
                / totalSupply;
    }

    /// @inheritdoc IGauge
    function lastTimeRewardApplicable() public override returns (uint256) {
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        return Math.min(uint256(epoch), periodFinish);
    }

    /// @inheritdoc IGauge
    function earned(address account) public override returns (uint256) {
        return
            (balanceOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / PRECISION + rewards[account];
    }

    /// @inheritdoc IGauge
    function getReward(address account) external override nonReentrant {
        if (msg.sender != account && msg.sender != voter) revert NotAuthorized();
        _updateRewards(account);
        uint256 reward = rewards[account];
        if (reward != 0) {
            rewards[account] = 0;
            IERC20(rewardToken).safeTransfer(account, reward);
            emit ClaimRewards(account, reward);
        }
    }

    /// @inheritdoc IGauge
    function left() external override returns (uint256) {
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        if (uint256(epoch) >= periodFinish) return 0;
        return (periodFinish - uint256(epoch)) * rewardRate;
    }

    /// @inheritdoc IGauge
    function notifyRewardAmount(uint256 amount) external override nonReentrant {
        if (msg.sender != voter) revert NotVoter();
        if (amount == 0) revert ZeroAmount();
        _onNotifyRewardAmount();
        _notifyRewardAmount(msg.sender, amount);
    }

    /// @dev Extension hook for gauge-specific checks before new emissions are recorded.
    function _onNotifyRewardAmount() internal virtual {}

    /// @dev Updates the epoch-based emission rate and records it at the current cycle start.
    function _notifyRewardAmount(address sender, uint256 amount) internal {
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        uint256 currentEpoch = epoch;
        rewardPerTokenStored = rewardPerToken();
        uint256 finish = uint256(ProtocolTimeLibrary.cycleNext(epoch));
        uint256 duration = finish - currentEpoch;
        IERC20(rewardToken).safeTransferFrom(sender, address(this), amount);

        uint256 leftover = 0;
        if (currentEpoch < periodFinish) leftover = (periodFinish - currentEpoch) * rewardRate;
        rewardRate = (amount + leftover) / duration;
        if (rewardRate == 0) revert ZeroRewardRate();
        if (rewardRate > IERC20(rewardToken).balanceOf(address(this)) / duration) revert RewardRateTooHigh();

        rewardRateByEpoch[uint256(ProtocolTimeLibrary.cycleStart(epoch))] = rewardRate;
        lastUpdateTime = currentEpoch;
        periodFinish = finish;
        emit NotifyReward(sender, amount);
    }

    /// @dev Settles an account against the latest cumulative reward-per-token value.
    function _updateRewards(address account) internal {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        rewards[account] = earned(account);
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
    }
}
