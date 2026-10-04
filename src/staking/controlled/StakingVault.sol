// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StakeControlled} from "./StakeControlled.sol";

import {IValidatorRegistry} from "../../interfaces/IValidatorRegistry.sol";

/// @title StakingVault
/// @notice MON vault bound to exactly one validator.
contract StakingVault is StakeControlled {
    uint256 public constant MIN_AUTH_ADDRESS_STAKE = 100_000 ether;
    uint256 public constant REWARD_PRECISION = 1e27;

    IValidatorRegistry public registry;
    mapping(uint256 tokenId => uint256 amount) public balanceOf;
    mapping(uint256 tokenId => uint256 amount) public pendingWithdrawal;
    uint256 public totalBalance;
    uint256 public rewardPerShareStored;
    uint256 public accountedUnclaimedRewards;
    uint256 public rewardReserve;
    mapping(uint256 tokenId => uint256 rewardPerShare) public userRewardPerSharePaid;
    mapping(uint256 tokenId => uint256 amount) public rewards;

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
    error InvalidRecipient();
    error RewardTransferFailed();
    error InsufficientRewardLiquidity();

    event RewardsSynced(uint256 newlyAccrued, uint256 rewardPerShare);
    event RewardPaid(uint256 indexed tokenId, address indexed recipient, uint256 amount);

    /// @notice Called by the controller immediately after cloning.
    function initialize(address registry_, uint256 requestId_) external onlyController initializer {
        if (registry_ == address(0) || requestId_ == 0) revert InvalidRequest();

        registry = IValidatorRegistry(registry_);
        requestId = requestId_;
    }

    function deficit() public view returns (uint256) {
        return totalBalance >= MIN_AUTH_ADDRESS_STAKE ? 0 : MIN_AUTH_ADDRESS_STAKE - totalBalance;
    }

    /// @notice Stored and checkpointed MON rewards for one vault position.
    function earned(uint256 tokenId) public view returns (uint256) {
        uint256 rewardPerShare = rewardPerShareStored;
        uint256 paid = userRewardPerSharePaid[tokenId];
        uint256 stored = rewards[tokenId];
        if (rewardPerShare > paid) stored += balanceOf[tokenId] * (rewardPerShare - paid) / REWARD_PRECISION;
        return stored;
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
        if (msg.value == 0 || (validatorId == 0 && deficit() < msg.value)) revert InvalidAmount();

        _updateReward(tokenId);

        balanceOf[tokenId] += msg.value;
        totalBalance += msg.value;

        if (deficit() != 0) return validatorId;

        if (validatorId != 0) {
            STAKING.delegate{value: msg.value}(validatorId);
        } else {
            IValidatorRegistry.Submission memory submission = registry.getSubmission(requestId);
            validatorId = STAKING.addValidator{value: availableBalance()}(
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
        if (availableBalance() != rewardReserve) revert InvalidAmount();
        _updateReward(tokenId);
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

        if (availableBalance() - rewardReserve < amount) {
            if (!STAKING.withdraw(validatorId, WITHDRAW_ID)) return 0;
        }
        delete pendingWithdrawal[tokenId];

        (bool success,) = payable(controller).call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    /// @notice Claim a single veMON position's accrued MON rewards.
    function claimReward(uint256 tokenId, address recipient) external onlyController returns (uint256 amount) {
        if (validatorId == 0) revert ValidatorNotAdded();
        if (recipient == address(0)) revert InvalidRecipient();

        _updateReward(tokenId);
        uint256 trackedRewards = accountedUnclaimedRewards;
        uint256 claimedRewards = _claimRewardsRaw(validatorId);
        rewardReserve += claimedRewards > trackedRewards ? claimedRewards : trackedRewards;
        accountedUnclaimedRewards = 0;

        amount = rewards[tokenId];
        if (amount == 0) return 0;
        if (amount > rewardReserve || availableBalance() < amount) revert InsufficientRewardLiquidity();
        delete rewards[tokenId];
        rewardReserve -= amount;

        (bool success,) = payable(recipient).call{value: amount}("");
        if (!success) revert RewardTransferFailed();
        emit RewardPaid(tokenId, recipient, amount);
    }

    function _updateReward(uint256 tokenId) internal {
        _syncRewards();
        uint256 rewardPerShare = rewardPerShareStored;
        uint256 paid = userRewardPerSharePaid[tokenId];
        if (rewardPerShare > paid) {
            rewards[tokenId] += balanceOf[tokenId] * (rewardPerShare - paid) / REWARD_PRECISION;
        }
        userRewardPerSharePaid[tokenId] = rewardPerShare;
    }

    /// @dev Reads the vault delegator's precompile reward state and accounts
    ///      only the increase since the previous synchronization.
    function _syncRewards() internal {
        if (validatorId == 0 || totalBalance == 0) return;
        (,, uint256 unclaimedRewards,,,,) = STAKING.getDelegator(validatorId, address(this));

        uint256 newlyAccrued;
        if (unclaimedRewards > accountedUnclaimedRewards) {
            newlyAccrued = unclaimedRewards - accountedUnclaimedRewards;
        }
        accountedUnclaimedRewards = unclaimedRewards;

        if (newlyAccrued != 0) {
            rewardPerShareStored += newlyAccrued * REWARD_PRECISION / totalBalance;
            emit RewardsSynced(newlyAccrued, rewardPerShareStored);
        }
    }

    receive() external payable {
        if (msg.sender != address(STAKING)) revert UnexpectedEtherSender();
    }
}
