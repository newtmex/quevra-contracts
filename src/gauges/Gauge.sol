// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IGauge} from "../interfaces/IGauge.sol";
import {IBaseVoter} from "../interfaces/IBaseVoter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";

/// @title Generic Protocol Gauge
/// @author veldorome.finance, @figs999, @pegahcarter
/// @notice Gauge contract for distribution of emissions by address
abstract contract Gauge is IGauge, ERC2771Context, ReentrancyGuard {
    using SafeERC20 for IERC20;
    /// @inheritdoc IGauge
    address public immutable rewardToken;
    /// @inheritdoc IGauge
    address public immutable voter;
    /// @inheritdoc IGauge
    address public immutable ve;

    uint256 internal constant PRECISION = 10 ** 18;

    /// @inheritdoc IGauge
    uint256 public periodFinish;
    /// @inheritdoc IGauge
    uint256 public rewardRate;
    /// @inheritdoc IGauge
    uint256 public lastUpdateTime;
    /// @inheritdoc IGauge
    uint256 public rewardPerTokenStored;
    /// @inheritdoc IGauge
    uint256 public totalSupply;
    /// @inheritdoc IGauge
    mapping(address => uint256) public balanceOf;
    /// @inheritdoc IGauge
    mapping(address => uint256) public userRewardPerTokenPaid;
    /// @inheritdoc IGauge
    mapping(address => uint256) public rewards;
    /// @inheritdoc IGauge
    mapping(uint256 => uint256) public rewardRateByEpoch;

    constructor(address _forwarder, address _rewardToken, address _voter) ERC2771Context(_forwarder) {
        rewardToken = _rewardToken;
        voter = _voter;
        ve = IBaseVoter(voter).ve();
    }

    /// @inheritdoc IGauge
    function rewardPerToken() public view returns (uint256) {
        if (totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * PRECISION)
                / totalSupply;
    }

    /// @inheritdoc IGauge
    function lastTimeRewardApplicable() public view returns (uint256) {
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpochView();
        return Math.min(uint256(epoch), periodFinish);
    }

    /// @inheritdoc IGauge
    function getReward(address _account) external nonReentrant {
        address sender = _msgSender();
        if (sender != _account && sender != voter) revert NotAuthorized();

        _updateRewards(_account);

        uint256 reward = rewards[_account];
        if (reward > 0) {
            rewards[_account] = 0;
            IERC20(rewardToken).safeTransfer(_account, reward);
            emit ClaimRewards(_account, reward);
        }
    }

    /// @inheritdoc IGauge
    function earned(address _account) public view returns (uint256) {
        return
            (balanceOf[_account] * (rewardPerToken() - userRewardPerTokenPaid[_account])) / PRECISION
                + rewards[_account];
    }

    function _updateRewards(address _account) internal {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        rewards[_account] = earned(_account);
        userRewardPerTokenPaid[_account] = rewardPerTokenStored;
    }

    /// @inheritdoc IGauge
    function left() external view returns (uint256) {
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpochView();
        if (epoch >= periodFinish) return 0;
        uint256 _remaining = periodFinish - epoch;
        return _remaining * rewardRate;
    }

    /// @inheritdoc IGauge
    function notifyRewardAmount(uint256 _amount) external nonReentrant {
        address sender = _msgSender();
        if (sender != voter) revert NotVoter();
        if (_amount == 0) revert ZeroAmount();
        _onNotifyRewardAmount();
        _notifyRewardAmount(sender, _amount);
    }

    /// @dev Hook that is called upon notifyRewardAmount.
    function _onNotifyRewardAmount() internal virtual {}

    function _notifyRewardAmount(address sender, uint256 _amount) internal {
        rewardPerTokenStored = rewardPerToken();
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        uint256 cycleEnd = ProtocolTimeLibrary.cycleNext(epoch);
        uint256 timeUntilNext = cycleEnd - epoch;

        if (epoch >= periodFinish) {
            IERC20(rewardToken).safeTransferFrom(sender, address(this), _amount);
            rewardRate = _amount / timeUntilNext;
        } else {
            uint256 _remaining = periodFinish - epoch;
            uint256 _leftover = _remaining * rewardRate;
            IERC20(rewardToken).safeTransferFrom(sender, address(this), _amount);
            rewardRate = (_amount + _leftover) / timeUntilNext;
        }
        rewardRateByEpoch[ProtocolTimeLibrary.cycleStart(epoch)] = rewardRate;
        if (rewardRate == 0) revert ZeroRewardRate();

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint256 balance = IERC20(rewardToken).balanceOf(address(this));
        if (rewardRate > balance / timeUntilNext) revert RewardRateTooHigh();

        lastUpdateTime = epoch;
        periodFinish = cycleEnd;
        emit NotifyReward(sender, _amount);
    }
}
