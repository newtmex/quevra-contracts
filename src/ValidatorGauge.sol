// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IValidatorRegistry} from "./interfaces/IValidatorRegistry.sol";
import {ProtocolTimeLibrary} from "./libraries/ProtocolTimeLibrary.sol";

/// @title ValidatorGauge
/// @notice Validator target for future voting and capital-routing integrations.
contract ValidatorGauge {
    using SafeERC20 for IERC20;

    address public immutable registry;
    address public immutable vault;
    address public immutable operator;
    uint256 public immutable requestId;

    mapping(uint256 cycle => mapping(address token => uint256 amount)) public totalRewards;
    mapping(uint256 cycle => mapping(address token => mapping(address poster => uint256 amount))) public
        rewardContributions;

    event RewardNotified(uint256 indexed cycle, address indexed token, address indexed poster, uint256 amount);

    error InvalidReward();

    constructor(address registry_, address vault_, address operator_, uint256 requestId_) {
        registry = registry_;
        vault = vault_;
        operator = operator_;
        requestId = requestId_;
    }

    /// @notice Posts ERC20 rewards for a voting cycle.
    /// @dev Records the actual balance increase to support fee-on-transfer tokens.
    function notifyReward(address token, uint256 amount) external returns (uint256 received) {
        if (token == address(0) || amount == 0) revert InvalidReward();

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

    /// @notice Becomes nonzero after the vault executes its bound request.
    function validatorId() external view returns (uint64) {
        return IValidatorRegistry(registry).getProposal(requestId).validatorId;
    }
}
