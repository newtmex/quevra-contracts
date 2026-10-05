// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ValidatorGauge
/// @notice Permanent Quevra voting target for one validator onboarding request.
/// @dev The gauge is intentionally inert in this stage. Its identity is tied to
///      the request, not to a Monad validator ID that may not exist yet.
contract ValidatorGauge {
    address public immutable controller;
    uint256 public immutable requestId;
    address public immutable operator;

    error InvalidGaugeIdentity();

    constructor(address controller_, uint256 requestId_, address operator_) {
        if (controller_ == address(0) || requestId_ == 0 || operator_ == address(0)) {
            revert InvalidGaugeIdentity();
        }
        controller = controller_;
        requestId = requestId_;
        operator = operator_;
    }
}
