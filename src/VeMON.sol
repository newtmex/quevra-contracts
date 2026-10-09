// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VotingEscrow} from "./VotingEscrow.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IStakingController} from "./interfaces/IStakingController.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {ProtocolTimeLibrary} from "./libraries/ProtocolTimeLibrary.sol";
import {SafeCastLibrary} from "./libraries/SafeCastLibrary.sol";

/// @title veMON
/// @notice Quevra voting escrow for MON routed into validator staking.
/// @dev Concrete deployment wrapper around the shared voting escrow implementation.
contract VeMON is VotingEscrow {
    using SafeCastLibrary for uint256;
    using SafeCastLibrary for int128;
    address public immutable controller;
    address public booster;

    error InvalidAddress();
    error InvalidValue();
    error NotController();
    error LockDurationTooLong();
    error LockExpired();
    error LockNotExpired();
    error NotApprovedOrOwner();
    error NotPermanentLock();
    error PermanentLock();
    event LockCreated(uint256 indexed tokenId, address indexed account, uint256 amount, uint256 unlockEpoch);
    event LockPermanent(address indexed account, uint256 indexed tokenId, uint256 amount, uint64 epoch);
    event UnlockPermanent(address indexed account, uint256 indexed tokenId, uint256 amount, uint64 epoch);
    event BoosterSet(address indexed booster);

    constructor(address controller_, uint64 maxLockCycles_) VotingEscrow(maxLockCycles_, "Locked MON", "veMON") {
        if (controller_ == address(0)) revert InvalidAddress();
        controller = controller_;
    }

    function createLock(uint256 value, uint256 lockDuration) external payable nonReentrant returns (uint256 tokenId) {
        uint256 unlockEpoch = _unlockEpoch(lockDuration);
        if (value == 0 || value > uint256(uint128(type(int128).max))) revert InvalidAmount();

        tokenId = nextId++;
        _deposit(value, tokenId);
        _lockData[tokenId] = LockData(unlockEpoch, false, 0);
        int128 principal = _amountOf(tokenId);
        if (principal.toUint256() != value) revert InvalidValue();
        _checkpointLock(
            tokenId,
            IVotingEscrow.LockedBalance(0, 0, false, 0),
            IVotingEscrow.LockedBalance(principal, unlockEpoch, false, 0)
        );
        emit LockCreated(tokenId, msg.sender, principal.toUint256(), unlockEpoch);
        _safeMint(msg.sender, tokenId);
    }

    function lockPermanent(uint256 tokenId) external nonReentrant {
        _requireApprovedOrOwner(msg.sender, tokenId);
        uint256 amount = uint256(uint128(_amountOf(tokenId)));
        LockData memory oldData = _lockData[tokenId];
        IVotingEscrow.LockedBalance memory oldLock =
            IVotingEscrow.LockedBalance(int128(uint128(amount)), oldData.end, oldData.isPermanent, oldData.boost);
        if (oldLock.isPermanent) revert PermanentLock();
        (uint64 currentEpoch,) = ProtocolTimeLibrary.currentEpoch();
        if (oldLock.end <= currentEpoch) revert LockExpired();

        IVotingEscrow.LockedBalance memory newLock = IVotingEscrow.LockedBalance(oldLock.amount, 0, true, oldLock.boost);
        _lockData[tokenId] = LockData(0, true, oldData.boost);
        _checkpointLock(tokenId, oldLock, newLock);
        emit LockPermanent(msg.sender, tokenId, newLock.amount.toUint256(), currentEpoch);
    }

    function unlockPermanent(uint256 tokenId) external nonReentrant {
        _requireApprovedOrOwner(msg.sender, tokenId);
        uint256 amount = uint256(uint128(_amountOf(tokenId)));
        LockData memory oldData = _lockData[tokenId];
        IVotingEscrow.LockedBalance memory oldLock =
            IVotingEscrow.LockedBalance(int128(uint128(amount)), oldData.end, oldData.isPermanent, oldData.boost);
        if (!oldLock.isPermanent) revert NotPermanentLock();

        uint64 currentEpoch = _currentEpoch();
        IVotingEscrow.LockedBalance memory newLock =
            IVotingEscrow.LockedBalance(oldLock.amount, _unlockEpoch(maxLockCycles), false, oldLock.boost);
        _lockData[tokenId] = LockData(newLock.end, false, oldData.boost);
        _checkpointLock(tokenId, oldLock, newLock);
        emit UnlockPermanent(msg.sender, tokenId, newLock.amount.toUint256(), currentEpoch);
    }

    function _deposit(uint256 amount, uint256 tokenId) internal {
        if (msg.value != amount) revert InvalidValue();

        IStakingController(controller).deposit{value: amount}(tokenId);
    }

    /// @notice Withdraw a fully unstaked position's MON and burn its veNFT.
    function withdraw(uint256 tokenId) external nonReentrant {
        _requireApprovedOrOwner(msg.sender, tokenId);

        if (_lockData[tokenId].isPermanent) revert PermanentLock();

        (uint64 currentEpoch,) = ProtocolTimeLibrary.currentEpoch();
        if (_lockData[tokenId].end > currentEpoch) revert LockNotExpired();

        // Withdrawal proceeds are forwarded to the controller and do not need to be read here.
        // forge-lint: disable-next-line(unused-return)
        IStakingController(controller).withdraw(tokenId);
        _burn(tokenId);
    }

    function _requireController() internal view override {
        if (msg.sender != controller) revert NotController();
    }

    function _amountOf(uint256 tokenId) internal view override returns (int128) {
        return uint256(IStakingController(controller).veMONPrincipalOf(tokenId)).toInt128();
    }

    function _requireApprovedOrOwner(address account, uint256 tokenId) internal view {
        address tokenOwner = _ownerOf(tokenId);
        if (tokenOwner == address(0)) revert NonexistentToken();
        if (account != tokenOwner && account != getApproved(tokenId) && !isApprovedForAll(tokenOwner, account)) {
            revert NotApprovedOrOwner();
        }
    }

    function _currentEpoch() internal returns (uint64 currentEpoch) {
        (currentEpoch,) = ProtocolTimeLibrary.currentEpoch();
    }

    function _unlockEpoch(uint256 lockCycles) internal returns (uint256 unlockEpoch) {
        if (lockCycles == 0) revert LockDurationNotInFuture();
        if (lockCycles > maxLockCycles) revert LockDurationTooLong();

        (uint64 currentEpoch_,) = ProtocolTimeLibrary.currentEpoch();
        unlockEpoch =
            ProtocolTimeLibrary.cycleStart(currentEpoch_) + (lockCycles * ProtocolTimeLibrary.EPOCHS_PER_CYCLE);
        if (unlockEpoch <= currentEpoch_) {
            unlockEpoch += ProtocolTimeLibrary.EPOCHS_PER_CYCLE;
        }
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = ERC721._update(to, tokenId, auth);
        if (from != address(0) && to != address(0)) ownershipChange[tokenId] = block.number;
    }

    function setBooster(address booster_) external {
        if (msg.sender != controller || booster != address(0) || booster_ == address(0)) revert NotController();
        booster = booster_;
        emit BoosterSet(booster_);
    }

    function _requireBooster() internal view override {
        if (msg.sender != controller && msg.sender != booster) revert NotController();
    }
}
