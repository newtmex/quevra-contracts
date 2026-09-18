// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title veMON
/// @notice ERC721 receipt for MON routed into validator staking.
contract VeMON is ERC721, ReentrancyGuardTransient {
    struct Lock {
        uint256 amount;
        uint256 duration;
    }

    address public immutable controller;
    uint256 public nextId = 1;

    mapping(uint256 tokenId => Lock lock) public locks;

    error InvalidAddress();
    error InvalidAmount();
    error InvalidValue();
    error ForwardFailed();

    event LockCreated(uint256 indexed tokenId, address indexed account, uint256 amount, uint256 duration);

    constructor(address controller_) ERC721("veMON", "veMON") {
        if (controller_ == address(0)) revert InvalidAddress();
        controller = controller_;
    }

    function createLock(uint256 _value, uint256 _lockDuration) external payable nonReentrant returns (uint256 tokenId) {
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
        locks[tokenId] = Lock(_value, _lockDuration);
        emit LockCreated(tokenId, msg.sender, _value, _lockDuration);

        _safeMint(msg.sender, tokenId);
    }
}
