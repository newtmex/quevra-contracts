// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @notice Storage operations for a token's validator and reward gauge lists.
/// @dev The controller owns the storage; these helpers keep its collection and
///      intent bookkeeping out of the staking flow implementation.
library StakingControllerGaugeLibrary {
    using EnumerableSet for EnumerableSet.AddressSet;

    function rememberGauge(
        uint256 tokenId,
        address gauge,
        mapping(uint256 => EnumerableSet.AddressSet) storage tokenGauges,
        mapping(uint256 => EnumerableSet.AddressSet) storage rewardGauges
    ) internal {
        tokenGauges[tokenId].add(gauge);
        rewardGauges[tokenId].add(gauge);
    }

    function setIntent(
        uint256 tokenId,
        address[] calldata gauges,
        uint256[] calldata amounts,
        mapping(uint256 => address[]) storage intentGauges,
        mapping(uint256 => mapping(address => uint256)) storage intentGaugeIndex,
        mapping(uint256 => mapping(address => uint256)) storage intent
    ) internal {
        address[] storage previous = intentGauges[tokenId];
        for (uint256 i; i < previous.length; ++i) {
            delete intent[tokenId][previous[i]];
            delete intentGaugeIndex[tokenId][previous[i]];
        }
        delete intentGauges[tokenId];
        for (uint256 i; i < gauges.length; ++i) {
            address gauge = gauges[i];
            previous.push(gauge);
            intentGaugeIndex[tokenId][gauge] = i + 1;
            intent[tokenId][gauge] = amounts[i];
        }
    }

    function increaseIntent(
        uint256 tokenId,
        address gauge,
        uint256 amount,
        mapping(uint256 => address[]) storage intentGauges,
        mapping(uint256 => mapping(address => uint256)) storage intentGaugeIndex,
        mapping(uint256 => mapping(address => uint256)) storage intent
    ) internal {
        if (amount == 0) return;
        intent[tokenId][gauge] += amount;
        if (intentGaugeIndex[tokenId][gauge] == 0) {
            intentGauges[tokenId].push(gauge);
            intentGaugeIndex[tokenId][gauge] = intentGauges[tokenId].length;
        }
    }

    function recordReward(
        uint256 tokenId,
        address gauge,
        uint256 amount,
        mapping(uint256 => EnumerableSet.AddressSet) storage tokenGauges,
        mapping(uint256 => EnumerableSet.AddressSet) storage rewardGauges,
        mapping(uint256 => address[]) storage intentGauges,
        mapping(uint256 => mapping(address => uint256)) storage intentGaugeIndex,
        mapping(uint256 => mapping(address => uint256)) storage intent
    ) internal {
        rememberGauge(tokenId, gauge, tokenGauges, rewardGauges);
        increaseIntent(tokenId, gauge, amount, intentGauges, intentGaugeIndex, intent);
    }

    function reduceIntent(
        uint256 tokenId,
        address gauge,
        uint256 amount,
        mapping(uint256 => mapping(address => uint256)) storage intent
    ) internal {
        uint256 target = intent[tokenId][gauge];
        if (target <= amount) {
            delete intent[tokenId][gauge];
        } else {
            intent[tokenId][gauge] = target - amount;
        }
    }

    function removeGauge(
        uint256 tokenId,
        address gauge,
        mapping(uint256 => EnumerableSet.AddressSet) storage gaugesByToken
    ) internal {
        gaugesByToken[tokenId].remove(gauge);
    }

    function removeRewardGauge(
        uint256 tokenId,
        address gauge,
        mapping(uint256 => EnumerableSet.AddressSet) storage gaugesByToken
    ) internal {
        gaugesByToken[tokenId].remove(gauge);
    }

    function clearGauges(uint256 tokenId, mapping(uint256 => EnumerableSet.AddressSet) storage gaugesByToken) internal {
        EnumerableSet.AddressSet storage gauges = gaugesByToken[tokenId];
        while (gauges.length() != 0) gauges.remove(gauges.at(gauges.length() - 1));
    }
}
