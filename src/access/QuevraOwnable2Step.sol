// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Local equivalent of OpenZeppelin's Ownable2Step with an explicit direct
///      Ownable constructor target for the compiler used by the Monad toolchain.
abstract contract QuevraOwnable2Step is Ownable {
    address private _pendingOwner;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    constructor(address initialOwner) Ownable(initialOwner) {}

    function pendingOwner() public view returns (address) {
        return _pendingOwner;
    }

    function transferOwnership(address newOwner) public override onlyOwner {
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner(), newOwner);
    }

    function acceptOwnership() public {
        if (pendingOwner() != _msgSender()) revert OwnableUnauthorizedAccount(_msgSender());
        delete _pendingOwner;
        _transferOwnership(_msgSender());
    }
}
