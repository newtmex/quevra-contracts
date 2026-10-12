// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StakeControlled} from "./StakeControlled.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IVeValidator} from "../../interfaces/IVeValidator.sol";

/// @title StakingVault
/// @notice MON vault bound to exactly one validator.
contract StakingVault is StakeControlled {
    using EnumerableSet for EnumerableSet.UintSet;

    uint256 public constant MIN_AUTH_ADDRESS_STAKE = 100_000 ether;
    uint256 public constant REWARD_PRECISION = 1e27;

    /// @custom:storage-location erc7201:quevra.StakingVault
    struct StakingVaultStorage {
        IVeValidator validatorVe;
        mapping(uint256 tokenId => uint256 amount) balanceOf;
        mapping(uint256 tokenId => uint256 amount) pendingWithdrawal;
        EnumerableSet.UintSet tokenIds;
        uint256 totalBalance;
        uint256 rewardPerShareStored;
        uint256 accountedUnclaimedRewards;
        uint256 rewardReserve;
        mapping(uint256 tokenId => uint256 rewardPerShare) userRewardPerSharePaid;
        mapping(uint256 tokenId => uint256 amount) rewards;
        uint256 validatorTokenId;
        bool requiresMinimumStake;
        uint64 currentValidatorId;
    }

    bytes32 private constant STAKING_VAULT_STORAGE_SLOT =
        0x893650d15963dde93fd26941fe79ad83546083e6893de5d5c0634cd87ac2a700;

    function _vaultStorage() internal pure returns (StakingVaultStorage storage $) {
        bytes32 slot = STAKING_VAULT_STORAGE_SLOT;
        assembly ("memory-safe") { $.slot := slot }
    }

    function validatorVe() public view returns (IVeValidator) {
        return _vaultStorage().validatorVe;
    }

    function balanceOf(uint256 tokenId) public view returns (uint256) {
        return _vaultStorage().balanceOf[tokenId];
    }

    function pendingWithdrawal(uint256 tokenId) public view returns (uint256) {
        return _vaultStorage().pendingWithdrawal[tokenId];
    }

    function totalBalance() public view returns (uint256) {
        return _vaultStorage().totalBalance;
    }

    function rewardPerShareStored() public view returns (uint256) {
        return _vaultStorage().rewardPerShareStored;
    }

    function accountedUnclaimedRewards() public view returns (uint256) {
        return _vaultStorage().accountedUnclaimedRewards;
    }

    function rewardReserve() public view returns (uint256) {
        return _vaultStorage().rewardReserve;
    }

    function userRewardPerSharePaid(uint256 tokenId) public view returns (uint256) {
        return _vaultStorage().userRewardPerSharePaid[tokenId];
    }

    function rewards(uint256 tokenId) public view returns (uint256) {
        return _vaultStorage().rewards[tokenId];
    }

    function validatorTokenId() public view returns (uint256) {
        return _vaultStorage().validatorTokenId;
    }

    function requiresMinimumStake() public view returns (bool) {
        return _vaultStorage().requiresMinimumStake;
    }

    function validatorId() public view returns (uint64) {
        return _vaultStorage().currentValidatorId;
    }

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
    function initialize(address controller_, address validatorVe_, uint256 tokenId_, uint64 validatorId_)
        external
        initializer
    {
        if (validatorVe_ == address(0) || validatorVe_.code.length == 0 || tokenId_ == 0) {
            revert InvalidRequest();
        }
        __StakeControlled_init(controller_);

        StakingVaultStorage storage $ = _vaultStorage();
        $.validatorVe = IVeValidator(validatorVe_);
        $.validatorTokenId = tokenId_;
        $.currentValidatorId = validatorId_;
        $.requiresMinimumStake = validatorId_ == 0;
    }

    function deficit() public view returns (uint256) {
        if (!_vaultStorage().requiresMinimumStake) return 0;
        return _vaultStorage().totalBalance >= MIN_AUTH_ADDRESS_STAKE
            ? 0
            : MIN_AUTH_ADDRESS_STAKE - _vaultStorage().totalBalance;
    }

    /// @notice Stored and checkpointed MON rewards for one vault position.
    function earned(uint256 tokenId) public view returns (uint256) {
        uint256 rewardPerShare = _vaultStorage().rewardPerShareStored;
        uint256 paid = _vaultStorage().userRewardPerSharePaid[tokenId];
        uint256 stored = _vaultStorage().rewards[tokenId];
        if (rewardPerShare > paid) {
            stored += _vaultStorage().balanceOf[tokenId] * (rewardPerShare - paid) / REWARD_PRECISION;
        }
        return stored;
    }

    function positionOf(uint256 tokenId)
        external
        view
        returns (uint256 allocation, uint256 pending, uint64 currentValidatorId)
    {
        allocation = _vaultStorage().balanceOf[tokenId];
        pending = _vaultStorage().pendingWithdrawal[tokenId];
        currentValidatorId = _vaultStorage().currentValidatorId;
    }

    function tokenIds() external view returns (uint256[] memory) {
        return _vaultStorage().tokenIds.values();
    }

    /// @notice Accounts deposits and uses the validator escrow submission to activate the validator.
    /// @dev The controller caps the value forwarded here. The vault itself also
    ///      enforces the cap so it can never overfund validator creation.
    function deposit(uint256 tokenId) external payable onlyController returns (uint64 currentValidatorId) {
        if (msg.value == 0 || (_vaultStorage().currentValidatorId == 0 && deficit() < msg.value)) {
            revert InvalidAmount();
        }

        _updateReward(tokenId);

        _vaultStorage().tokenIds.add(tokenId);
        _vaultStorage().balanceOf[tokenId] += msg.value;
        _vaultStorage().totalBalance += msg.value;

        if (deficit() != 0) return _vaultStorage().currentValidatorId;

        if (_vaultStorage().currentValidatorId != 0) {
            if (!STAKING.delegate{value: msg.value}(_vaultStorage().currentValidatorId)) revert StakingCallFailed();
        } else {
            IVeValidator.ValidatorSubmission memory submission =
                _vaultStorage().validatorVe.validatorSubmission(_vaultStorage().validatorTokenId);
            _vaultStorage().currentValidatorId = STAKING.addValidator{value: availableBalance()}(
                submission.payload, submission.signedSecpMessage, submission.signedBlsMessage
            );
            if (_vaultStorage().currentValidatorId == 0) revert AddValidatorFailed();
        }
        return _vaultStorage().currentValidatorId;
    }

    /// @notice Begin withdrawing part of a token's active allocation.
    /// @dev The withdrawal slot is shared by the vault. A later token can be
    ///      credited from the same redeemed balance once the first request is
    ///      finalized; Monad does not need one precompile slot per token.
    function undelegate(uint256 tokenId, uint256 amount) external onlyController {
        if (_vaultStorage().currentValidatorId == 0 || amount == 0 || _vaultStorage().balanceOf[tokenId] < amount) {
            revert InvalidAmount();
        }
        if (_vaultStorage().pendingWithdrawal[tokenId] != 0) revert InvalidAmount();
        if (availableBalance() != _vaultStorage().rewardReserve) revert InvalidAmount();
        _updateReward(tokenId);
        if (!STAKING.undelegate(_vaultStorage().currentValidatorId, amount, WITHDRAW_ID)) {
            revert UndelegationFailed();
        }
        _vaultStorage().balanceOf[tokenId] -= amount;
        _vaultStorage().totalBalance -= amount;
        _vaultStorage().pendingWithdrawal[tokenId] = amount;
        if (_vaultStorage().balanceOf[tokenId] == 0) _vaultStorage().tokenIds.remove(tokenId);
    }

    /// @notice Return liquid pre-activation funds or finalize a matured validator withdrawal.
    /// @dev For unregistered validators, the amount is returned from the vault's
    ///      liquid balance. Registered validator withdrawals use the matured
    ///      precompile withdrawal request.
    function withdraw(uint256 tokenId, uint256 amount) external onlyController returns (uint256) {
        if (amount == 0) revert InvalidAmount();

        if (_vaultStorage().currentValidatorId == 0) {
            if (_vaultStorage().balanceOf[tokenId] < amount) revert InvalidAmount();
            if (availableBalance() < _vaultStorage().totalBalance + _vaultStorage().rewardReserve) {
                revert InvalidAmount();
            }

            _vaultStorage().balanceOf[tokenId] -= amount;
            _vaultStorage().totalBalance -= amount;
            if (_vaultStorage().balanceOf[tokenId] == 0) _vaultStorage().tokenIds.remove(tokenId);
        } else {
            if (_vaultStorage().pendingWithdrawal[tokenId] != amount) revert InvalidAmount();
            if (availableBalance() - _vaultStorage().rewardReserve < amount) {
                if (!STAKING.withdraw(_vaultStorage().currentValidatorId, WITHDRAW_ID)) return 0;
            }
            delete _vaultStorage().pendingWithdrawal[tokenId];
        }

        (bool success,) = payable(controller()).call{value: amount}("");
        if (!success) revert TransferFailed();
        return amount;
    }

    /// @notice Claim a single veMON position's accrued MON rewards.
    function claimReward(uint256 tokenId, address recipient) external onlyController returns (uint256 amount) {
        if (_vaultStorage().currentValidatorId == 0) revert ValidatorNotAdded();
        if (recipient == address(0)) revert InvalidRecipient();

        _updateReward(tokenId);
        uint256 trackedRewards = _vaultStorage().accountedUnclaimedRewards;
        uint256 claimedRewards = _claimRewardsRaw(_vaultStorage().currentValidatorId);
        _vaultStorage().rewardReserve += claimedRewards > trackedRewards ? claimedRewards : trackedRewards;
        _vaultStorage().accountedUnclaimedRewards = 0;

        amount = _vaultStorage().rewards[tokenId];
        if (amount == 0) return 0;
        if (amount > _vaultStorage().rewardReserve || availableBalance() < amount) {
            revert InsufficientRewardLiquidity();
        }
        delete _vaultStorage().rewards[tokenId];
        _vaultStorage().rewardReserve -= amount;

        (bool success,) = payable(recipient).call{value: amount}("");
        if (!success) revert RewardTransferFailed();
        emit RewardPaid(tokenId, recipient, amount);
    }

    function _updateReward(uint256 tokenId) internal {
        _syncRewards();
        uint256 rewardPerShare = _vaultStorage().rewardPerShareStored;
        uint256 paid = _vaultStorage().userRewardPerSharePaid[tokenId];
        if (rewardPerShare > paid) {
            _vaultStorage().rewards[tokenId] += _vaultStorage().balanceOf[tokenId] * (rewardPerShare - paid)
            / REWARD_PRECISION;
        }
        _vaultStorage().userRewardPerSharePaid[tokenId] = rewardPerShare;
    }

    /// @dev Reads the vault delegator's precompile reward state and accounts
    ///      only the increase since the previous synchronization.
    function _syncRewards() internal {
        if (_vaultStorage().currentValidatorId == 0 || _vaultStorage().totalBalance == 0) return;
        // The precompile returns the complete tuple; only unclaimed rewards are relevant here.
        // forge-lint: disable-next-line(unused-return)
        (,, uint256 unclaimedRewards,,,,) = STAKING.getDelegator(_vaultStorage().currentValidatorId, address(this));

        uint256 newlyAccrued = 0;
        if (unclaimedRewards > _vaultStorage().accountedUnclaimedRewards) {
            newlyAccrued = unclaimedRewards - _vaultStorage().accountedUnclaimedRewards;
        }
        _vaultStorage().accountedUnclaimedRewards = unclaimedRewards;

        if (newlyAccrued != 0) {
            _vaultStorage().rewardPerShareStored += newlyAccrued * REWARD_PRECISION / _vaultStorage().totalBalance;
            emit RewardsSynced(newlyAccrued, _vaultStorage().rewardPerShareStored);
        }
    }

    receive() external payable {
        if (msg.sender != address(STAKING)) revert UnexpectedEtherSender();
    }
}
