// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBaseVoter} from "../interfaces/IBaseVoter.sol";
import {IValidatorGauge} from "../interfaces/IValidatorGauge.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";

interface IValidatorGaugeVoter {
    function isValidatorRewardEligible(address gauge) external view returns (bool);
    function isWhitelistedToken(address token) external view returns (bool);
}

contract ValidatorGauge is IValidatorGauge, ERC2771Context, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct RewardState {
        uint256 rate;
        uint256 periodFinish;
        uint256 lastUpdate;
        uint256 rewardPerTokenStored;
    }

    address public immutable override voter;
    address public immutable override ve;
    mapping(uint256 tokenId => uint256 amount) public override activeLiquidity;
    uint256 public override totalActiveLiquidity;
    mapping(address token => RewardState) public rewardState;
    mapping(address token => bool) public isPostedReward;
    mapping(address token => mapping(uint256 tokenId => uint256)) public userRewardPerTokenPaid;
    mapping(address token => mapping(uint256 tokenId => uint256)) public rewards;
    address[] private _postedRewards;

    constructor(address forwarder, address voter_) ERC2771Context(forwarder) {
        if (voter_ == address(0)) revert ZeroAddress();
        voter = voter_;
        ve = IBaseVoter(voter_).ve();
    }

    function notifyRewardAmount(address token, uint256 amount) external override nonReentrant {
        if (token == address(0) || amount == 0) revert InvalidRewardToken();
        if (!IValidatorGaugeVoter(voter).isWhitelistedToken(token)) revert RewardTokenNotWhitelisted();
        if (!IValidatorGaugeVoter(voter).isValidatorRewardEligible(address(this))) revert NotAuthorized();

        _updateReward(token, 0, false);
        IERC20 reward = IERC20(token);
        uint256 beforeBalance = reward.balanceOf(address(this));
        reward.safeTransferFrom(_msgSender(), address(this), amount);
        uint256 received = reward.balanceOf(address(this)) - beforeBalance;
        if (received == 0) revert InvalidRewardToken();

        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        uint256 cycleEnd = ProtocolTimeLibrary.cycleNext(epoch);
        RewardState storage state = rewardState[token];
        uint256 remaining = epoch >= state.periodFinish ? 0 : state.periodFinish - epoch;
        state.rate = (received + remaining * state.rate) / (cycleEnd - epoch);
        if (state.rate == 0) revert ZeroRewardRate();
        state.lastUpdate = epoch;
        state.periodFinish = cycleEnd;
        if (!isPostedReward[token]) {
            isPostedReward[token] = true;
            _postedRewards.push(token);
        }
    }

    function updateLiquidity(uint256 tokenId, uint256 amount) external override {
        if (_msgSender() != voter) revert NotAuthorized();
        _updateAllRewards(tokenId);
        totalActiveLiquidity = totalActiveLiquidity - activeLiquidity[tokenId] + amount;
        activeLiquidity[tokenId] = amount;
    }

    function earned(address token, uint256 tokenId) public view override returns (uint256) {
        RewardState memory state = rewardState[token];
        uint256 perToken = state.rewardPerTokenStored;
        uint256 applicable = _applicable(state);
        if (totalActiveLiquidity != 0 && applicable > state.lastUpdate) {
            perToken += (applicable - state.lastUpdate) * state.rate * 1e18 / totalActiveLiquidity;
        }
        return
            rewards[token][tokenId] + activeLiquidity[tokenId] * (perToken - userRewardPerTokenPaid[token][tokenId])
                / 1e18;
    }

    function claimTokenReward(uint256 tokenId) external override nonReentrant returns (uint256 amount) {
        address owner = IVotingEscrow(ve).ownerOf(tokenId);
        address sender = _msgSender();
        if (sender != owner && sender != voter) revert NotAuthorized();

        _updateAllRewards(tokenId);
        for (uint256 i; i < _postedRewards.length; ++i) {
            address token = _postedRewards[i];
            uint256 reward = rewards[token][tokenId];
            if (reward == 0) continue;
            rewards[token][tokenId] = 0;
            IERC20(token).safeTransfer(owner, reward);
            amount += reward;
        }
    }

    function _updateAllRewards(uint256 tokenId) private {
        for (uint256 i; i < _postedRewards.length; ++i) {
            _updateReward(_postedRewards[i], tokenId, true);
        }
    }

    function _updateReward(address token, uint256 tokenId, bool account) private {
        RewardState storage state = rewardState[token];
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        uint256 applicable = epoch < state.periodFinish ? epoch : state.periodFinish;
        if (totalActiveLiquidity != 0 && applicable > state.lastUpdate) {
            state.rewardPerTokenStored += (applicable - state.lastUpdate) * state.rate * 1e18 / totalActiveLiquidity;
        }
        state.lastUpdate = applicable;
        if (account) {
            rewards[token][tokenId] += activeLiquidity[tokenId]
            * (state.rewardPerTokenStored - userRewardPerTokenPaid[token][tokenId]) / 1e18;
            userRewardPerTokenPaid[token][tokenId] = state.rewardPerTokenStored;
        }
    }

    function _applicable(RewardState memory state) private view returns (uint256) {
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpochView();
        return epoch < state.periodFinish ? epoch : state.periodFinish;
    }
}
