// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {ProtocolTimeLibrary} from "./libraries/ProtocolTimeLibrary.sol";

/// @title veMON
/// @notice ERC721 receipt for MON routed into validator staking.
/// @dev Power follows veBTC's linear bias/slope model, measured in Monad epochs.
///      veBTC delegation is limited to permanent locks; veMON has no permanent-lock operation,
///      so this contract does not add delegated-balance accounting.
contract VeMON is ERC721, ReentrancyGuardTransient {
    uint64 public constant MAX_LOCK_CYCLES = 4;
    uint64 public constant MAX_LOCK_EPOCHS = MAX_LOCK_CYCLES * ProtocolTimeLibrary.EPOCHS_PER_CYCLE;

    struct Point {
        int128 bias;
        int128 slope;
        uint64 epoch;
    }

    address public immutable controller;
    uint256 public nextId = 1;

    mapping(uint256 tokenId => IVotingEscrow.LockedBalance lock) public locked;
    uint256 public epoch;
    mapping(uint256 index => Point) public pointHistory;
    mapping(uint256 tokenId => Point[]) private _userPointHistory;
    mapping(uint64 unlockEpoch => int128 slopeChange) public slopeChanges;
    mapping(uint256 tokenId => uint256 blockNumber) public ownershipChange;

    error InvalidAddress();
    error InvalidAmount();
    error InvalidValue();
    error LockDurationNotInFuture();
    error LockDurationTooLong();
    error ForwardFailed();

    event LockCreated(uint256 indexed tokenId, address indexed account, uint256 amount, uint256 unlockEpoch);
    event Checkpoint(uint64 indexed epoch, uint256 indexed pointIndex);

    constructor(address controller_) ERC721("Locked MON", "veMON") {
        if (controller_ == address(0)) revert InvalidAddress();
        controller = controller_;
    }

    function createLock(uint256 _value, uint256 _lockDuration) external payable nonReentrant returns (uint256 tokenId) {
        uint256 unlockEpoch = _unlockEpoch(_lockDuration);
        if (_value == 0) revert InvalidAmount();
        if (msg.value != _value) revert InvalidValue();

        (bool success, bytes memory returndata) = controller.call{value: msg.value}("");
        if (!success) {
            if (returndata.length == 0) revert ForwardFailed();
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }

        tokenId = nextId++;
        IVotingEscrow.LockedBalance memory newLock =
            IVotingEscrow.LockedBalance(int128(int256(_value)), unlockEpoch, false, 0);
        locked[tokenId] = newLock;
        _checkpointLock(tokenId, IVotingEscrow.LockedBalance(0, 0, false, 0), newLock);
        emit LockCreated(tokenId, msg.sender, _value, unlockEpoch);

        _safeMint(msg.sender, tokenId);
    }

    /// @notice Advances global voting-power checkpoints to the current staking epoch.
    function checkpoint() external nonReentrant {
        (uint64 currentEpoch,) = ProtocolTimeLibrary.currentEpoch();
        _advanceGlobal(currentEpoch);
    }

    function balanceOfNFT(uint256 tokenId) external view returns (uint256) {
        if (ownershipChange[tokenId] == block.number) return 0;
        // The staking epoch precompile is CALL-only, so view methods use the latest checkpoint.
        return _balanceOfNFTAt(tokenId, uint64(pointHistory[epoch].epoch));
    }

    function balanceOfNFTAt(uint256 tokenId, uint256 targetEpoch) external view returns (uint256) {
        return _balanceOfNFTAt(tokenId, uint64(targetEpoch));
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupplyAt(pointHistory[epoch].epoch);
    }

    function totalSupplyAt(uint256 targetEpoch) external view returns (uint256) {
        return _totalSupplyAt(uint64(targetEpoch));
    }

    function userPointEpoch(uint256 tokenId) external view returns (uint256) {
        return _userPointHistory[tokenId].length;
    }

    function userPointHistory(uint256 tokenId, uint256 index) external view returns (Point memory) {
        return _userPointHistory[tokenId][index];
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
            pointHistory[1] = Point(0, 0, targetEpoch);
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
        pure
        returns (Point memory point)
    {
        if (lock.amount <= 0 || lock.end <= atEpoch) return Point(0, 0, atEpoch);
        point.slope = lock.amount / int128(uint128(MAX_LOCK_EPOCHS));
        point.bias = point.slope * int128(uint128(lock.end - atEpoch));
        point.epoch = atEpoch;
    }

    function _balanceOfNFTAt(uint256 tokenId, uint64 targetEpoch) private view returns (uint256) {
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
        if (targetEpoch - point.epoch >= MAX_LOCK_EPOCHS) return 0;
        int128 decayed = point.bias - point.slope * int128(uint128(targetEpoch - point.epoch));
        return decayed > 0 ? uint256(uint128(decayed)) : 0;
    }

    function _totalSupplyAt(uint64 targetEpoch) private view returns (uint256) {
        uint256 low = 1;
        uint256 high = epoch + 1;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (pointHistory[mid].epoch <= targetEpoch) low = mid + 1;
            else high = mid;
        }
        if (low == 1) return 0;
        Point memory point = pointHistory[low - 1];
        if (targetEpoch - point.epoch >= MAX_LOCK_EPOCHS) return 0;
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
        from = super._update(to, tokenId, auth);
        if (from != address(0) && to != address(0)) ownershipChange[tokenId] = block.number;
    }

    function _unlockEpoch(uint256 lockCycles) private returns (uint256 unlockEpoch) {
        if (lockCycles == 0) revert LockDurationNotInFuture();
        if (lockCycles > MAX_LOCK_CYCLES) revert LockDurationTooLong();

        (uint64 currentEpoch_,) = ProtocolTimeLibrary.currentEpoch();
        unlockEpoch =
            ProtocolTimeLibrary.cycleStart(currentEpoch_) + (lockCycles * ProtocolTimeLibrary.EPOCHS_PER_CYCLE);
        if (unlockEpoch <= currentEpoch_) {
            unlockEpoch += ProtocolTimeLibrary.EPOCHS_PER_CYCLE;
        }
    }
}
