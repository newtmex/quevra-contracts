// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBaseVoter} from "../interfaces/IBaseVoter.sol";
import {IBoostVoter} from "../interfaces/IBoostVoter.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {IVotingEscrowBooster} from "../interfaces/IVotingEscrowBooster.sol";
import {StakingRewards} from "../rewards/StakingRewards.sol";
import {BoostLibrary} from "../libraries/BoostLibrary.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";

/// @title BoostVoter
/// @notice Allocates voting veMON power to veMON positions and refreshes their boost.
/// @dev The Tigris reward target is represented by Quevra's cycle-scoped
///      {StakingRewards} contract. This keeps incentive accounting in one
///      reward implementation and avoids a second target type.
contract BoostVoter is Ownable2Step, ReentrancyGuardTransient, IBoostVoter {
    uint256 public constant BOOST_PRECISION = BoostLibrary.PRECISION;
    uint256 public constant MAX_BOOST = 5 * BoostLibrary.PRECISION;

    address public immutable override ve;
    address public immutable override boostableVe;

    mapping(address token => bool) public override isWhitelistedToken;
    mapping(uint256 tokenId => address stakingRewards) public override boostableTokenIdToStakingRewards;
    mapping(address stakingRewards => uint256 tokenId) public boostableTokenIdForStakingRewards;
    mapping(address stakingRewards => uint256 amount) public weights;
    mapping(uint256 tokenId => mapping(address stakingRewards => uint256 amount)) public votes;
    mapping(uint256 tokenId => uint256 amount) public usedWeights;
    mapping(uint256 tokenId => uint64 cycle) public lastVoted;
    mapping(uint256 tokenId => address[]) private _targets;

    event RewardTokenWhitelistUpdated(address indexed token, bool whitelisted);
    event BoostStakingRewardsCreated(uint256 indexed boostableTokenId, address indexed stakingRewards);
    event Voted(address indexed voter, address indexed stakingRewards, uint256 indexed tokenId, uint256 weight);
    event Abstained(address indexed voter, address indexed stakingRewards, uint256 indexed tokenId, uint256 weight);
    event BoostPoked(uint256 indexed boostableTokenId, uint256 boost);
    event BoostableTokenBurned(uint256 indexed boostableTokenId, address indexed stakingRewards);

    error InvalidAddress();
    error NotApprovedOrOwner();
    error InvalidTarget();
    error TargetExists();
    error LengthMismatch();
    error EmptyArray();
    error ZeroAmount();
    error AlreadyVoted();
    error NotBoostableVe();
    error LockDoesNotExist();
    error LockExpired();
    error NotWhitelisted();

    constructor(address votingVe_, address boostableVe_, address owner_) Ownable(owner_) {
        if (votingVe_ == address(0) || boostableVe_ == address(0) || owner_ == address(0)) revert InvalidAddress();
        ve = votingVe_;
        boostableVe = boostableVe_;
    }

    function setRewardTokenWhitelisted(address token, bool whitelisted) external onlyOwner {
        if (token == address(0) || token.code.length == 0) revert InvalidAddress();
        isWhitelistedToken[token] = whitelisted;
        emit RewardTokenWhitelistUpdated(token, whitelisted);
    }

    function createBoostStakingRewards(uint256 boostableTokenId)
        external
        override
        nonReentrant
        returns (address stakingRewards)
    {
        if (!IVotingEscrow(boostableVe).isApprovedOrOwner(msg.sender, boostableTokenId)) {
            revert NotApprovedOrOwner();
        }
        if (boostableTokenIdToStakingRewards[boostableTokenId] != address(0)) revert TargetExists();

        (int128 amount, uint256 end, bool isPermanent,) = IVotingEscrow(boostableVe).locked(boostableTokenId);
        if (amount <= 0) revert LockDoesNotExist();
        if (!isPermanent && end <= _currentEpoch()) revert LockExpired();

        stakingRewards = address(new StakingRewards(address(this), boostableTokenId, msg.sender));
        boostableTokenIdToStakingRewards[boostableTokenId] = stakingRewards;
        boostableTokenIdForStakingRewards[stakingRewards] = boostableTokenId;
        emit BoostStakingRewardsCreated(boostableTokenId, stakingRewards);
    }

    function vote(uint256 tokenId, address[] calldata targets, uint256[] calldata weights_)
        external
        override
        nonReentrant
    {
        if (!IVotingEscrow(ve).isApprovedOrOwner(msg.sender, tokenId)) revert NotApprovedOrOwner();
        if (targets.length == 0 || targets.length != weights_.length) revert LengthMismatch();
        uint64 cycle = ProtocolTimeLibrary.currentCycle();
        if (lastVoted[tokenId] == cycle) revert AlreadyVoted();
        _reset(tokenId);

        uint256 total = 0;
        for (uint256 i; i < targets.length; ++i) {
            if (weights_[i] == 0 || boostableTokenIdForStakingRewards[targets[i]] == 0) revert InvalidTarget();
            total += weights_[i];
        }
        uint256 votingPower = IVotingEscrow(ve).votingPowerOf(tokenId);
        for (uint256 i; i < targets.length; ++i) {
            uint256 amount = votingPower * weights_[i] / total;
            if (amount == 0) revert ZeroAmount();
            votes[tokenId][targets[i]] = amount;
            weights[targets[i]] += amount;
            usedWeights[tokenId] += amount;
            StakingRewards(targets[i])._deposit(amount, tokenId);
            _targets[tokenId].push(targets[i]);
            emit Voted(msg.sender, targets[i], tokenId, amount);
        }
        lastVoted[tokenId] = cycle;
    }

    function reset(uint256 tokenId) external override nonReentrant {
        if (!IVotingEscrow(ve).isApprovedOrOwner(msg.sender, tokenId)) revert NotApprovedOrOwner();
        _reset(tokenId);
    }

    function poke(uint256 boostableTokenId) external override nonReentrant {
        _poke(boostableTokenId);
    }

    function pokeBoost(uint256 boostableTokenId) external override nonReentrant {
        _poke(boostableTokenId);
    }

    function pokeMany(uint256[] calldata boostableTokenIds) external override nonReentrant {
        for (uint256 i; i < boostableTokenIds.length; ++i) {
            _poke(boostableTokenIds[i]);
        }
    }

    function pokeBoosts(uint256[] calldata boostableTokenIds) external override nonReentrant {
        for (uint256 i; i < boostableTokenIds.length; ++i) {
            _poke(boostableTokenIds[i]);
        }
    }

    function getBoost(uint256 boostableTokenId) public view override returns (uint256) {
        address target = boostableTokenIdToStakingRewards[boostableTokenId];
        uint256 votingTotal = IVotingEscrow(ve).totalVotingPower();
        uint256 targetWeight = weights[target];
        uint256 targetPower = IVotingEscrow(boostableVe).unboostedVotingPowerOf(boostableTokenId);
        uint256 targetTotal = IVotingEscrow(boostableVe).unboostedTotalVotingPower();
        if (target == address(0) || votingTotal == 0 || targetWeight == 0 || targetPower == 0) {
            return BoostLibrary.PRECISION;
        }

        uint256 votingRatio = targetWeight * BoostLibrary.PRECISION / votingTotal;
        uint256 targetRatio = targetTotal * BoostLibrary.PRECISION / targetPower;
        uint256 boost = BoostLibrary.PRECISION + 4 * Math.mulDiv(targetRatio, votingRatio, BoostLibrary.PRECISION);
        return Math.min(MAX_BOOST, boost);
    }

    function notifyBoostableBurned(uint256 boostableTokenId) external override {
        if (msg.sender != boostableVe) revert NotBoostableVe();
        address target = boostableTokenIdToStakingRewards[boostableTokenId];
        if (target == address(0)) return;
        delete boostableTokenIdToStakingRewards[boostableTokenId];
        delete boostableTokenIdForStakingRewards[target];
        emit BoostableTokenBurned(boostableTokenId, target);
    }

    function _poke(uint256 boostableTokenId) internal {
        uint256 boost = getBoost(boostableTokenId);
        emit BoostPoked(boostableTokenId, boost);
        IVotingEscrowBooster(boostableVe).updateBoost(boostableTokenId, boost);
    }

    function _reset(uint256 tokenId) internal {
        address[] storage targets = _targets[tokenId];
        for (uint256 i; i < targets.length; ++i) {
            address target = targets[i];
            uint256 amount = votes[tokenId][target];
            if (amount == 0) continue;
            weights[target] -= amount;
            delete votes[tokenId][target];
            StakingRewards(target)._withdraw(amount, tokenId);
            emit Abstained(msg.sender, target, tokenId, amount);
        }
        delete _targets[tokenId];
        usedWeights[tokenId] = 0;
    }

    function _currentEpoch() private returns (uint256 epoch) {
        (epoch,) = ProtocolTimeLibrary.currentEpoch();
    }
}
