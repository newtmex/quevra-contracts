// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ValidatorGauge
/// @notice Permanent Quevra voting target for one validator onboarding request.
/// @dev Its identity is tied to the request, not to a Monad validator ID that
///      may not exist yet. The controller records veMON-scaled weight as each
///      vault or agent delegation occurs and removes it on undelegation.
contract ValidatorGauge {
    address public immutable controller;
    uint256 public immutable requestId;
    address public immutable operator;
    mapping(uint256 tokenId => uint256 weight) public weightOf;
    uint256 public totalWeight;

    error InvalidGaugeIdentity();
    error NotController();

    event WeightIncreased(uint256 indexed tokenId, uint256 amount, uint256 newWeight, uint256 newTotalWeight);
    event WeightDecreased(uint256 indexed tokenId, uint256 amount, uint256 newWeight, uint256 newTotalWeight);

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
        uint256 newWeight = weightOf[tokenId] + amount;
        weightOf[tokenId] = newWeight;
        totalWeight += amount;
        emit WeightIncreased(tokenId, amount, newWeight, totalWeight);
    }

    function decreaseWeight(uint256 tokenId, uint256 amount) external {
        if (msg.sender != controller) revert NotController();
        if (amount == 0) return;
        uint256 newWeight = weightOf[tokenId] - amount;
        weightOf[tokenId] = newWeight;
        totalWeight -= amount;
        emit WeightDecreased(tokenId, amount, newWeight, totalWeight);
    }
}
