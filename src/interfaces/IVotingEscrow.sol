// SPDX-License-Identifier: MIT
// Derived from Tigris IVotingEscrow.sol.
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

    error LockDurationNotInFuture();
    error NotVoter();
    error NotController();

    /// @notice Returns whether `spender` is the token owner or an approved account.
    function isApprovedOrOwner(address _spender, uint256 _tokenId) external view returns (bool);

    /// @notice Index of the latest global voting-power checkpoint.
    function epoch() external view returns (uint256);

    /// @notice Maximum finite lock duration, measured in Monad staking epochs.
    function maxLockEpochs() external view returns (uint64);

    /// @notice Controller authorized to reconcile principal changes and exit positions.
    function controller() external view returns (address);

    /// @notice Summarized voting power of all permanently locked veNFTs.
    ///         For example, if there are 3 veNFTs with 100 tokens each,
    ///         and 2 of them are permanently locked, the permanentLockBalance
    ///         will be 200.
    function permanentLockBalance() external view returns (uint256);

    /// @notice Number of voting-power checkpoints recorded for a token ID.
    function userPointEpoch(uint256 _tokenId) external view returns (uint256 _epoch);

    /// @notice Returns the locked principal, expiry epoch, permanent-lock flag, and boost for a token.
    /// @return amount The locked MON amount.
    /// @return end The Monad epoch when the lock expires.
    /// @return isPermanent Whether the position is permanently locked.
    /// @return boost The stored boost.
    function locked(uint256 _tokenId)
        external
        view
        returns (int128 amount, uint256 end, bool isPermanent, uint256 boost);

    /// @notice Advances global voting-power checkpoints to the current Monad staking epoch.
    function checkpoint() external;

    /// @notice Checkpoint a controller-owned principal change for voting power.
    /// @dev The escrow verifies `newAmount` against the controller's canonical balance.
    function syncAmountFromController(uint256 tokenId, uint256 oldAmount, uint256 newAmount) external;

    /// @notice Sets a token's voting-power multiplier through the configured voter.
    function updateBoost(uint256 tokenId, uint256 boost) external;
    /// @notice Voter authorized to update boosts and voting allocations.
    function voter() external view returns (address);

    /// @notice Returns the token's voting power without applying its stored boost.
    function unboostedVotingPowerOf(uint256 tokenId) external view returns (uint256);

    /// @notice Returns total voting power without applying token boosts.
    function unboostedTotalVotingPower() external view returns (uint256);

    /// @notice Returns total voting power at the latest global checkpoint.
    function totalVotingPower() external view returns (uint256);

    /// @notice Returns total voting power at a given Monad staking epoch.
    /// @param _t Monad staking epoch to query.
    function totalVotingPowerAt(uint256 _t) external view returns (uint256);

    /// @notice Returns a token's voting power at the latest global checkpoint.
    function votingPowerOf(uint256 tokenId) external view returns (uint256);

    /// @notice Returns the token's latest voting power and locked principal amount.
    function votingPowerAndLockedAmount(uint256 tokenId) external view returns (uint256 power, int128 amount);

    /// @notice Returns a token's voting power at a specified Monad staking epoch.
    function votingPowerOfAt(uint256 tokenId, uint256 epoch) external view returns (uint256);
}
