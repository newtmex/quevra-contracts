// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StakeControlled} from "./StakeControlled.sol";

import {IValidatorRegistry} from "../../interfaces/IValidatorRegistry.sol";

/// @title StakingVault
/// @notice MON vault bound to exactly one validator.
contract StakingVault is StakeControlled {
    uint256 public constant MIN_AUTH_ADDRESS_STAKE = 100_000 ether;

    IValidatorRegistry public registry;
    mapping(uint256 tokenId => uint256 amount) public balanceOf;
    mapping(uint256 tokenId => uint256 amount) public pendingWithdrawal;
    uint256 public totalBalance;

    /// @notice The only validator request this vault can execute.
    uint256 public requestId;

    /// @notice Set after the request is successfully executed.
    uint64 public validatorId;

    error ValidatorAlreadyAdded();
    error ValidatorNotAdded();
    error InvalidRequest();
    error AddValidatorFailed();
    error UndelegationFailed();
    error TransferFailed();
    error InvalidAmount();
    error StakingCallFailed();
    error UnexpectedEtherSender();

    /// @notice Called by the controller immediately after cloning.
    function initialize(address registry_, uint256 requestId_) external onlyController initializer {
        if (registry_ == address(0) || requestId_ == 0) revert InvalidRequest();

        registry = IValidatorRegistry(registry_);
        requestId = requestId_;
    }

    function deficit() public view returns (uint256) {
        return totalBalance >= MIN_AUTH_ADDRESS_STAKE ? 0 : MIN_AUTH_ADDRESS_STAKE - totalBalance;
    }

    function positionOf(uint256 tokenId)
        external
        view
        returns (uint256 allocation, uint256 pending, uint64 currentValidatorId)
    {
        allocation = balanceOf[tokenId];
        pending = pendingWithdrawal[tokenId];
        currentValidatorId = validatorId;
    }

    /// @notice Accounts deposits and uses the registry to activate the validator.
    /// @dev The controller caps the value forwarded here. The vault itself also
    ///      enforces the cap so it can never overfund validator creation.
    function deposit(uint256 tokenId) external payable onlyController returns (uint64 currentValidatorId) {
        if (msg.value == 0 || deficit() < msg.value) revert InvalidAmount();

        balanceOf[tokenId] += msg.value;
        totalBalance += msg.value;

        if (deficit() != 0) return validatorId;

        uint256 balance = availableBalance();
        if (validatorId != 0) {
            STAKING.delegate{value: balance}(validatorId);
        } else {
            IValidatorRegistry.Submission memory submission = registry.getSubmission(requestId);
            validatorId = STAKING.addValidator{value: balance}(
                submission.payload, submission.signedSecpMessage, submission.signedBlsMessage
            );
            if (validatorId == 0) revert AddValidatorFailed();
        }
        return validatorId;
    }

    /// @notice Begin withdrawing part of a token's active allocation.
    /// @dev The withdrawal slot is shared by the vault. A later token can be
    ///      credited from the same redeemed balance once the first request is
    ///      finalized; Monad does not need one precompile slot per token.
    function undelegate(uint256 tokenId, uint256 amount) external onlyController {
        if (validatorId == 0 || amount == 0 || balanceOf[tokenId] < amount) revert InvalidAmount();
        if (pendingWithdrawal[tokenId] != 0) revert InvalidAmount();
        if (availableBalance() != 0) revert InvalidAmount();
        if (!STAKING.undelegate(validatorId, amount, WITHDRAW_ID)) {
            revert UndelegationFailed();
        }
        balanceOf[tokenId] -= amount;
        totalBalance -= amount;
        pendingWithdrawal[tokenId] = amount;
    }

    /// @notice Finalize a matured withdrawal and return this token's share.
    function withdraw(uint256 tokenId) external onlyController returns (uint256 amount) {
        amount = pendingWithdrawal[tokenId];
        if (amount == 0) revert InvalidAmount();

        if (availableBalance() < amount) {
            if (!STAKING.withdraw(validatorId, WITHDRAW_ID)) return 0;
        }
        delete pendingWithdrawal[tokenId];

        (bool success,) = payable(controller).call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    function claimRewards() external onlyController {
        if (validatorId == 0) revert ValidatorNotAdded();
        _claimRewards(validatorId);
    }

    function compound() external onlyController {
        if (validatorId == 0) revert ValidatorNotAdded();
        _compound(validatorId);
    }

    receive() external payable {
        if (msg.sender != address(STAKING)) revert UnexpectedEtherSender();
    }
}
