// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Development-only reward token deployed by the root Solonet workflow.
contract SolonetRewardToken is ERC20 {
    constructor() ERC20("Quevra Solonet Reward", "qMON") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}
