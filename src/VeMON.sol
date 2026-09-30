// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VotingEscrow} from "./ve/VotingEscrow.sol";
import {IStakingController} from "./interfaces/IStakingController.sol";
import {IVoter} from "./interfaces/IVoter.sol";

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

    /// @notice Release a fully unstaked position's MON and burn its veNFT.
    /// @dev Pending Monad withdrawals are finalized in the same transaction
    ///      when they have matured. Vote intent is cleared before the veNFT is
    ///      burned; the original lock principal remains an immutable record.
    function withdraw(uint256 tokenId) external override nonReentrant {
        _requireApprovedOrOwner(msg.sender, tokenId);

        IStakingController stakingController = IStakingController(controller);
        IVoter voter = IVoter(stakingController.voter());
        voter.clearVoteFromEscrow(tokenId);
        stakingController.finalizeWithdrawals(tokenId);
        if (!stakingController.isFullyUnstaked(tokenId)) revert InvalidAmount();

        address recipient = ownerOf(tokenId);
        stakingController.release(tokenId, payable(recipient));
        _burn(tokenId);
    }
}
