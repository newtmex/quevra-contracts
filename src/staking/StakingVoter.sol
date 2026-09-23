// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBaseVoter} from "../interfaces/IBaseVoter.sol";
import {IFactoryRegistry} from "../interfaces/factories/IFactoryRegistry.sol";
import {IGaugeFactory} from "../interfaces/factories/IGaugeFactory.sol";
import {IVotingRewardsFactory} from "../interfaces/factories/IVotingRewardsFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IVoter} from "../interfaces/IVoter.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {IReward} from "../interfaces/IReward.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";
import {StakingController} from "./StakingController.sol";

/// @notice Gauge creation and lifecycle hooks shared by staking voters.
/// @dev This carries the Tigris creation dependencies while leaving Quevra's
///      cycle voting and reward accounting in its existing voter contracts.
abstract contract StakingVoter is IBaseVoter, IVoter, ERC2771Context, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct VoteAllocation {
        uint128 weight;
        uint128 stakeAmount;
    }

    address public immutable forwarder;
    address public override ve;
    address public factoryRegistry;
    address public rewardToken;
    StakingController public controller;
    address public governor;
    mapping(address => bool) public override isWhitelistedToken;
    mapping(address => address) public gaugeToBribe;
    mapping(address => bool) public isGauge;
    mapping(address => uint256) public claimable;

    // Voting records are shared across staking voter implementations.
    mapping(uint256 => address[]) public poolVote;
    mapping(uint256 => uint256) public usedWeights;
    mapping(uint256 => mapping(address => VoteAllocation)) public votes;
    mapping(address => uint256) public weights;
    uint256 public totalWeight;
    mapping(uint64 => mapping(address => uint256)) public cycleWeights;
    mapping(uint64 => uint256) public cycleTotalWeight;
    mapping(uint256 => uint64) public lastVotedCycle;

    error ZeroAddress();
    error GaugeFactoryNotApproved();
    error NotGovernor();
    error VoteNotAuthorized();
    error InvalidVote();
    error VotingClosed();
    error AlreadyVoted();

    modifier onlyNewCycle(uint256 tokenId) {
        uint64 cycle = ProtocolTimeLibrary.currentCycleStart();
        if (lastVotedCycle[tokenId] == cycle && usedWeights[tokenId] != 0) revert AlreadyVoted();
        _;
    }

    event GaugeCreated(address indexed gauge, address indexed bribeVotingReward, address indexed creator);
    event WhitelistToken(address indexed whitelister, address indexed token, bool indexed whitelisted);
    event Voted(address indexed voter, uint256 indexed tokenId, uint256 weight);
    event Abstained(uint256 indexed tokenId, uint256 weight);

    constructor(address forwarder_) ERC2771Context(forwarder_) {
        if (forwarder_ == address(0)) revert ZeroAddress();
        forwarder = forwarder_;
    }

    function __StakingVoter_init(address ve_, address factoryRegistry_, address rewardToken_, address controller_)
        internal
    {
        if (ve_ == address(0) || factoryRegistry_ == address(0) || controller_ == address(0)) revert ZeroAddress();
        ve = ve_;
        factoryRegistry = factoryRegistry_;
        rewardToken = rewardToken_;
        controller = StakingController(payable(controller_));
        governor = _msgSender();
    }

    function emergencyCouncil() external view returns (address) {
        return governor;
    }

    function setGovernor(address governor_) external {
        if (_msgSender() != governor) revert NotGovernor();
        if (governor_ == address(0)) revert ZeroAddress();
        governor = governor_;
    }

    function whitelistToken(address token, bool whitelisted) external {
        if (_msgSender() != governor) revert NotGovernor();
        isWhitelistedToken[token] = whitelisted;
        emit WhitelistToken(_msgSender(), token, whitelisted);
    }

    function _createGauge(address gaugeFactory, address rewardsBeneficiary) internal returns (address gauge) {
        IFactoryRegistry registry = IFactoryRegistry(factoryRegistry);
        if (!registry.isGaugeFactoryApproved(gaugeFactory)) revert GaugeFactoryNotApproved();

        address rewardsFactory = registry.gaugeFactoryToVotingRewardsFactory(gaugeFactory);
        gauge = IGaugeFactory(gaugeFactory).createNonStakingGauge(forwarder, rewardToken, rewardsBeneficiary);
        address bribe = IVotingRewardsFactory(rewardsFactory).createBribeReward(forwarder, new address[](0));

        gaugeToBribe[gauge] = bribe;
        isGauge[gauge] = true;
        emit GaugeCreated(gauge, bribe, _msgSender());
    }

    function vote(uint256 tokenId, address[] calldata gauges, uint256[] calldata weights_)
        external
        virtual
        override
        nonReentrant
        onlyNewCycle(tokenId)
    {
        if (!IVotingEscrow(ve).isApprovedOrOwner(_msgSender(), tokenId)) revert VoteNotAuthorized();
        if (gauges.length == 0 || gauges.length != weights_.length) revert InvalidVote();
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        _checkVoteWindow(epoch);
        uint64 cycle = ProtocolTimeLibrary.cycleStart(epoch);

        uint256 requested;
        for (uint256 i; i < gauges.length; ++i) {
            if (!isGauge[gauges[i]] || weights_[i] == 0) revert InvalidVote();
            for (uint256 j; j < i; ++j) {
                if (gauges[j] == gauges[i]) revert InvalidVote();
            }
            requested += weights_[i];
        }
        uint256 power = IVotingEscrow(ve).votingPowerOf(tokenId);
        if (requested == 0 || power == 0) revert InvalidVote();
        (int128 lockedAmount,,,) = IVotingEscrow(ve).locked(tokenId);
        if (lockedAmount <= 0) revert InvalidVote();
        uint256 principal = uint256(uint128(lockedAmount));

        _reset(tokenId, cycle);
        _addVoteAllocations(tokenId, gauges, weights_, requested, power, principal, cycle);
        usedWeights[tokenId] = power;
        lastVotedCycle[tokenId] = cycle;
        emit Voted(_msgSender(), tokenId, power);
    }

    function _addVoteAllocations(
        uint256 tokenId,
        address[] calldata gauges,
        uint256[] calldata weights_,
        uint256 requested,
        uint256 power,
        uint256 principal,
        uint64 cycle
    ) private {
        uint256 allocatedWeight;
        uint256 allocatedStake;
        for (uint256 i; i < gauges.length; ++i) {
            bool isLast = i + 1 == gauges.length;
            uint256 weight = _distributed(power, weights_[i], requested, allocatedWeight, isLast);
            uint256 stakeAmount = _distributed(principal, weights_[i], requested, allocatedStake, isLast);
            allocatedWeight += weight;
            allocatedStake += stakeAmount;
            _addVote(tokenId, gauges[i], weight, stakeAmount, cycle);
        }
    }

    function poolVoteLength(uint256 tokenId) external view returns (uint256) {
        return poolVote[tokenId].length;
    }

    function _checkVoteWindow(uint64 epoch) private pure {
        if (epoch < ProtocolTimeLibrary.cycleVoteStart(epoch) || epoch >= ProtocolTimeLibrary.cycleVoteEnd(epoch)) {
            revert VotingClosed();
        }
    }

    function _reset(uint256 tokenId, uint64 cycle) private {
        address[] storage oldGauges = poolVote[tokenId];
        for (uint256 i; i < oldGauges.length; ++i) {
            address gauge = oldGauges[i];
            VoteAllocation memory allocation = votes[tokenId][gauge];
            if (allocation.weight == 0) continue;
            weights[gauge] -= allocation.weight;
            totalWeight -= allocation.weight;
            if (lastVotedCycle[tokenId] == cycle) {
                cycleWeights[cycle][gauge] -= allocation.weight;
                cycleTotalWeight[cycle] -= allocation.weight;
            }
            delete votes[tokenId][gauge];
            IReward(gaugeToBribe[gauge])._withdraw(allocation.weight, tokenId);
            emit Abstained(tokenId, allocation.weight);
        }
        delete poolVote[tokenId];
        usedWeights[tokenId] = 0;
    }

    function _addVote(uint256 tokenId, address gauge, uint256 weight, uint256 stakeAmount, uint64 cycle) private {
        poolVote[tokenId].push(gauge);
        votes[tokenId][gauge] = VoteAllocation(_toUint128(weight), _toUint128(stakeAmount));
        weights[gauge] += weight;
        totalWeight += weight;
        cycleWeights[cycle][gauge] += weight;
        cycleTotalWeight[cycle] += weight;
        IReward(gaugeToBribe[gauge])._deposit(weight, tokenId);
    }

    function _toUint128(uint256 value) private pure returns (uint128) {
        if (value > type(uint128).max) revert InvalidVote();
        return uint128(value);
    }

    function _distributed(uint256 total, uint256 requestedWeight, uint256 requested, uint256 allocated, bool isLast)
        private
        pure
        returns (uint256)
    {
        return isLast ? total - allocated : total * requestedWeight / requested;
    }
}
