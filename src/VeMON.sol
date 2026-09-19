// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {ProtocolTimeLibrary} from "./libraries/ProtocolTimeLibrary.sol";

/// @title veMON
/// @notice ERC721 receipt for MON routed into validator staking.
contract VeMON is ERC721, ReentrancyGuardTransient {
    uint64 public constant MAX_LOCK_CYCLES = 4;

    address public immutable controller;
    uint256 public nextId = 1;

    mapping(uint256 tokenId => IVotingEscrow.LockedBalance lock) public locked;

    error InvalidAddress();
    error InvalidAmount();
    error InvalidValue();
    error LockDurationNotInFuture();
    error LockDurationTooLong();
    error ForwardFailed();

    event LockCreated(uint256 indexed tokenId, address indexed account, uint256 amount, uint256 unlockEpoch);

    constructor(address controller_) ERC721("veMON", "veMON") {
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
        locked[tokenId] = IVotingEscrow.LockedBalance(int128(int256(_value)), unlockEpoch, false, 0);
        emit LockCreated(tokenId, msg.sender, _value, unlockEpoch);

        _safeMint(msg.sender, tokenId);
    }

    function _unlockEpoch(uint256 lockCycles) private returns (uint256 unlockEpoch) {
        if (lockCycles == 0) revert LockDurationNotInFuture();
        if (lockCycles > MAX_LOCK_CYCLES) revert LockDurationTooLong();

        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        unlockEpoch = ProtocolTimeLibrary.cycleStart(epoch) + (lockCycles * ProtocolTimeLibrary.EPOCHS_PER_CYCLE);
        if (unlockEpoch <= epoch) revert LockDurationNotInFuture();
    }
}
