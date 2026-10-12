// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @notice Storage operations for a token's validator and reward vault lists.
/// @dev The controller owns the storage; these helpers keep its collection and
///      intent bookkeeping out of the staking flow implementation.
library StakingControllerRewardsLibrary {
    using EnumerableSet for EnumerableSet.AddressSet;

    function rememberVault(
        uint256 tokenId,
        address vault,
        mapping(uint256 => EnumerableSet.AddressSet) storage tokenVaultLists,
        mapping(uint256 => EnumerableSet.AddressSet) storage rewardVaultLists
    ) internal {
        tokenVaultLists[tokenId].add(vault);
        rewardVaultLists[tokenId].add(vault);
    }

    function setIntent(
        uint256 tokenId,
        address[] calldata vaults,
        uint256[] calldata amounts,
        mapping(uint256 => address[]) storage intentVaultLists,
        mapping(uint256 => mapping(address => uint256)) storage intentVaultIndex,
        mapping(uint256 => mapping(address => uint256)) storage intent
    ) internal {
        address[] storage previous = intentVaultLists[tokenId];
        for (uint256 i; i < previous.length; ++i) {
            delete intent[tokenId][previous[i]];
            delete intentVaultIndex[tokenId][previous[i]];
        }
        delete intentVaultLists[tokenId];
        for (uint256 i; i < vaults.length; ++i) {
            address vault = vaults[i];
            previous.push(vault);
            intentVaultIndex[tokenId][vault] = i + 1;
            intent[tokenId][vault] = amounts[i];
        }
    }

    function increaseIntent(
        uint256 tokenId,
        address vault,
        uint256 amount,
        mapping(uint256 => address[]) storage intentVaultLists,
        mapping(uint256 => mapping(address => uint256)) storage intentVaultIndex,
        mapping(uint256 => mapping(address => uint256)) storage intent
    ) internal {
        if (amount == 0) return;
        intent[tokenId][vault] += amount;
        if (intentVaultIndex[tokenId][vault] == 0) {
            intentVaultLists[tokenId].push(vault);
            intentVaultIndex[tokenId][vault] = intentVaultLists[tokenId].length;
        }
    }

    function recordReward(
        uint256 tokenId,
        address vault,
        uint256 amount,
        mapping(uint256 => EnumerableSet.AddressSet) storage tokenVaultLists,
        mapping(uint256 => EnumerableSet.AddressSet) storage rewardVaultLists,
        mapping(uint256 => address[]) storage intentVaultLists,
        mapping(uint256 => mapping(address => uint256)) storage intentVaultIndex,
        mapping(uint256 => mapping(address => uint256)) storage intent
    ) internal {
        rememberVault(tokenId, vault, tokenVaultLists, rewardVaultLists);
        increaseIntent(tokenId, vault, amount, intentVaultLists, intentVaultIndex, intent);
    }

    function reduceIntent(
        uint256 tokenId,
        address vault,
        uint256 amount,
        mapping(uint256 => mapping(address => uint256)) storage intent
    ) internal {
        uint256 target = intent[tokenId][vault];
        if (target <= amount) {
            delete intent[tokenId][vault];
        } else {
            intent[tokenId][vault] = target - amount;
        }
    }

    function removeVault(
        uint256 tokenId,
        address vault,
        mapping(uint256 => EnumerableSet.AddressSet) storage vaultsByToken
    ) internal {
        vaultsByToken[tokenId].remove(vault);
    }

    function removeRewardVault(
        uint256 tokenId,
        address vault,
        mapping(uint256 => EnumerableSet.AddressSet) storage vaultsByToken
    ) internal {
        vaultsByToken[tokenId].remove(vault);
    }

    function clearVaultLists(uint256 tokenId, mapping(uint256 => EnumerableSet.AddressSet) storage vaultsByToken)
        internal
    {
        EnumerableSet.AddressSet storage vaults = vaultsByToken[tokenId];
        while (vaults.length() != 0) {
            vaults.remove(vaults.at(vaults.length() - 1));
        }
    }
}
