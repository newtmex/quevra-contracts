// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {ProtocolTimeLibrary} from "./libraries/ProtocolTimeLibrary.sol";

/// @title VotingEscrow
/// @notice Abstract veNFT escrow implementation for Quevra voting power.
/// @dev Power follows veBTC's linear bias/slope model, measured in Monad epochs.
///      Time-limited locks are specified in Quevra cycles and expire on cycle boundaries.
abstract contract VotingEscrow is ERC721, ReentrancyGuardTransient, IVotingEscrow {
    uint64 public immutable maxLockCycles;
    uint64 public immutable maxLockEpochs;

    struct Point {
        int128 bias;
        int128 slope;
        uint64 epoch;
        uint256 permanentBalance;
    }

    uint256 public nextId = 1;

    mapping(uint256 tokenId => IVotingEscrow.LockedBalance lock) private _locked;
    mapping(uint256 tokenId => IVotingEscrow.EscrowType) public override escrowType;
    mapping(uint256 tokenId => uint256 managedTokenId) public override idToManaged;
    mapping(uint256 tokenId => mapping(uint256 managedTokenId => uint256 amount)) public override weights;
    uint256 public override epoch;
    mapping(uint256 index => Point) public pointHistory;
    mapping(uint256 tokenId => Point[]) private _userPointHistory;
    mapping(uint64 unlockEpoch => int128 slopeChange) public slopeChanges;
    mapping(uint256 tokenId => uint256 blockNumber) public ownershipChange;
    uint256 public override permanentLockBalance;

    error InvalidAmount();
    error NonexistentToken();
    error PositionHasNoVotingPower();
    error ManagedPositionLocked();
    error EpochOutOfRange();
    event LockCreated(uint256 indexed tokenId, address indexed account, uint256 amount, uint256 unlockEpoch);
    event Checkpoint(uint64 indexed epoch, uint256 indexed pointIndex);
    event LockPermanent(address indexed account, uint256 indexed tokenId, uint256 amount, uint64 epoch);
    event UnlockPermanent(address indexed account, uint256 indexed tokenId, uint256 amount, uint64 epoch);
    event ManagedLockCreated(address indexed account, uint256 indexed tokenId);
    event DepositManaged(
        address indexed account, uint256 indexed tokenId, uint256 indexed managedTokenId, uint256 amount
    );
    event WithdrawManaged(
        address indexed account, uint256 indexed tokenId, uint256 indexed managedTokenId, uint256 amount
    );

    constructor(uint64 maxLockCycles_, string memory name_, string memory symbol_) ERC721(name_, symbol_) {
        if (maxLockCycles_ == 0) revert LockDurationNotInFuture();
        maxLockCycles = maxLockCycles_;
        maxLockEpochs = maxLockCycles_ * ProtocolTimeLibrary.EPOCHS_PER_CYCLE;
    }

    function createLock(uint256 _value, uint256 _lockDuration)
        external
        payable
        override
        nonReentrant
        returns (uint256 tokenId)
    {
        uint256 unlockEpoch = _unlockEpoch(_lockDuration);
        if (_value == 0) revert InvalidAmount();
        _deposit(_value);

        tokenId = nextId++;
        IVotingEscrow.LockedBalance memory newLock =
            IVotingEscrow.LockedBalance(int128(int256(_value)), unlockEpoch, false, 0);
        _locked[tokenId] = newLock;
        _checkpointLock(tokenId, IVotingEscrow.LockedBalance(0, 0, false, 0), newLock);
        emit LockCreated(tokenId, msg.sender, _value, unlockEpoch);

        _safeMint(msg.sender, tokenId);
    }

    /// @dev Custody implementation supplied by the concrete escrow. The lock
    ///      accounting is token agnostic; VeMON forwards MON to its controller.
    function _deposit(uint256 amount) internal virtual;

    function createManagedLock() external nonReentrant returns (uint256 tokenId) {
        tokenId = nextId++;
        IVotingEscrow.LockedBalance memory managedLock = IVotingEscrow.LockedBalance(0, 0, true, 0);
        _locked[tokenId] = managedLock;
        escrowType[tokenId] = IVotingEscrow.EscrowType.MANAGED;
        _checkpointLock(tokenId, IVotingEscrow.LockedBalance(0, 0, false, 0), managedLock);
        _mint(msg.sender, tokenId);
        emit ManagedLockCreated(msg.sender, tokenId);
    }

    function lockPermanent(uint256 tokenId) external override nonReentrant {
        _requireApprovedOrOwner(msg.sender, tokenId);
        if (escrowType[tokenId] != IVotingEscrow.EscrowType.NORMAL) revert NotNormalNFT();
        IVotingEscrow.LockedBalance memory oldLock = _locked[tokenId];
        if (oldLock.isPermanent) revert PermanentLock();
        (uint64 currentEpoch,) = ProtocolTimeLibrary.currentEpoch();
        if (oldLock.end <= currentEpoch) revert LockExpired();

        IVotingEscrow.LockedBalance memory newLock = IVotingEscrow.LockedBalance(oldLock.amount, 0, true, oldLock.boost);
        _checkpointLock(tokenId, oldLock, newLock);
        _locked[tokenId] = newLock;
        emit LockPermanent(msg.sender, tokenId, uint256(uint128(newLock.amount)), currentEpoch);
    }

    function unlockPermanent(uint256 tokenId) external override nonReentrant {
        _requireApprovedOrOwner(msg.sender, tokenId);
        if (escrowType[tokenId] != IVotingEscrow.EscrowType.NORMAL) revert NotNormalNFT();
        IVotingEscrow.LockedBalance memory oldLock = _locked[tokenId];
        if (!oldLock.isPermanent) revert NotPermanentLock();

        uint64 currentEpoch = _currentEpoch();
        IVotingEscrow.LockedBalance memory newLock =
            IVotingEscrow.LockedBalance(oldLock.amount, _unlockEpoch(maxLockCycles), false, oldLock.boost);
        _checkpointLock(tokenId, oldLock, newLock);
        _locked[tokenId] = newLock;
        emit UnlockPermanent(msg.sender, tokenId, uint256(uint128(newLock.amount)), currentEpoch);
    }

    function depositManaged(uint256 tokenId, uint256 managedTokenId) external override nonReentrant {
        _requireApprovedOrOwner(msg.sender, tokenId);
        if (escrowType[managedTokenId] != IVotingEscrow.EscrowType.MANAGED) revert NotManagedNFT();
        if (escrowType[tokenId] != IVotingEscrow.EscrowType.NORMAL) revert NotNormalNFT();

        uint64 currentEpoch = _currentEpoch();
        IVotingEscrow.LockedBalance memory userLock = _locked[tokenId];
        Point memory userPoint = _lockPoint(userLock, currentEpoch);
        if (userPoint.bias == 0) revert PositionHasNoVotingPower();
        uint256 amount = uint256(uint128(userLock.amount));

        IVotingEscrow.LockedBalance memory emptyLock = IVotingEscrow.LockedBalance(0, 0, false, 0);
        _checkpointLock(tokenId, userLock, emptyLock);
        _locked[tokenId] = emptyLock;

        IVotingEscrow.LockedBalance memory managedLock = _locked[managedTokenId];
        IVotingEscrow.LockedBalance memory newManagedLock = IVotingEscrow.LockedBalance(
            managedLock.amount + userLock.amount, managedLock.end, managedLock.isPermanent, managedLock.boost
        );
        _checkpointLock(managedTokenId, managedLock, newManagedLock);
        _locked[managedTokenId] = newManagedLock;

        weights[tokenId][managedTokenId] = amount;
        idToManaged[tokenId] = managedTokenId;
        escrowType[tokenId] = IVotingEscrow.EscrowType.LOCKED;
        emit DepositManaged(ownerOf(tokenId), tokenId, managedTokenId, amount);
    }

    function withdrawManaged(uint256 tokenId) external override nonReentrant {
        _requireApprovedOrOwner(msg.sender, tokenId);
        uint256 managedTokenId = idToManaged[tokenId];
        if (managedTokenId == 0) revert InvalidManagedNFTId();
        if (escrowType[tokenId] != IVotingEscrow.EscrowType.LOCKED) revert NotLockedNFT();

        uint256 amount = weights[tokenId][managedTokenId];
        IVotingEscrow.LockedBalance memory managedLock = _locked[managedTokenId];
        IVotingEscrow.LockedBalance memory newManagedLock = IVotingEscrow.LockedBalance(
            managedLock.amount - int128(int256(amount)), managedLock.end, managedLock.isPermanent, managedLock.boost
        );
        _checkpointLock(managedTokenId, managedLock, newManagedLock);
        _locked[managedTokenId] = newManagedLock;

        uint256 unlockEpoch = _unlockEpoch(maxLockCycles);
        IVotingEscrow.LockedBalance memory restoredLock =
            IVotingEscrow.LockedBalance(int128(int256(amount)), unlockEpoch, false, 0);
        IVotingEscrow.LockedBalance memory emptyLock = _locked[tokenId];
        _checkpointLock(tokenId, emptyLock, restoredLock);
        _locked[tokenId] = restoredLock;
        delete idToManaged[tokenId];
        delete weights[tokenId][managedTokenId];
        escrowType[tokenId] = IVotingEscrow.EscrowType.NORMAL;
        emit WithdrawManaged(ownerOf(tokenId), tokenId, managedTokenId, amount);
    }

    /// @notice Advances global voting-power checkpoints to the current staking epoch.
    function checkpoint() external override nonReentrant {
        (uint64 currentEpoch,) = ProtocolTimeLibrary.currentEpoch();
        _advanceGlobal(currentEpoch);
    }

    function votingPowerOf(uint256 tokenId) external view override returns (uint256) {
        if (ownershipChange[tokenId] == block.number) return 0;
        // The staking epoch precompile is CALL-only, so view methods use the latest checkpoint.
        return _votingPowerOfAt(tokenId, uint64(pointHistory[epoch].epoch));
    }

    function votingPowerOfAt(uint256 tokenId, uint256 targetEpoch) external view override returns (uint256) {
        if (targetEpoch > type(uint64).max) revert EpochOutOfRange();
        return _votingPowerOfAt(tokenId, uint64(targetEpoch));
    }

    function totalVotingPower() external view override returns (uint256) {
        return _totalVotingPowerAt(pointHistory[epoch].epoch);
    }

    function totalVotingPowerAt(uint256 targetEpoch) external view override returns (uint256) {
        if (targetEpoch > type(uint64).max) revert EpochOutOfRange();
        return _totalVotingPowerAt(uint64(targetEpoch));
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
        IVotingEscrow.LockedBalance memory balance = _locked[tokenId];
        return (balance.amount, balance.end, balance.isPermanent, balance.boost);
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
    ) private {
        (uint64 currentEpoch,) = ProtocolTimeLibrary.currentEpoch();
        _advanceGlobal(currentEpoch);

        Point memory oldPoint = _lockPoint(oldLock, currentEpoch);
        Point memory newPoint = _lockPoint(newLock, currentEpoch);
        Point storage globalPoint = pointHistory[epoch];
        if (oldLock.isPermanent) {
            uint256 amount = uint256(uint128(oldLock.amount));
            permanentLockBalance -= amount;
            globalPoint.permanentBalance -= amount;
        }
        if (newLock.isPermanent) {
            uint256 amount = uint256(uint128(newLock.amount));
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
            return Point(int128(uint128(lock.amount)), 0, atEpoch, uint256(uint128(lock.amount)));
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
        uint256 low;
        uint256 high = length;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (history[mid].epoch <= targetEpoch) low = mid + 1;
            else high = mid;
        }
        if (low == 0) return 0;
        Point memory point = history[low - 1];
        if (targetEpoch <= point.epoch) return uint256(uint128(point.bias));
        if (targetEpoch - point.epoch >= maxLockEpochs) {
            return point.slope == 0 ? uint256(uint128(point.bias)) : 0;
        }
        int128 decayed = point.bias - point.slope * int128(uint128(targetEpoch - point.epoch));
        return decayed > 0 ? uint256(uint128(decayed)) : 0;
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
        return point.bias > 0 ? uint256(uint128(point.bias)) : 0;
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        address currentOwner = _ownerOf(tokenId);
        if (currentOwner != address(0) && to != address(0)) {
            if (escrowType[tokenId] == IVotingEscrow.EscrowType.LOCKED) revert ManagedPositionLocked();
        }
        from = super._update(to, tokenId, auth);
        if (from != address(0) && to != address(0)) ownershipChange[tokenId] = block.number;
    }

    function _requireApprovedOrOwner(address account, uint256 tokenId) private view {
        address tokenOwner = _ownerOf(tokenId);
        if (tokenOwner == address(0)) revert NonexistentToken();
        if (account != tokenOwner && account != getApproved(tokenId) && !isApprovedForAll(tokenOwner, account)) {
            revert NotApprovedOrOwner();
        }
    }

    function _currentEpoch() private returns (uint64 currentEpoch) {
        (currentEpoch,) = ProtocolTimeLibrary.currentEpoch();
    }

    function _unlockEpoch(uint256 lockCycles) private returns (uint256 unlockEpoch) {
        if (lockCycles == 0) revert LockDurationNotInFuture();
        if (lockCycles > maxLockCycles) revert LockDurationTooLong();

        (uint64 currentEpoch_,) = ProtocolTimeLibrary.currentEpoch();
        unlockEpoch =
            ProtocolTimeLibrary.cycleStart(currentEpoch_) + (lockCycles * ProtocolTimeLibrary.EPOCHS_PER_CYCLE);
        if (unlockEpoch <= currentEpoch_) {
            unlockEpoch += ProtocolTimeLibrary.EPOCHS_PER_CYCLE;
        }
    }
}
