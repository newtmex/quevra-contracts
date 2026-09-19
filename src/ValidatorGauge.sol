// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IValidatorRegistry} from "./interfaces/IValidatorRegistry.sol";
import {IValidatorVoter} from "./interfaces/IValidatorVoter.sol";
import {ProtocolTimeLibrary} from "./libraries/ProtocolTimeLibrary.sol";

/// @title ValidatorGauge
/// @notice Validator target for future voting and capital-routing integrations.
contract ValidatorGauge {
    using SafeERC20 for IERC20;

    address public immutable registry;
    address public immutable vault;
    address public immutable operator;
    uint256 public immutable requestId;
    IValidatorVoter public immutable voter;

    mapping(uint256 cycle => mapping(address token => uint256 amount)) public totalRewards;
    mapping(uint256 cycle => mapping(address token => mapping(address poster => uint256 amount))) public
        rewardContributions;

    event RewardNotified(uint256 indexed cycle, address indexed token, address indexed poster, uint256 amount);
    event RewardRefunded(uint256 indexed cycle, address indexed token, address indexed poster, uint256 amount);

    error InvalidReward();
    error RewardTokenNotWhitelisted();
    error CycleNotEnded();
    error ValidatorAccepted();
    error NoContribution();

    constructor(address registry_, address vault_, address operator_, uint256 requestId_, address voter_) {
        registry = registry_;
        vault = vault_;
        operator = operator_;
        requestId = requestId_;
        voter = IValidatorVoter(voter_);
    }

    /// @notice Posts ERC20 rewards for a voting cycle.
    /// @dev Records the actual balance increase to support fee-on-transfer tokens.
    function notifyReward(address token, uint256 amount) external returns (uint256 received) {
        if (token == address(0) || amount == 0) revert InvalidReward();
        if (!voter.isRewardTokenWhitelisted(token)) revert RewardTokenNotWhitelisted();

        uint256 cycle = ProtocolTimeLibrary.currentCycle();
        IERC20 rewardToken = IERC20(token);
        uint256 balanceBefore = rewardToken.balanceOf(address(this));
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        received = rewardToken.balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert InvalidReward();

        totalRewards[cycle][token] += received;
        rewardContributions[cycle][token][msg.sender] += received;

        emit RewardNotified(cycle, token, msg.sender, received);
    }

    /// @notice Returns a poster's contribution after the cycle ends if the validator was rejected.
    function refundReward(uint256 cycle, address token) external returns (uint256 amount) {
        if (ProtocolTimeLibrary.currentCycle() <= cycle) revert CycleNotEnded();
        if (voter.validatorAccepted(requestId, cycle)) revert ValidatorAccepted();

        amount = rewardContributions[cycle][token][msg.sender];
        if (amount == 0) revert NoContribution();

        rewardContributions[cycle][token][msg.sender] = 0;
        totalRewards[cycle][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit RewardRefunded(cycle, token, msg.sender, amount);
    }

    /// @notice Becomes nonzero after the vault executes its bound request.
    function validatorId() external view returns (uint64) {
        return IValidatorRegistry(registry).getProposal(requestId).validatorId;
    }
}
