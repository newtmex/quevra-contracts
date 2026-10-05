// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {IStakingController} from "../interfaces/IStakingController.sol";

/// @title ValidatorGauge
/// @notice Permanent Quevra voting target for one validator onboarding request.
/// @dev Its identity is tied to the request, not to a Monad validator ID that
///      may not exist yet. The controller records veMON-scaled weight as each
///      vault or agent delegation occurs and removes it on undelegation.
contract ValidatorGauge is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 private constant REWARD_PRECISION = 1e27;
    address public immutable controller;
    uint256 public immutable requestId;
    address public immutable operator;
    mapping(uint256 tokenId => uint256 weight) public weightOf;
    uint256 public totalWeight;
    address[] private _rewardTokens;
    mapping(address token => bool registered) public isRewardToken;
    mapping(address token => uint256 index) public rewardPerWeightStored;
    mapping(uint256 tokenId => mapping(address token => uint256 index)) public userRewardPerWeightPaid;
    mapping(uint256 tokenId => mapping(address token => uint256 amount)) public rewards;

    error InvalidGaugeIdentity();
    error NotController();
    error RewardTokenNotWhitelisted();
    error NoGaugeWeight();
    error InvalidRewardAmount();
    error RewardTooSmall();
    error NotTokenOwner();

    event WeightIncreased(uint256 indexed tokenId, uint256 amount, uint256 newWeight, uint256 newTotalWeight);
    event WeightDecreased(uint256 indexed tokenId, uint256 amount, uint256 newWeight, uint256 newTotalWeight);
    event RewardNotified(address indexed token, address indexed sender, uint256 amount);
    event RewardPaid(uint256 indexed tokenId, address indexed token, address indexed owner, uint256 amount);

    constructor(address controller_, uint256 requestId_, address operator_) {
        if (controller_ == address(0) || requestId_ == 0 || operator_ == address(0)) {
            revert InvalidGaugeIdentity();
        }
        controller = controller_;
        requestId = requestId_;
        operator = operator_;
    }

    function increaseWeight(uint256 tokenId, uint256 amount) external {
        if (msg.sender != controller) revert NotController();
        if (amount == 0) return;
        _checkpointRewards(tokenId);
        uint256 newWeight = weightOf[tokenId] + amount;
        weightOf[tokenId] = newWeight;
        totalWeight += amount;
        emit WeightIncreased(tokenId, amount, newWeight, totalWeight);
    }

    function decreaseWeight(uint256 tokenId, uint256 amount) external {
        if (msg.sender != controller) revert NotController();
        if (amount == 0) return;
        _checkpointRewards(tokenId);
        uint256 newWeight = weightOf[tokenId] - amount;
        weightOf[tokenId] = newWeight;
        totalWeight -= amount;
        emit WeightDecreased(tokenId, amount, newWeight, totalWeight);
    }

    /// @notice Distribute an ERC20 deposit to the weight backing this validator now.
    /// @dev Zero-weight deposits revert instead of being assigned to later voters.
    function notifyRewardAmount(address token, uint256 amount) external nonReentrant {
        if (!IStakingController(controller).isRewardTokenWhitelisted(token)) revert RewardTokenNotWhitelisted();
        uint256 supply = totalWeight;
        if (supply == 0) revert NoGaugeWeight();
        if (amount == 0) revert InvalidRewardAmount();

        uint256 indexDelta = Math.mulDiv(amount, REWARD_PRECISION, supply);
        if (indexDelta == 0) revert RewardTooSmall();

        IERC20 rewardToken = IERC20(token);
        uint256 beforeBalance = rewardToken.balanceOf(address(this));
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        if (rewardToken.balanceOf(address(this)) - beforeBalance != amount) revert InvalidRewardAmount();

        if (!isRewardToken[token]) {
            isRewardToken[token] = true;
            _rewardTokens.push(token);
        }
        rewardPerWeightStored[token] += indexDelta;
        emit RewardNotified(token, msg.sender, amount);
    }

    function rewardTokenCount() external view returns (uint256) {
        return _rewardTokens.length;
    }

    function rewardTokenAt(uint256 index) external view returns (address) {
        return _rewardTokens[index];
    }

    function earned(uint256 tokenId, address token) public view returns (uint256) {
        return rewards[tokenId][token]
            + Math.mulDiv(
            weightOf[tokenId], rewardPerWeightStored[token] - userRewardPerWeightPaid[tokenId][token], REWARD_PRECISION
        );
    }

    /// @notice Claim one reward token without touching another token's accrual.
    function claimReward(uint256 tokenId, address token) external nonReentrant returns (uint256 amount) {
        address owner = _requireTokenOwner(tokenId);
        _checkpointReward(tokenId, token);
        amount = _payReward(tokenId, token, owner);
    }

    /// @notice Claim every reward token ever deposited in this validator gauge.
    function claimRewards(uint256 tokenId) external nonReentrant {
        address owner = _requireTokenOwner(tokenId);
        for (uint256 i; i < _rewardTokens.length; ++i) {
            address token = _rewardTokens[i];
            _checkpointReward(tokenId, token);
            _payReward(tokenId, token, owner);
        }
    }

    function _requireTokenOwner(uint256 tokenId) private view returns (address owner) {
        owner = IVotingEscrow(IStakingController(controller).ve()).ownerOf(tokenId);
        if (msg.sender != owner) revert NotTokenOwner();
    }

    function _checkpointRewards(uint256 tokenId) private {
        for (uint256 i; i < _rewardTokens.length; ++i) {
            _checkpointReward(tokenId, _rewardTokens[i]);
        }
    }

    function _checkpointReward(uint256 tokenId, address token) private {
        uint256 index = rewardPerWeightStored[token];
        uint256 paid = userRewardPerWeightPaid[tokenId][token];
        if (index > paid) {
            rewards[tokenId][token] += Math.mulDiv(weightOf[tokenId], index - paid, REWARD_PRECISION);
            userRewardPerWeightPaid[tokenId][token] = index;
        }
    }

    function _payReward(uint256 tokenId, address token, address owner) private returns (uint256 amount) {
        amount = rewards[tokenId][token];
        if (amount == 0) return 0;
        delete rewards[tokenId][token];
        IERC20(token).safeTransfer(owner, amount);
        emit RewardPaid(tokenId, token, owner, amount);
    }
}
