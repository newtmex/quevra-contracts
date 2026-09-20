// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBaseVoter} from "./interfaces/IBaseVoter.sol";
import {IFactoryRegistry} from "./interfaces/factories/IFactoryRegistry.sol";
import {IGaugeFactory} from "./interfaces/factories/IGaugeFactory.sol";
import {IVotingRewardsFactory} from "./interfaces/factories/IVotingRewardsFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IVoter} from "./interfaces/IVoter.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {IReward} from "./interfaces/IReward.sol";
import {ProtocolTimeLibrary} from "./libraries/ProtocolTimeLibrary.sol";

/// @notice Gauge creation and lifecycle hooks shared by validator voters.
/// @dev This carries the Tigris creation dependencies while leaving Quevra's
///      cycle voting and reward accounting in its existing voter contracts.
abstract contract NonStakingVoter is IBaseVoter, IVoter, ERC2771Context, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable forwarder;
    address public override ve;
    address public factoryRegistry;
    address public rewardToken;
    address public splitter;
    address public governor;
    mapping(address => bool) public override isWhitelistedToken;
    mapping(address => address) public gaugeToBribe;
    mapping(address => bool) public isGauge;
    mapping(address => bool) public isAlive;
    mapping(address => uint256) public claimable;

    // Voting records are shared across non-staking voter implementations.
    mapping(uint256 => address[]) public poolVote;
    mapping(uint256 => uint256) public usedWeights;
    mapping(uint256 => mapping(address => uint256)) public votes;
    mapping(address => uint256) public weights;
    uint256 public totalWeight;
    mapping(uint64 => mapping(address => uint256)) public cycleWeights;
    mapping(uint64 => uint256) public cycleTotalWeight;
    mapping(uint256 => uint64) public lastVotedCycle;

    error ZeroAddress();
    error GaugeFactoryNotApproved();
    error GaugeDoesNotExist(address gauge);
    error GaugeAlreadyKilled();
    error NotGovernor();
    error VoteNotAuthorized();
    error InvalidVote();
    error VotingClosed();

    event GaugeCreated(address indexed gauge, address indexed bribeVotingReward, address indexed creator);
    event GaugeKilled(address indexed gauge);
    event SplitterSet(address indexed splitter);
    event WhitelistToken(address indexed whitelister, address indexed token, bool indexed whitelisted);
    event Voted(address indexed voter, uint256 indexed tokenId, uint256 weight);
    event Abstained(uint256 indexed tokenId, uint256 weight);

    constructor(address forwarder_) ERC2771Context(forwarder_) {
        if (forwarder_ == address(0)) revert ZeroAddress();
        forwarder = forwarder_;
    }

    function __NonStakingVoter_init(address ve_, address factoryRegistry_, address rewardToken_) internal {
        if (ve_ == address(0) || factoryRegistry_ == address(0)) revert ZeroAddress();
        ve = ve_;
        factoryRegistry = factoryRegistry_;
        rewardToken = rewardToken_;
        splitter = _msgSender();
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

    function setSplitter(address splitter_) external {
        if (_msgSender() != governor) revert NotGovernor();
        if (splitter_ == address(0)) revert ZeroAddress();
        splitter = splitter_;
        emit SplitterSet(splitter_);
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
        isAlive[gauge] = true;
        emit GaugeCreated(gauge, bribe, _msgSender());
    }

    function _onGaugeKilled(address gauge) internal {
        if (!isGauge[gauge]) revert GaugeDoesNotExist(gauge);
        if (!isAlive[gauge]) revert GaugeAlreadyKilled();

        uint256 amount = claimable[gauge];
        if (amount != 0) {
            delete claimable[gauge];
            IERC20(rewardToken).safeTransfer(splitter, amount);
        }
        isAlive[gauge] = false;
        emit GaugeKilled(gauge);
    }

    function vote(uint256 tokenId, address[] calldata gauges, uint256[] calldata weights_)
        external
        virtual
        override
        nonReentrant
    {
        if (!IVotingEscrow(ve).isApprovedOrOwner(_msgSender(), tokenId)) revert VoteNotAuthorized();
        if (gauges.length == 0 || gauges.length != weights_.length) revert InvalidVote();
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        _checkVoteWindow(epoch);
        uint64 cycle = ProtocolTimeLibrary.cycleStart(epoch);

        uint256 requested;
        for (uint256 i; i < gauges.length; ++i) {
            if (!isGauge[gauges[i]] || !isAlive[gauges[i]] || weights_[i] == 0) revert InvalidVote();
            for (uint256 j; j < i; ++j) {
                if (gauges[j] == gauges[i]) revert InvalidVote();
            }
            requested += weights_[i];
        }
        uint256 power = IVotingEscrow(ve).votingPowerOf(tokenId);
        if (requested == 0 || power == 0) revert InvalidVote();

        _reset(tokenId, cycle);
        uint256 allocated;
        for (uint256 i; i < gauges.length; ++i) {
            uint256 amount = i + 1 == gauges.length ? power - allocated : power * weights_[i] / requested;
            allocated += amount;
            _addVote(tokenId, gauges[i], amount, cycle);
        }
        usedWeights[tokenId] = power;
        lastVotedCycle[tokenId] = cycle;
        emit Voted(_msgSender(), tokenId, power);
    }

    function reset(uint256 tokenId) external virtual override nonReentrant {
        if (!IVotingEscrow(ve).isApprovedOrOwner(_msgSender(), tokenId)) revert VoteNotAuthorized();
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        _checkVoteWindow(epoch);
        _reset(tokenId, ProtocolTimeLibrary.cycleStart(epoch));
    }

    function poke(uint256 tokenId) external virtual override nonReentrant {
        if (!IVotingEscrow(ve).isApprovedOrOwner(_msgSender(), tokenId)) revert VoteNotAuthorized();
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        _checkVoteWindow(epoch);
        uint64 cycle = ProtocolTimeLibrary.cycleStart(epoch);
        address[] memory oldGauges = poolVote[tokenId];
        uint256[] memory oldAmounts = new uint256[](oldGauges.length);
        uint256 oldTotal;
        for (uint256 i; i < oldGauges.length; ++i) {
            oldAmounts[i] = votes[tokenId][oldGauges[i]];
            oldTotal += oldAmounts[i];
        }
        if (oldTotal == 0) revert InvalidVote();
        uint256 power = IVotingEscrow(ve).votingPowerOf(tokenId);
        _reset(tokenId, cycle);
        uint256 allocated;
        for (uint256 i; i < oldGauges.length; ++i) {
            if (!isGauge[oldGauges[i]] || !isAlive[oldGauges[i]]) revert InvalidVote();
            uint256 amount = i + 1 == oldGauges.length ? power - allocated : power * oldAmounts[i] / oldTotal;
            allocated += amount;
            _addVote(tokenId, oldGauges[i], amount, cycle);
        }
        usedWeights[tokenId] = power;
        lastVotedCycle[tokenId] = cycle;
        emit Voted(_msgSender(), tokenId, power);
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
            uint256 amount = votes[tokenId][gauge];
            if (amount == 0) continue;
            weights[gauge] -= amount;
            totalWeight -= amount;
            if (lastVotedCycle[tokenId] == cycle) {
                cycleWeights[cycle][gauge] -= amount;
                cycleTotalWeight[cycle] -= amount;
            }
            delete votes[tokenId][gauge];
            IReward(gaugeToBribe[gauge])._withdraw(amount, tokenId);
            emit Abstained(tokenId, amount);
        }
        delete poolVote[tokenId];
        usedWeights[tokenId] = 0;
    }

    function _addVote(uint256 tokenId, address gauge, uint256 amount, uint64 cycle) private {
        poolVote[tokenId].push(gauge);
        votes[tokenId][gauge] = amount;
        weights[gauge] += amount;
        totalWeight += amount;
        cycleWeights[cycle][gauge] += amount;
        cycleTotalWeight[cycle] += amount;
        IReward(gaugeToBribe[gauge])._deposit(amount, tokenId);
    }
}
