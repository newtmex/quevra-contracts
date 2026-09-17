// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IWMON
/// @notice Canonical WETH9-shaped wrapped MON. Do not deploy a production wrapper.
interface IWMON is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}
