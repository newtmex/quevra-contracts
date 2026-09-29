// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MonadStdConstants} from "monad-std/MonadStdConstants.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

abstract contract StakeControlled is MonadStdConstants, Initializable {
    uint8 internal constant WITHDRAW_ID = 0;
    address public immutable controller = msg.sender;

    error InvalidController();
    error OnlyController();
    error ControlledStakingCallFailed();
    error ControlledTransferFailed();

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

    function _claimRewards(uint64 validatorId) internal returns (uint256 claimed) {
        uint256 beforeBalance = availableBalance();
        if (!STAKING.claimRewards(validatorId)) revert ControlledStakingCallFailed();
        claimed = availableBalance() - beforeBalance;
        if (claimed != 0) {
            (bool success,) = payable(controller).call{value: claimed}("");
            if (!success) revert ControlledTransferFailed();
        }
    }

    function _compound(uint64 validatorId) internal {
        if (!STAKING.compound(validatorId)) revert ControlledStakingCallFailed();
    }
}
