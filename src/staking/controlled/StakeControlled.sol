// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";

abstract contract StakeControlled is Initializable {
    uint8 internal constant WITHDRAW_ID = 0;
    IMonadStaking internal constant STAKING = IMonadStaking(address(0x1000));

    /// @custom:storage-location erc7201:quevra.StakeControlled
    struct StakeControlledStorage {
        address controller;
    }

    bytes32 private constant STAKE_CONTROLLED_STORAGE_SLOT =
        0xb9467c0878ba5b8ea107d9b6e2f401bca02821866aead17c4099c3b67ee7a500;

    function _stakeControlledStorage() internal pure returns (StakeControlledStorage storage $) {
        bytes32 slot = STAKE_CONTROLLED_STORAGE_SLOT;
        assembly ("memory-safe") { $.slot := slot }
    }

    error OnlyController();
    error ControlledStakingCallFailed();
    error InvalidController();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function controller() public view returns (address) {
        return _stakeControlledStorage().controller;
    }

    modifier onlyController() {
        if (msg.sender != controller()) revert OnlyController();
        _;
    }

    function __StakeControlled_init(address controller_) internal onlyInitializing {
        if (controller_ == address(0) || msg.sender != controller_) revert InvalidController();
        _stakeControlledStorage().controller = controller_;
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
