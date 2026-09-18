// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IVeMON} from "../interfaces/IVeMON.sol";
import {IWMON} from "../interfaces/IWMON.sol";
import {IMonVault} from "../interfaces/IMonVault.sol";
import {VotingPower} from "../libraries/VotingPower.sol";

/// @title VeMON
/// @notice ERC-721 vote-escrow over canonical WMON. Never holds WMON; MonVault is custodian.
contract VeMON is Ownable2Step, ReentrancyGuardTransient, ERC721, IVeMON {
    using SafeERC20 for IERC20;

    IWMON public immutable wmon;
    address public immutable override vault;
    uint256 public immutable override maxLockTime;
    address public immutable override voter;

    uint256 public override supply;
    uint256 public lastId;

    mapping(uint256 tokenId => LockedBalance) internal _locked;
    mapping(uint256 tokenId => bool) public override voted;

    constructor(address owner_, address wmon_, address vault_, address voter_, uint256 maxLockTime_)
        Ownable(owner_)
        ERC721("veMON", "veMON")
    {
        if (wmon_ == address(0) || vault_ == address(0) || voter_ == address(0)) revert ZeroAddress();
        if (maxLockTime_ == 0) revert MaxLockTooShort();

        wmon = IWMON(wmon_);
        vault = vault_;
        voter = voter_;
        maxLockTime = maxLockTime_;
    }

    function renounceOwnership() public pure override {
        revert OwnableInvalidOwner(address(0));
    }

    function token() external view override returns (address) {
        return address(wmon);
    }

    function locked(uint256 tokenId) external view override returns (LockedBalance memory) {
        return _locked[tokenId];
    }

    function isApprovedOrOwner(address spender, uint256 tokenId) public view override returns (bool) {
        address owner_ = _ownerOf(tokenId);
        return _isAuthorized(owner_, spender, tokenId);
    }

    function votingPowerOfNFT(uint256 tokenId) public view override returns (uint256) {
        return votingPowerOfNFTAt(tokenId, block.timestamp);
    }

    function votingPowerOfNFTAt(uint256 tokenId, uint256 timestamp) public view override returns (uint256) {
        LockedBalance memory lock = _locked[tokenId];
        return VotingPower.votingPower(lock.amount, lock.end, timestamp, maxLockTime);
    }

    function totalVotingPower() external view override returns (uint256) {
        return totalVotingPowerAt(block.timestamp);
    }

    function totalVotingPowerAt(uint256 timestamp) public view override returns (uint256 total) {
        uint256 n = lastId;
        for (uint256 i = 1; i <= n; ++i) {
            total += votingPowerOfNFTAt(i, timestamp);
        }
    }

    function voting(uint256 tokenId, bool voted_) external override {
        if (msg.sender != voter) revert NotVoter();
        if (_ownerOf(tokenId) == address(0)) revert NoLockFound();
        voted[tokenId] = voted_;
    }

    function createLock(uint256 value, uint256 duration) external override nonReentrant returns (uint256 tokenId) {
        tokenId = _mintLock(msg.sender, value, duration);
        IERC20(address(wmon)).safeTransferFrom(msg.sender, vault, value);
        IMonVault(vault).onLock(value);
    }

    function createLockNative(uint256 duration) external payable override nonReentrant returns (uint256 tokenId) {
        uint256 value = msg.value;
        tokenId = _mintLock(msg.sender, value, duration);
        wmon.deposit{value: value}();
        IERC20(address(wmon)).safeTransfer(vault, value);
        IMonVault(vault).onLock(value);
    }

    function increaseAmount(uint256 tokenId, uint256 value) external override nonReentrant {
        _increaseAmount(tokenId, value);
        IERC20(address(wmon)).safeTransferFrom(msg.sender, vault, value);
        IMonVault(vault).onLock(value);
    }

    function increaseAmountNative(uint256 tokenId) external payable override nonReentrant {
        uint256 value = msg.value;
        _increaseAmount(tokenId, value);
        wmon.deposit{value: value}();
        IERC20(address(wmon)).safeTransfer(vault, value);
        IMonVault(vault).onLock(value);
    }

    function depositFor(uint256 tokenId, uint256 value) external override nonReentrant {
        _increaseAmountFor(tokenId, value);
        IERC20(address(wmon)).safeTransferFrom(msg.sender, vault, value);
        IMonVault(vault).onLock(value);
    }

    function increaseUnlockTime(uint256 tokenId, uint256 duration) external override nonReentrant {
        if (!isApprovedOrOwner(msg.sender, tokenId)) revert NotApprovedOrOwner();
        if (voted[tokenId]) revert AlreadyVoted();

        LockedBalance memory lock = _locked[tokenId];
        if (lock.amount == 0) revert NoLockFound();
        if (block.timestamp >= lock.end) revert LockExpired();

        uint256 newEnd = _endTime(duration);
        if (newEnd <= lock.end) revert LockDurationNotInFuture();

        lock.end = newEnd;
        _locked[tokenId] = lock;

        emit Deposit(msg.sender, tokenId, 0, newEnd, block.timestamp);
    }

    function withdraw(uint256 tokenId) external override nonReentrant {
        if (!isApprovedOrOwner(msg.sender, tokenId)) revert NotApprovedOrOwner();
        if (voted[tokenId]) revert AlreadyVoted();

        LockedBalance memory lock = _locked[tokenId];
        if (lock.amount == 0) revert NoLockFound();
        if (block.timestamp < lock.end) revert LockNotExpired();

        address owner_ = ownerOf(tokenId);
        uint256 value = lock.amount;
        uint256 prev = supply;

        IMonVault(vault).onUnlock(owner_, value);

        delete _locked[tokenId];
        supply = prev - value;
        _burn(tokenId);

        emit Withdraw(owner_, tokenId, value, block.timestamp);
        emit Supply(prev, supply);
    }

    function _mintLock(address to, uint256 value, uint256 duration) internal returns (uint256 tokenId) {
        if (value == 0) revert ZeroAmount();
        uint256 end = _endTime(duration);
        tokenId = ++lastId;

        uint256 prev = supply;
        _locked[tokenId] = LockedBalance({amount: value, end: end});
        supply = prev + value;
        _mint(to, tokenId);

        emit Deposit(to, tokenId, value, end, block.timestamp);
        emit Supply(prev, supply);
    }

    function _increaseAmount(uint256 tokenId, uint256 value) internal {
        if (!isApprovedOrOwner(msg.sender, tokenId)) revert NotApprovedOrOwner();
        _increaseAmountFor(tokenId, value);
    }

    function _increaseAmountFor(uint256 tokenId, uint256 value) internal {
        if (value == 0) revert ZeroAmount();
        LockedBalance memory lock = _locked[tokenId];
        if (lock.amount == 0) revert NoLockFound();
        if (block.timestamp >= lock.end) revert LockExpired();

        uint256 prev = supply;
        lock.amount += value;
        _locked[tokenId] = lock;
        supply = prev + value;

        emit Deposit(msg.sender, tokenId, value, lock.end, block.timestamp);
        emit Supply(prev, supply);
    }

    function _endTime(uint256 duration) internal view returns (uint256 end) {
        if (duration == 0) revert LockDurationNotInFuture();
        if (duration > maxLockTime) revert LockDurationTooLong();
        end = block.timestamp + duration;
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0) && voted[tokenId]) revert AlreadyVoted();
        return super._update(to, tokenId, auth);
    }
}
