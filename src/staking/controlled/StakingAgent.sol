// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";
import {StakeControlled} from "./StakeControlled.sol";

/// @title StakingAgent
/// @notice A token-bound agent that delegates MON to Monad validators.
contract StakingAgent is StakeControlled {
    uint8 public constant WITHDRAW_ID = 0;

    mapping(uint64 validatorId => uint256 amount) public balanceOf;

    error EmptyArray();
    error LengthMismatch();
    error ZeroAmount();
    error ValueMismatch();
    error StakingCallFailed();
    error TransferFailed();
    error UnexpectedEtherSender();
    error InsufficientBalance();

    function delegate(uint64[] calldata validatorIds, uint256[] calldata amounts) external payable onlyController {
        _validateArrays(validatorIds.length, amounts.length);
        uint256 total;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 amount = amounts[i];
            if (amount == 0) revert ZeroAmount();
            if (!STAKING.delegate{value: amount}(validatorIds[i])) revert StakingCallFailed();
            balanceOf[validatorIds[i]] += amount;
            total += amount;
        }
        if (total != msg.value) revert ValueMismatch();
    }

    function undelegate(uint64[] calldata validatorIds, uint256[] calldata amounts) external onlyController {
        _validateArrays(validatorIds.length, amounts.length);
        for (uint256 i; i < amounts.length; ++i) {
            if (amounts[i] == 0) revert ZeroAmount();
            if (balanceOf[validatorIds[i]] < amounts[i]) revert InsufficientBalance();
            if (!STAKING.undelegate(validatorIds[i], amounts[i], WITHDRAW_ID)) revert StakingCallFailed();
            balanceOf[validatorIds[i]] -= amounts[i];
        }
    }

    function withdraw(uint64[] calldata validatorIds) external onlyController {
        if (validatorIds.length == 0) revert EmptyArray();
        for (uint256 i; i < validatorIds.length; ++i) {
            if (!STAKING.withdraw(validatorIds[i], WITHDRAW_ID)) revert StakingCallFailed();
        }

        uint256 balance = availableBalance();
        if (balance != 0) {
            (bool success,) = payable(controller).call{value: balance}("");
            if (!success) revert TransferFailed();
        }
    }

    /// @dev Monad sends redeemed stake to the caller of `staking.withdraw`.
    receive() external payable {
        if (msg.sender != address(STAKING)) revert UnexpectedEtherSender();
    }

    function _validateArrays(uint256 validatorCount, uint256 amountCount) private pure {
        if (validatorCount == 0) revert EmptyArray();
        if (validatorCount != amountCount) revert LengthMismatch();
    }
}
