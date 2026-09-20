// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";

interface IVotingEscrow is IERC721Metadata {
    /// @notice Structure containing foundational properties of a locked balance (veNFT).
    struct LockedBalance {
        /// @notice The physical amount of tokens locked.
        int128 amount;
        /// @notice The Monad epoch when the lock expires.
        uint256 end;
        /// @notice Flag indicating if the lock is permanent.
        ///         When true, all tokens in the veNFT are permanently locked.
        ///         Permanent locks apply to the entire amount - there is no way
        ///         to lock permanently just a portion of tokens from the veNFT.
        bool isPermanent;
        /// @notice The boost value stored with the lock.
        uint256 boost;
    }

    /// @dev Different types of veNFTs:
    /// NORMAL  - typical veNFT
    /// LOCKED  - veNFT which is locked into a MANAGED veNFT
    /// MANAGED - veNFT which can accept the deposit of NORMAL veNFTs
    enum EscrowType {
        NORMAL,
        LOCKED,
        MANAGED
    }

    error InvalidManagedNFTId();
    error LockDurationNotInFuture();
    error LockDurationTooLong();
    error LockExpired();
    error NotApprovedOrOwner();
    error NotManagedNFT();
    error NotLockedNFT();
    error NotNormalNFT();
    error NotPermanentLock();
    error PermanentLock();

    /// @dev Mapping of token id to escrow type
    ///      Takes advantage of the fact default value is EscrowType.NORMAL
    function escrowType(uint256 tokenId) external view returns (EscrowType);

    /// @dev Mapping of token id to managed id
    function idToManaged(uint256 tokenId) external view returns (uint256 managedTokenId);

    /// @dev Mapping of user token id to managed token id to weight of token id
    function weights(uint256 tokenId, uint256 managedTokenId) external view returns (uint256 weight);

    /// @notice Deposit a normal veNFT into a managed veNFT.
    /// @param _tokenId Id of the depositing veNFT.
    /// @param _mTokenId Id of the managed veNFT.
    function depositManaged(uint256 _tokenId, uint256 _mTokenId) external;

    /// @notice Withdraw a veNFT from its managed position and re-lock it for the maximum duration.
    function withdrawManaged(uint256 _tokenId) external;

    /// @notice Check whether spender is owner or an approved user for a given veNFT
    /// @param _spender .
    /// @param _tokenId .
    function isApprovedOrOwner(address _spender, uint256 _tokenId) external view returns (bool);

    /// @notice Index of the latest global voting-power checkpoint.
    function epoch() external view returns (uint256);

    /// @notice Summarized voting power of all permanently locked veNFTs.
    ///         For example, if there are 3 veNFTs with 100 tokens each,
    ///         and 2 of them are permanently locked, the permanentLockBalance
    ///         will be 200.
    function permanentLockBalance() external view returns (uint256);

    function userPointEpoch(uint256 _tokenId) external view returns (uint256 _epoch);

    /// @notice Get the LockedBalance (amount, end) of a _tokenId
    /// @param _tokenId .
    /// @return amount The locked MON amount.
    /// @return end The Monad epoch when the lock expires.
    /// @return isPermanent Whether the position is permanently locked.
    /// @return boost The stored boost.
    function locked(uint256 _tokenId)
        external
        view
        returns (int128 amount, uint256 end, bool isPermanent, uint256 boost);

    /// @notice Record global data to checkpoint
    function checkpoint() external;

    /// @notice Create a veNFT for `msg.sender`.
    /// @param _value Amount to lock.
    /// @param _lockDuration Lock duration in Quevra cycles.
    /// @return TokenId of the created veNFT.
    function createLock(uint256 _value, uint256 _lockDuration) external payable returns (uint256);

    /// @notice Permanently lock a normal veNFT.
    function lockPermanent(uint256 _tokenId) external;

    /// @notice Return a permanently locked veNFT to a time-limited lock.
    function unlockPermanent(uint256 _tokenId) external;

    /// @notice Calculate total voting power at the current Monad epoch.
    function totalVotingPower() external view returns (uint256);

    /// @notice Calculate total voting power at a given Monad epoch.
    /// @param _t Monad epoch to query.
    function totalVotingPowerAt(uint256 _t) external view returns (uint256);

    /// @notice Voting power in Quevra units for a veNFT at the latest checkpoint.
    function votingPowerOf(uint256 tokenId) external view returns (uint256);

    function votingPowerOfAt(uint256 tokenId, uint256 epoch) external view returns (uint256);
}
