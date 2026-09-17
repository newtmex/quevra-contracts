// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IVeMON
/// @notice Vote-escrow NFT over canonical WMON. Principal is custodied by MonVault, not this contract.
interface IVeMON {
    struct LockedBalance {
        uint256 amount;
        uint256 end;
    }

    event Deposit(address indexed from, uint256 indexed tokenId, uint256 value, uint256 end, uint256 timestamp);
    event Withdraw(address indexed from, uint256 indexed tokenId, uint256 value, uint256 timestamp);
    event Supply(uint256 prev, uint256 next);
    event VoterSet(address voter);

    error ZeroAddress();
    error ZeroAmount();
    error LockDurationNotInFuture();
    error LockDurationTooLong();
    error LockExpired();
    error LockNotExpired();
    error NoLockFound();
    error AlreadyVoted();
    error NotApprovedOrOwner();
    error NotVoter();
    error MaxLockTooShort();

    function token() external view returns (address);
    function vault() external view returns (address);
    function voter() external view returns (address);
    function supply() external view returns (uint256);
    function maxLockTime() external view returns (uint256);
    function voted(uint256 tokenId) external view returns (bool);
    function locked(uint256 tokenId) external view returns (LockedBalance memory);

    function createLock(uint256 value, uint256 duration) external returns (uint256 tokenId);
    function createLockNative(uint256 duration) external payable returns (uint256 tokenId);
    function increaseAmount(uint256 tokenId, uint256 value) external;
    function increaseAmountNative(uint256 tokenId) external payable;
    function increaseUnlockTime(uint256 tokenId, uint256 duration) external;
    function withdraw(uint256 tokenId) external;
    function depositFor(uint256 tokenId, uint256 value) external;

    function voting(uint256 tokenId, bool voted_) external;
    function votingPowerOfNFT(uint256 tokenId) external view returns (uint256);
    function votingPowerOfNFTAt(uint256 tokenId, uint256 timestamp) external view returns (uint256);
    function totalVotingPower() external view returns (uint256);
    function totalVotingPowerAt(uint256 timestamp) external view returns (uint256);
    function isApprovedOrOwner(address spender, uint256 tokenId) external view returns (bool);

    function setVoter(address voter_) external;
}
