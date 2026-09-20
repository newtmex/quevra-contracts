// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IFactoryRegistry} from "../interfaces/factories/IFactoryRegistry.sol";

/// @notice Owner-managed registry of approved gauge and voting-reward factories.
/// @dev Keeps the factory pairing stable when a gauge factory is later reapproved.
contract FactoryRegistry is IFactoryRegistry, Ownable {
    mapping(address gaugeFactory => address votingRewardsFactory) private _rewardFactories;
    mapping(address gaugeFactory => bool approved) private _approved;
    address[] private _gaugeFactories;

    error ZeroAddress();
    error PathAlreadyApproved();
    error PathNotApproved();
    error InvalidGaugeFactoryPair();

    event ApproveGaugeFactory(address indexed gaugeFactory, address indexed votingRewardsFactory);
    event UnapproveGaugeFactory(address indexed gaugeFactory, address indexed votingRewardsFactory);

    constructor() Ownable(msg.sender) {}

    function approveGaugeFactory(address gaugeFactory, address votingRewardsFactory) external onlyOwner {
        if (gaugeFactory == address(0) || votingRewardsFactory == address(0)) revert ZeroAddress();
        if (_approved[gaugeFactory]) revert PathAlreadyApproved();

        address existing = _rewardFactories[gaugeFactory];
        if (existing != address(0) && existing != votingRewardsFactory) revert InvalidGaugeFactoryPair();
        _rewardFactories[gaugeFactory] = votingRewardsFactory;
        _approved[gaugeFactory] = true;
        if (existing == address(0)) _gaugeFactories.push(gaugeFactory);
        emit ApproveGaugeFactory(gaugeFactory, votingRewardsFactory);
    }

    function unapproveGaugeFactory(address gaugeFactory) external onlyOwner {
        if (!_approved[gaugeFactory]) revert PathNotApproved();
        _approved[gaugeFactory] = false;
        emit UnapproveGaugeFactory(gaugeFactory, _rewardFactories[gaugeFactory]);
    }

    function isGaugeFactoryApproved(address gaugeFactory) external view returns (bool) {
        return _approved[gaugeFactory];
    }

    function gaugeFactoryToVotingRewardsFactory(address gaugeFactory) external view returns (address) {
        return _rewardFactories[gaugeFactory];
    }

    function gaugeFactories() external view returns (address[] memory) {
        return _gaugeFactories;
    }
}
