// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface INonStakingGauge {
    event RewardsBeneficiarySwitched(address indexed oldBeneficiary, address indexed newBeneficiary);

    function rewardsBeneficiary() external view returns (address);
    function switchRewardsBeneficiary(address newBeneficiary) external;
}
