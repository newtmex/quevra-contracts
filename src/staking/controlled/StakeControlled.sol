// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";

abstract contract StakeControlled is Initializable {
    uint8 internal constant WITHDRAW_ID = 0;
    IMonadStaking internal constant STAKING = IMonadStaking(address(0x1000));
    address public immutable controller = msg.sender;

    error OnlyController();
    error ControlledStakingCallFailed();

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

    function _claimRewardsRaw(uint64 validatorId) internal returns (uint256 claimed) {
        uint256 beforeBalance = availableBalance();
        if (!STAKING.claimRewards(validatorId)) revert ControlledStakingCallFailed();
        claimed = availableBalance() - beforeBalance;
    }
}
