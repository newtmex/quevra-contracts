// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MonadStdConstants} from "monad-std/MonadStdConstants.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

abstract contract StakeControlled is MonadStdConstants, Initializable {
    address public immutable controller = msg.sender;

    error InvalidController();
    error OnlyController();

    constructor() {
        _disableInitializers();
    }

    modifier onlyController() {
        if (msg.sender != controller) revert OnlyController();
        _;
    }

    function availableBalance() public view returns (uint256) {
        return address(this).balance;
    }
}
