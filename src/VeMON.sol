// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VotingEscrow} from "./VotingEscrow.sol";

/// @title veMON
/// @notice Quevra voting escrow for MON routed into validator staking.
/// @dev Concrete deployment wrapper around the shared voting escrow implementation.
contract VeMON is VotingEscrow {
    address public immutable controller;

    error InvalidAddress();
    error InvalidValue();
    error ForwardFailed();

    constructor(address controller_, uint64 maxLockCycles_) VotingEscrow(maxLockCycles_, "Locked MON", "veMON") {
        if (controller_ == address(0)) revert InvalidAddress();
        controller = controller_;
    }

    function _deposit(uint256 amount) internal override {
        if (msg.value != amount) revert InvalidValue();

        (bool success, bytes memory returndata) = controller.call{value: amount}("");
        if (!success) {
            if (returndata.length == 0) revert ForwardFailed();
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
    }
}
