// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";
import {StakeControlled} from "./StakeControlled.sol";

/// @title StakingAgent
/// @notice A token-bound agent that delegates MON to Monad validators.
contract StakingAgent is StakeControlled {
    mapping(uint64 validatorId => uint256 amount) public balanceOf;
    mapping(uint64 validatorId => uint256 amount) public pendingWithdrawal;
    mapping(uint64 validatorId => bool usedValidator) public usedValidator;

    error EmptyArray();
    error LengthMismatch();
    error ZeroAmount();
    error ValueMismatch();
    error StakingCallFailed();
    error TransferFailed();
    error UnexpectedEtherSender();
    error InsufficientBalance();
    error WithdrawalPending(uint64 validatorId);

    function positionOf(uint64 validatorId) external view returns (uint256 allocation, uint256 pending) {
        allocation = balanceOf[validatorId];
        pending = pendingWithdrawal[validatorId];
    }

    function _validateArrays(uint256 validatorCount, uint256 amountCount) private pure {
        if (validatorCount == 0) revert EmptyArray();
        if (validatorCount != amountCount) revert LengthMismatch();
    }

    function _delegate(uint64 validatorId, uint256 amount) internal {
        if (!STAKING.delegate{value: amount}(validatorId)) revert StakingCallFailed();
        balanceOf[validatorId] += amount;
        usedValidator[validatorId] = true;
    }

    function _undelegate(uint64 validatorId, uint256 amount) internal {
        if (pendingWithdrawal[validatorId] != 0) revert WithdrawalPending(validatorId);
        if (amount == 0) revert ZeroAmount();
        if (balanceOf[validatorId] < amount) revert InsufficientBalance();
        if (!STAKING.undelegate(validatorId, amount, WITHDRAW_ID)) revert StakingCallFailed();
        balanceOf[validatorId] -= amount;
        pendingWithdrawal[validatorId] = amount;
    }

    function _withdraw(uint64 validatorId) internal {
        if (!STAKING.withdraw(validatorId, WITHDRAW_ID)) revert StakingCallFailed();
        delete pendingWithdrawal[validatorId];
    }

    function delegate(uint64[] calldata validatorIds, uint256[] calldata amounts) external payable onlyController {
        _validateArrays(validatorIds.length, amounts.length);
        uint256 total;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 amount = amounts[i];
            if (amount == 0) revert ZeroAmount();
            _delegate(validatorIds[i], amount);
            total += amount;
        }
        if (total != msg.value) revert ValueMismatch();
    }

    function delegate(uint64 validatorId, uint256 amount) external payable onlyController {
        if (amount == 0 || msg.value != amount) revert ValueMismatch();
        _delegate(validatorId, amount);
    }

    function undelegate(uint64[] calldata validatorIds, uint256[] calldata amounts) external onlyController {
        _validateArrays(validatorIds.length, amounts.length);
        for (uint256 i; i < amounts.length; ++i) {
            _undelegate(validatorIds[i], amounts[i]);
        }
    }

    function undelegate(uint64 validatorId, uint256 amount) external onlyController {
        _undelegate(validatorId, amount);
    }

    function withdraw(uint64[] calldata validatorIds) external onlyController {
        if (validatorIds.length == 0) revert EmptyArray();
        for (uint256 i; i < validatorIds.length; ++i) {
            _withdraw(validatorIds[i]);
        }

        uint256 balance = availableBalance();
        if (balance != 0) {
            (bool success,) = payable(controller).call{value: balance}("");
            if (!success) revert TransferFailed();
        }
    }

    function withdraw(uint64 validatorId) external onlyController {
        _withdraw(validatorId);
        uint256 balance = availableBalance();
        if (balance != 0) {
            (bool success,) = payable(controller).call{value: balance}("");
            if (!success) revert TransferFailed();
        }
    }

    function claimRewards(uint64[] calldata validatorIds)
        external
        onlyController
        returns (uint256[] memory claimedAmounts)
    {
        if (validatorIds.length == 0) revert EmptyArray();
        uint256 beforeBalance = availableBalance();
        claimedAmounts = new uint256[](validatorIds.length);
        for (uint256 i; i < validatorIds.length; ++i) {
            claimedAmounts[i] = _claimRewardsRaw(validatorIds[i]);
        }
        uint256 claimed = availableBalance() - beforeBalance;
        if (claimed != 0) {
            (bool success,) = payable(controller).call{value: claimed}("");
            if (!success) revert TransferFailed();
        }
    }

    /// @dev Monad sends redeemed stake to the caller of `staking.withdraw`.
    receive() external payable {
        if (msg.sender != address(STAKING)) revert UnexpectedEtherSender();
    }
}
