// SPDX-License-Identifier: MIT
// Derived from Tigris Gauge.sol by veldorome.finance, @figs999, and @pegahcarter.
// Upstream: tigris/solidity/contracts/gauges/Gauge.sol @ fa9ba83d93d4ee362b0699e7bcd13d32e150afda
// Provenance: docs/provenance.md
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBaseVoter} from "../interfaces/IBaseVoter.sol";
import {IGauge} from "../interfaces/IGauge.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @dev Adapted from Tigris's Gauge. Monad's CALL-only staking epoch precompile supplies the reward
///      clock; rates are recorded at the start of each Quevra cycle.
abstract contract Gauge is Initializable, IGauge, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @dev Fixed-point scale used for per-token reward accounting.
    uint256 internal constant PRECISION = 1e18;

    /// @custom:storage-location erc7201:quevra.Gauge
    struct GaugeStorage {
        address rewardToken;
        address voter;
        address ve;
        uint256 periodFinish;
        uint256 rewardRate;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
        uint256 totalSupply;
        mapping(address account => uint256) balanceOf;
        mapping(address account => uint256) userRewardPerTokenPaid;
        mapping(address account => uint256) rewards;
        mapping(uint256 epoch => uint256) rewardRateByEpoch;
    }

    bytes32 private constant GAUGE_STORAGE_SLOT = 0x106d951ad41dda88d8c87ec08ef3bf8f979ad5e8ef74dd6433a1826b819b0400;

    function _gaugeStorage() internal pure returns (GaugeStorage storage $) {
        bytes32 slot = GAUGE_STORAGE_SLOT;
        assembly ("memory-safe") { $.slot := slot }
    }

    function rewardToken() public view override returns (address) {
        return _gaugeStorage().rewardToken;
    }

    function voter() public view override returns (address) {
        return _gaugeStorage().voter;
    }

    function ve() public view override returns (address) {
        return _gaugeStorage().ve;
    }

    function periodFinish() public view override returns (uint256) {
        return _gaugeStorage().periodFinish;
    }

    function rewardRate() public view override returns (uint256) {
        return _gaugeStorage().rewardRate;
    }

    function lastUpdateTime() public view override returns (uint256) {
        return _gaugeStorage().lastUpdateTime;
    }

    function rewardPerTokenStored() public view override returns (uint256) {
        return _gaugeStorage().rewardPerTokenStored;
    }

    function totalSupply() public view override returns (uint256) {
        return _gaugeStorage().totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _gaugeStorage().balanceOf[account];
    }

    function userRewardPerTokenPaid(address account) public view override returns (uint256) {
        return _gaugeStorage().userRewardPerTokenPaid[account];
    }

    function rewards(address account) public view override returns (uint256) {
        return _gaugeStorage().rewards[account];
    }

    function rewardRateByEpoch(uint256 epoch_) public view override returns (uint256) {
        return _gaugeStorage().rewardRateByEpoch[epoch_];
    }

    function __Gauge_init(address rewardToken_, address voter_) internal onlyInitializing {
        if (
            rewardToken_ == address(0) || rewardToken_.code.length == 0 || voter_ == address(0)
                || voter_.code.length == 0
        ) revert NotAuthorized();
        address votingEscrow = IBaseVoter(voter_).ve();
        if (votingEscrow == address(0)) revert NotAuthorized();
        GaugeStorage storage $ = _gaugeStorage();
        $.rewardToken = rewardToken_;
        $.voter = voter_;
        $.ve = votingEscrow;
    }

    /// @inheritdoc IGauge
    function rewardPerToken() public override returns (uint256) {
        if (_gaugeStorage().totalSupply == 0) return _gaugeStorage().rewardPerTokenStored;
        return _gaugeStorage().rewardPerTokenStored
            + ((lastTimeRewardApplicable() - _gaugeStorage().lastUpdateTime) * _gaugeStorage().rewardRate * PRECISION)
            / _gaugeStorage().totalSupply;
    }

    /// @inheritdoc IGauge
    function lastTimeRewardApplicable() public override returns (uint256) {
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        return Math.min(uint256(epoch), _gaugeStorage().periodFinish);
    }

    /// @inheritdoc IGauge
    function earned(address account) public override returns (uint256) {
        return (_gaugeStorage().balanceOf[account]
                * (rewardPerToken() - _gaugeStorage().userRewardPerTokenPaid[account])) / PRECISION
            + _gaugeStorage().rewards[account];
    }

    /// @inheritdoc IGauge
    function getReward(address account) external override nonReentrant {
        if (msg.sender != account && msg.sender != _gaugeStorage().voter) revert NotAuthorized();
        _updateRewards(account);
        uint256 reward = _gaugeStorage().rewards[account];
        if (reward != 0) {
            _gaugeStorage().rewards[account] = 0;
            IERC20(_gaugeStorage().rewardToken).safeTransfer(account, reward);
            emit ClaimRewards(account, reward);
        }
    }

    /// @inheritdoc IGauge
    function left() external override returns (uint256) {
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        if (uint256(epoch) >= _gaugeStorage().periodFinish) return 0;
        return (_gaugeStorage().periodFinish - uint256(epoch)) * _gaugeStorage().rewardRate;
    }

    /// @inheritdoc IGauge
    function notifyRewardAmount(uint256 amount) external override nonReentrant {
        if (msg.sender != _gaugeStorage().voter) revert NotVoter();
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
        _gaugeStorage().rewardPerTokenStored = rewardPerToken();
        uint256 finish = uint256(ProtocolTimeLibrary.cycleNext(epoch));
        uint256 duration = finish - currentEpoch;
        IERC20(_gaugeStorage().rewardToken).safeTransferFrom(sender, address(this), amount);

        uint256 leftover = 0;
        if (currentEpoch < _gaugeStorage().periodFinish) {
            leftover = (_gaugeStorage().periodFinish - currentEpoch) * _gaugeStorage().rewardRate;
        }
        _gaugeStorage().rewardRate = (amount + leftover) / duration;
        if (_gaugeStorage().rewardRate == 0) revert ZeroRewardRate();
        if (_gaugeStorage().rewardRate > IERC20(_gaugeStorage().rewardToken).balanceOf(address(this)) / duration) {
            revert RewardRateTooHigh();
        }

        _gaugeStorage().rewardRateByEpoch[uint256(ProtocolTimeLibrary.cycleStart(epoch))] = _gaugeStorage().rewardRate;
        _gaugeStorage().lastUpdateTime = currentEpoch;
        _gaugeStorage().periodFinish = finish;
        emit NotifyReward(sender, amount);
    }

    /// @dev Settles an account against the latest cumulative reward-per-token value.
    function _updateRewards(address account) internal {
        _gaugeStorage().rewardPerTokenStored = rewardPerToken();
        _gaugeStorage().lastUpdateTime = lastTimeRewardApplicable();
        _gaugeStorage().rewards[account] = earned(account);
        _gaugeStorage().userRewardPerTokenPaid[account] = _gaugeStorage().rewardPerTokenStored;
    }
}
