// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {BoostLibrary} from "./libraries/BoostLibrary.sol";
import {ProtocolTimeLibrary} from "./libraries/ProtocolTimeLibrary.sol";
import {SafeCastLibrary} from "./libraries/SafeCastLibrary.sol";

/// @title VotingEscrow
/// @notice Abstract veNFT escrow implementation for Quevra voting power.
/// @dev Power follows veBTC's linear bias/slope model, measured in Monad epochs.
///      Time-limited locks are specified in Quevra cycles and expire on cycle boundaries.
abstract contract VotingEscrow is ERC721, ReentrancyGuardTransient, IVotingEscrow {
    using SafeCastLibrary for uint256;
    using SafeCastLibrary for int128;
    uint64 public immutable maxLockCycles;
    uint64 public immutable override maxLockEpochs;
    address public immutable override controller;
    address public immutable override voter;

    struct Point {
        int128 bias;
        int128 slope;
        uint64 epoch;
        uint256 permanentBalance;
    }

    uint256 public nextId = 1;

    struct LockData {
        uint256 end;
        bool isPermanent;
        uint256 boost;
    }

    mapping(uint256 tokenId => LockData lock) internal _lockData;
    uint256 public override epoch;
    mapping(uint256 index => Point) public pointHistory;
    mapping(uint256 tokenId => Point[]) private _userPointHistory;
    mapping(uint64 unlockEpoch => int128 slopeChange) public slopeChanges;
    mapping(uint256 tokenId => uint256 blockNumber) public ownershipChange;
    uint256 public override permanentLockBalance;

    error InvalidAmount();
    error NonexistentToken();
    error EpochOutOfRange();
    event LockAmountIncreased(uint256 indexed tokenId, uint256 amount, uint256 newAmount);
    event LockAmountDecreased(uint256 indexed tokenId, uint256 amount, uint256 newAmount);
    event Checkpoint(uint64 indexed epoch, uint256 indexed pointIndex);

    constructor(uint64 maxLockCycles_, string memory name_, string memory symbol_, address controller_, address voter_)
        ERC721(name_, symbol_)
    {
        if (maxLockCycles_ == 0) revert LockDurationNotInFuture();
        maxLockCycles = maxLockCycles_;
        maxLockEpochs = maxLockCycles_ * ProtocolTimeLibrary.EPOCHS_PER_CYCLE;
        controller = controller_;
        voter = voter_;
    }

    /// @notice Checkpoint a controller-owned principal change for voting power.
    function syncAmountFromController(uint256 tokenId, uint256 oldAmount, uint256 newAmount)
        external
        override
        nonReentrant
    {
        _requireController();
        if (_ownerOf(tokenId) == address(0)) revert NonexistentToken();
        uint256 maxAmount = uint256(uint128(type(int128).max));
        if (oldAmount == newAmount || newAmount != _amountOf(tokenId).toUint256() || newAmount > maxAmount) {
            revert InvalidAmount();
        }

        LockData memory lock = _lockData[tokenId];
        _checkpointAmount(tokenId, oldAmount, newAmount, lock);
        if (newAmount > oldAmount) {
            emit LockAmountIncreased(tokenId, newAmount - oldAmount, newAmount);
        } else {
            emit LockAmountDecreased(tokenId, oldAmount - newAmount, newAmount);
        }
    }

    /// @dev The escrow reads principal from its concrete accounting source and keeps lock metadata/history.
    function _amountOf(uint256 tokenId) internal view virtual returns (int128);

    function _requireController() internal view {
        if (msg.sender != controller) revert NotController();
    }

    /// @dev Custody implementation supplied by the concrete escrow. The lock
    ///      accounting is token agnostic; concrete escrows define custody and accounting.
    /// @notice Advances global voting-power checkpoints to the current staking epoch.
    function checkpoint() external override nonReentrant {
        (uint64 currentEpoch,) = ProtocolTimeLibrary.currentEpoch();
        _advanceGlobal(currentEpoch);
    }

    function votingPowerOf(uint256 tokenId) external view override returns (uint256) {
        if (ownershipChange[tokenId] == block.number) return 0;
        // The staking epoch precompile is CALL-only, so view methods use the latest checkpoint.
        return BoostLibrary.boostedAmount(
            _votingPowerOfAt(tokenId, uint64(pointHistory[epoch].epoch)), _lockData[tokenId].boost
        );
    }

    function votingPowerAndLockedAmount(uint256 tokenId) external view override returns (uint256 power, int128 amount) {
        amount = _amountOf(tokenId);
        if (ownershipChange[tokenId] == block.number) return (0, amount);
        power = BoostLibrary.boostedAmount(
            _votingPowerOfAt(tokenId, uint64(pointHistory[epoch].epoch)), _lockData[tokenId].boost
        );
    }

    function votingPowerOfAt(uint256 tokenId, uint256 targetEpoch) external view override returns (uint256) {
        if (targetEpoch > type(uint64).max) revert EpochOutOfRange();
        return BoostLibrary.boostedAmount(_votingPowerOfAt(tokenId, uint64(targetEpoch)), _lockData[tokenId].boost);
    }

    function totalVotingPower() external view override returns (uint256) {
        return _totalVotingPowerAt(pointHistory[epoch].epoch);
    }

    function totalVotingPowerAt(uint256 targetEpoch) external view override returns (uint256) {
        if (targetEpoch > type(uint64).max) revert EpochOutOfRange();
        return _totalVotingPowerAt(uint64(targetEpoch));
    }

    function unboostedVotingPowerOf(uint256 tokenId) external view override returns (uint256) {
        if (ownershipChange[tokenId] == block.number) return 0;
        return _votingPowerOfAt(tokenId, uint64(pointHistory[epoch].epoch));
    }

    function unboostedTotalVotingPower() external view override returns (uint256) {
        return _totalVotingPowerAt(pointHistory[epoch].epoch);
    }

    function updateBoost(uint256 tokenId, uint256 boost) external override {
        if (msg.sender != voter) revert NotVoter();
        if (_ownerOf(tokenId) == address(0)) revert NonexistentToken();
        if (boost < BoostLibrary.PRECISION || boost > 5 * BoostLibrary.PRECISION) revert InvalidAmount();
        _lockData[tokenId].boost = boost;
    }

    function userPointEpoch(uint256 tokenId) external view override returns (uint256) {
        return _userPointHistory[tokenId].length;
    }

    function locked(uint256 tokenId)
        external
        view
        override
        returns (int128 amount, uint256 end, bool isPermanent, uint256 boost)
    {
        LockData memory lock = _lockData[tokenId];
        return (_amountOf(tokenId), lock.end, lock.isPermanent, lock.boost);
    }

    function userPointHistory(uint256 tokenId, uint256 index) external view returns (Point memory) {
        return _userPointHistory[tokenId][index];
    }

    function isApprovedOrOwner(address spender, uint256 tokenId) external view override returns (bool) {
        address tokenOwner = _ownerOf(tokenId);
        return tokenOwner != address(0)
            && (spender == tokenOwner || spender == getApproved(tokenId) || isApprovedForAll(tokenOwner, spender));
    }

    function _checkpointLock(
        uint256 tokenId,
        IVotingEscrow.LockedBalance memory oldLock,
        IVotingEscrow.LockedBalance memory newLock
    ) internal {
        (uint64 currentEpoch,) = ProtocolTimeLibrary.currentEpoch();
        _advanceGlobal(currentEpoch);

        Point memory oldPoint = _lockPoint(oldLock, currentEpoch);
        Point memory newPoint = _lockPoint(newLock, currentEpoch);
        Point storage globalPoint = pointHistory[epoch];
        if (oldLock.isPermanent) {
            uint256 amount = oldLock.amount.toUint256();
            permanentLockBalance -= amount;
            globalPoint.permanentBalance -= amount;
        }
        if (newLock.isPermanent) {
            uint256 amount = newLock.amount.toUint256();
            permanentLockBalance += amount;
            globalPoint.permanentBalance += amount;
        }
        globalPoint.bias += newPoint.bias - oldPoint.bias;
        globalPoint.slope += newPoint.slope - oldPoint.slope;
        if (globalPoint.bias < 0) globalPoint.bias = 0;
        if (globalPoint.slope < 0) globalPoint.slope = 0;

        if (oldLock.end > currentEpoch) slopeChanges[uint64(oldLock.end)] += oldPoint.slope;
        if (newLock.end > currentEpoch) slopeChanges[uint64(newLock.end)] -= newPoint.slope;

        newPoint.epoch = currentEpoch;
        _userPointHistory[tokenId].push(newPoint);
        _recordGlobal(pointHistory[epoch]);
    }

    function _checkpointAmount(uint256 tokenId, uint256 oldAmount, uint256 newAmount, LockData memory lock) internal {
        IVotingEscrow.LockedBalance memory oldBalance =
            IVotingEscrow.LockedBalance(oldAmount.toInt128(), lock.end, lock.isPermanent, lock.boost);
        IVotingEscrow.LockedBalance memory newBalance =
            IVotingEscrow.LockedBalance(newAmount.toInt128(), lock.end, lock.isPermanent, lock.boost);
        _checkpointLock(tokenId, oldBalance, newBalance);
    }

    function _advanceGlobal(uint64 targetEpoch) private {
        if (epoch == 0) {
            epoch = 1;
            pointHistory[1] = Point(0, 0, targetEpoch, 0);
            emit Checkpoint(targetEpoch, 1);
            return;
        }

        Point memory point = pointHistory[epoch];
        while (point.epoch < targetEpoch) {
            unchecked {
                ++point.epoch;
            }
            point.bias -= point.slope;
            if (point.bias < 0) point.bias = 0;
            point.slope += slopeChanges[point.epoch];
            if (point.slope < 0) point.slope = 0;
            _recordGlobal(point);
        }
    }

    function _recordGlobal(Point memory point) private {
        if (epoch != 0 && pointHistory[epoch].epoch == point.epoch) {
            pointHistory[epoch] = point;
        } else {
            pointHistory[++epoch] = point;
        }
        emit Checkpoint(point.epoch, epoch);
    }

    function _lockPoint(IVotingEscrow.LockedBalance memory lock, uint64 atEpoch)
        private
        view
        returns (Point memory point)
    {
        if (lock.amount <= 0) return Point(0, 0, atEpoch, 0);
        if (lock.isPermanent) {
            return Point(lock.amount, 0, atEpoch, lock.amount.toUint256());
        }
        if (lock.end <= atEpoch) return Point(0, 0, atEpoch, 0);
        point.slope = lock.amount / int128(uint128(maxLockEpochs));
        point.bias = point.slope * int128(uint128(lock.end - atEpoch));
        point.epoch = atEpoch;
    }

    function _votingPowerOfAt(uint256 tokenId, uint64 targetEpoch) private view returns (uint256) {
        Point[] storage history = _userPointHistory[tokenId];
        uint256 length = history.length;
        if (length == 0) return 0;
        uint256 low = 0;
        uint256 high = length;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (history[mid].epoch <= targetEpoch) low = mid + 1;
            else high = mid;
        }
        if (low == 0) return 0;
        Point memory point = history[low - 1];
        if (targetEpoch <= point.epoch) return point.bias.toUint256();
        if (targetEpoch - point.epoch >= maxLockEpochs) {
            return point.slope == 0 ? point.bias.toUint256() : 0;
        }
        int128 decayed = point.bias - point.slope * int128(uint128(targetEpoch - point.epoch));
        return decayed > 0 ? decayed.toUint256() : 0;
    }

    function _totalVotingPowerAt(uint64 targetEpoch) private view returns (uint256) {
        uint256 low = 1;
        uint256 high = epoch + 1;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (pointHistory[mid].epoch <= targetEpoch) low = mid + 1;
            else high = mid;
        }
        if (low == 1) return 0;
        Point memory point = pointHistory[low - 1];
        if (targetEpoch - point.epoch >= maxLockEpochs) return point.permanentBalance;
        uint64 cursor = point.epoch;
        while (cursor < targetEpoch) {
            unchecked {
                ++cursor;
            }
            point.bias -= point.slope;
            if (point.bias < 0) point.bias = 0;
            point.slope += slopeChanges[cursor];
            if (point.slope < 0) point.slope = 0;
        }
        return point.bias > 0 ? point.bias.toUint256() : 0;
    }

    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (from != address(0) && to != address(0)) ownershipChange[tokenId] = block.number;
    }
}
