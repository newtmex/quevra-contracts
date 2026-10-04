// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VotingEscrow} from "./ve/VotingEscrow.sol";
import {IStakingController} from "./interfaces/IStakingController.sol";
import {ProtocolTimeLibrary} from "./libraries/ProtocolTimeLibrary.sol";

/// @title veMON
/// @notice Quevra voting escrow for MON routed into validator staking.
/// @dev Concrete deployment wrapper around the shared voting escrow implementation.
contract VeMON is VotingEscrow {
    address public immutable controller;

    error InvalidAddress();
    error InvalidValue();
    error NotController();

    constructor(address controller_, uint64 maxLockCycles_) VotingEscrow(maxLockCycles_, "Locked MON", "veMON") {
        if (controller_ == address(0)) revert InvalidAddress();
        controller = controller_;
    }

    function _deposit(uint256 amount, uint256 tokenId) internal override {
        if (msg.value != amount) revert InvalidValue();

        IStakingController(controller).deposit{value: amount}(tokenId);
    }

    /// @notice Withdraw a fully unstaked position's MON and burn its veNFT.
    function withdraw(uint256 tokenId) external override nonReentrant {
        _requireApprovedOrOwner(msg.sender, tokenId);

        if (_locked[tokenId].isPermanent) revert PermanentLock();

        (uint64 currentEpoch,) = ProtocolTimeLibrary.currentEpoch();
        if (_locked[tokenId].end > currentEpoch) revert LockNotExpired();

        IStakingController(controller).withdraw(tokenId);
        _burn(tokenId);
    }

    function _requireController() internal view override {
        if (msg.sender != controller) revert NotController();
    }
}
