// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IValidatorRegistry} from "../interfaces/IValidatorRegistry.sol";
import {IValidatorVoter} from "../interfaces/IValidatorVoter.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";

interface IVeMONOwner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

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
    mapping(uint256 cycle => address[]) private _rewardTokens;
    mapping(uint256 cycle => mapping(address token => bool)) private _hasRewardToken;
    mapping(uint256 cycle => mapping(uint256 tokenId => mapping(address token => bool))) public rewardClaimed;

    event RewardNotified(uint256 indexed cycle, address indexed token, address indexed poster, uint256 amount);
    event RewardRefunded(uint256 indexed cycle, address indexed token, address indexed poster, uint256 amount);
    event RewardClaimed(
        uint256 indexed cycle, address indexed token, uint256 indexed tokenId, address recipient, uint256 amount
    );

    error InvalidReward();
    error RewardTokenNotWhitelisted();
    error CycleNotEnded();
    error ValidatorAccepted();
    error NoContribution();
    error NoReward();
    error NotAccepted();

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
        if (!_hasRewardToken[cycle][token]) {
            _hasRewardToken[cycle][token] = true;
            _rewardTokens[cycle].push(token);
        }

        emit RewardNotified(cycle, token, msg.sender, received);
    }

    /// @notice Reward earned by a veMON position from this gauge for a finalized cycle.
    function earned(uint256 tokenId, uint256 cycle, address token) public view returns (uint256) {
        if (!voter.isGaugeAccepted(address(this), cycle)) return 0;
        uint256 denominator = voter.totalGaugeWeight(address(this), cycle);
        if (denominator == 0) return 0;
        return Math.mulDiv(totalRewards[cycle][token], voter.voterWeight(tokenId, address(this), cycle), denominator);
    }

    function claimableRewards(uint256 tokenId, uint256 cycle)
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        tokens = _rewardTokens[cycle];
        amounts = new uint256[](tokens.length);
        if (!voter.isGaugeAccepted(address(this), cycle)) {
            return (tokens, amounts);
        }
        for (uint256 i; i < tokens.length; ++i) {
            if (!rewardClaimed[cycle][tokenId][tokens[i]]) {
                amounts[i] = earned(tokenId, cycle, tokens[i]);
            }
        }
    }

    function rewardTokens(uint256 cycle) external view returns (address[] memory) {
        return _rewardTokens[cycle];
    }

    function claim(uint256 tokenId, uint256 cycle, address token) public returns (uint256 amount) {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory amounts = _claim(tokenId, cycle, tokens);
        return amounts[0];
    }

    function claim(uint256 tokenId, uint256 cycle, address[] calldata tokens)
        external
        returns (uint256[] memory amounts)
    {
        return _claim(tokenId, cycle, tokens);
    }

    function _claim(uint256 tokenId, uint256 cycle, address[] memory tokens)
        private
        returns (uint256[] memory amounts)
    {
        if (ProtocolTimeLibrary.currentCycle() <= cycle) revert CycleNotEnded();
        if (!voter.isGaugeAccepted(address(this), cycle)) revert NotAccepted();
        address recipient = veMONOwner(tokenId);
        amounts = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            if (rewardClaimed[cycle][tokenId][token]) revert NoReward();
            uint256 amount = earned(tokenId, cycle, token);
            if (amount == 0) revert NoReward();
            rewardClaimed[cycle][tokenId][token] = true;
            amounts[i] = amount;
        }
        for (uint256 i; i < tokens.length; ++i) {
            IERC20(tokens[i]).safeTransfer(recipient, amounts[i]);
            emit RewardClaimed(cycle, tokens[i], tokenId, recipient, amounts[i]);
        }
    }

    function veMONOwner(uint256 tokenId) private view returns (address) {
        // The voter validates that tokenId has historical weight; the current owner receives the claim.
        return IVeMONOwner(address(voter.veMON())).ownerOf(tokenId);
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
