// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VotingEscrow} from "./ve/VotingEscrow.sol";
import {IStakingController} from "./interfaces/IStakingController.sol";

/// @title veMON
/// @notice Quevra voting escrow for MON routed into validator staking.
/// @dev Concrete deployment wrapper around the shared voting escrow implementation.
contract VeMON is VotingEscrow {
    address public immutable controller;

    error InvalidAddress();
    error InvalidValue();

    constructor(address controller_, uint64 maxLockCycles_) VotingEscrow(maxLockCycles_, "Locked MON", "veMON") {
        if (controller_ == address(0)) revert InvalidAddress();
        controller = controller_;
    }

    function _deposit(uint256 amount, uint256 tokenId) internal override {
        if (msg.value != amount) revert InvalidValue();

        IStakingController(controller).deposit{value: amount}(tokenId);
    }
}
