// SPDX-License-Identifier: BUSL-1.1
// Adapted from Tigris NonStakingVoter.sol (BUSL-1.1).
// Upstream: tigris/solidity/contracts/NonStakingVoter.sol @ fa9ba83d93d4ee362b0699e7bcd13d32e150afda
// License text: LICENSE-BUSL-1.1.txt — provenance: docs/provenance.md
pragma solidity ^0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBaseVoter} from "../interfaces/IBaseVoter.sol";
import {INonStakingVoter} from "../interfaces/INonStakingVoter.sol";
import {IGauge} from "../interfaces/IGauge.sol";
import {IReward} from "../interfaces/IReward.sol";

/// @dev Tigris-derived abstract layer for token whitelisting and reward funding. Concrete voters
///      provide gauge creation and vote-weight transitions.
abstract contract NonStakingVoter is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardTransient,
    INonStakingVoter
{
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:quevra.NonStakingVoter
    struct NonStakingVoterStorage {
        address ve;
        mapping(address token => bool) isWhitelistedToken;
        mapping(address gauge => bool) isGauge;
        mapping(address gauge => address bribeVotingRewards) gaugeToBribe;
        mapping(address gauge => uint256 amount) weights;
        mapping(uint256 tokenId => mapping(address gauge => uint256 amount)) votes;
        mapping(uint256 tokenId => uint256 amount) usedWeights;
        mapping(uint256 tokenId => address[]) gaugeVote;
    }

    bytes32 private constant NON_STAKING_VOTER_STORAGE_SLOT =
        0x0431b90e76672ad60f1867a33025fcd18669ccb8fadb8d04c70b7e6f22e42700;

    function _voterStorage() internal pure returns (NonStakingVoterStorage storage $) {
        bytes32 slot = NON_STAKING_VOTER_STORAGE_SLOT;
        assembly ("memory-safe") { $.slot := slot }
    }

    /// @inheritdoc IBaseVoter
    function ve() public view override returns (address) {
        return _voterStorage().ve;
    }

    /// @inheritdoc IBaseVoter
    function isWhitelistedToken(address token) public view override returns (bool) {
        return _voterStorage().isWhitelistedToken[token];
    }

    /// @inheritdoc INonStakingVoter
    function isGauge(address gauge) public view override returns (bool) {
        return _voterStorage().isGauge[gauge];
    }

    /// @inheritdoc INonStakingVoter
    function gaugeToBribe(address gauge) public view override returns (address) {
        return _voterStorage().gaugeToBribe[gauge];
    }

    /// @inheritdoc INonStakingVoter
    function weights(address gauge) public view override returns (uint256) {
        return _voterStorage().weights[gauge];
    }

    /// @inheritdoc INonStakingVoter
    function votes(uint256 tokenId, address gauge) public view override returns (uint256) {
        return _voterStorage().votes[tokenId][gauge];
    }

    /// @inheritdoc INonStakingVoter
    function usedWeights(uint256 tokenId) public view override returns (uint256) {
        return _voterStorage().usedWeights[tokenId];
    }

    /// @inheritdoc INonStakingVoter
    function gaugeVote(uint256 tokenId, uint256 index) public view returns (address) {
        return _voterStorage().gaugeVote[tokenId][index];
    }

    function __NonStakingVoter_init(address votingVe_, address owner_) internal onlyInitializing {
        if (votingVe_ == address(0) || votingVe_.code.length == 0 || owner_ == address(0)) revert ZeroAddress();
        __Ownable_init(owner_);
        __Ownable2Step_init();
        _voterStorage().ve = votingVe_;
    }

    // External state-changing API

    /// @inheritdoc INonStakingVoter
    function whitelistToken(address token, bool whitelisted) external virtual override onlyOwner {
        if (token == address(0) || token.code.length == 0) revert ZeroAddress();
        _voterStorage().isWhitelistedToken[token] = whitelisted;
        emit WhitelistToken(msg.sender, token, whitelisted);
    }

    /// @inheritdoc INonStakingVoter
    function notifyGaugeReward(address gauge, uint256 amount) external virtual override nonReentrant {
        if (!_voterStorage().isGauge[gauge]) revert GaugeDoesNotExist(gauge);
        address token = IGauge(gauge).rewardToken();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(token).forceApprove(gauge, amount);
        IGauge(gauge).notifyRewardAmount(amount);
    }

    /// @dev Notifies the gauge's bribe rewards contract of a vote weight.
    ///      Derived voters may override this to customize gauge weight handling.
    function _notifyGaugeWeight(address gauge, uint256 amount, uint256 tokenId) internal virtual {
        IReward(_voterStorage().gaugeToBribe[gauge])._deposit(amount, tokenId);
    }

    /// @dev Withdraws a previously deposited gauge weight.
    function _withdrawGaugeWeight(address gauge, uint256 amount, uint256 tokenId) internal virtual {
        IReward(_voterStorage().gaugeToBribe[gauge])._withdraw(amount, tokenId);
    }

    function _registerGauge(address gauge, address bribeVotingRewards) internal virtual {
        if (gauge == address(0) || bribeVotingRewards == address(0)) revert ZeroAddress();
        if (_voterStorage().isGauge[gauge]) revert GaugeExists();
        _voterStorage().isGauge[gauge] = true;
        _voterStorage().gaugeToBribe[gauge] = bribeVotingRewards;
    }

    function _unregisterGauge(address gauge) internal virtual {
        delete _voterStorage().isGauge[gauge];
        delete _voterStorage().gaugeToBribe[gauge];
    }
}
