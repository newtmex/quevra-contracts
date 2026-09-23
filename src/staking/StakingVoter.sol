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
        // Best-effort. Stake still in a Monad withdrawal stays pending and does not revert the vote.
        _rebalance(tokenId);
    }

    /// @notice Permissionlessly settle matured withdrawals and move `tokenId` toward its latest vote.
    /// @dev Surpluses are unstaked before deficits are funded. A deficit whose MON is still pending
    ///      withdrawal is left unresolved so a later call can follow the vote that is current then.
    function rebalance(uint256 tokenId) external override nonReentrant {
        _rebalance(tokenId);
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

    function _rebalance(uint256 tokenId) private {
        _settle(tokenId);

        address[] memory gauges = _reconcileGauges(tokenId);
        uint256 count = gauges.length;
        if (count == 0) return;

        address[] memory unstakeGauges = new address[](count);
        uint256[] memory unstakeAmounts = new uint256[](count);
        uint256 unstakeCount;
        for (uint256 i; i < count; ++i) {
            uint256 current = controller.allocationOf(tokenId, gauges[i]);
            uint256 target = votes[tokenId][gauges[i]].stakeAmount;
            if (current <= target) continue;
            uint256 executable = controller.executableUnstake(tokenId, gauges[i], current - target);
            if (executable == 0) continue;
            unstakeGauges[unstakeCount] = gauges[i];
            unstakeAmounts[unstakeCount] = executable;
            unchecked {
                ++unstakeCount;
            }
        }
        if (unstakeCount != 0) {
            assembly {
                mstore(unstakeGauges, unstakeCount)
                mstore(unstakeAmounts, unstakeCount)
            }
            controller.unstake(tokenId, unstakeGauges, unstakeAmounts);
        }

        uint256 liquid = controller.balanceOf(tokenId);
        if (liquid == 0) return;

        address[] memory stakeGauges = new address[](count);
        uint256[] memory stakeAmounts = new uint256[](count);
        uint256 stakeCount;
        for (uint256 i; i < count; ++i) {
            if (liquid == 0) break;
            uint256 current = controller.allocationOf(tokenId, gauges[i]);
            uint256 target = votes[tokenId][gauges[i]].stakeAmount;
            if (current >= target) continue;
            uint256 desired = target - current;
            if (desired > liquid) desired = liquid;
            desired = controller.executableStake(gauges[i], desired);
            if (desired == 0) continue;
            stakeGauges[stakeCount] = gauges[i];
            stakeAmounts[stakeCount] = desired;
            liquid -= desired;
            unchecked {
                ++stakeCount;
            }
        }
        if (stakeCount == 0) return;
        assembly {
            mstore(stakeGauges, stakeCount)
            mstore(stakeAmounts, stakeCount)
        }
        controller.stake(tokenId, stakeGauges, stakeAmounts);
    }

    function _settle(uint256 tokenId) private {
        address[] memory allocated = controller.allocatedGauges(tokenId);
        uint256 length = allocated.length;
        if (length == 0) return;
        address[] memory ready = new address[](length);
        uint256 count;
        for (uint256 i; i < length; ++i) {
            if (!controller.withdrawalReady(tokenId, allocated[i])) continue;
            ready[count] = allocated[i];
            unchecked {
                ++count;
            }
        }
        if (count == 0) return;
        assembly {
            mstore(ready, count)
        }
        controller.withdraw(tokenId, ready);
    }

    /// @dev Current votes plus gauges that still hold stake from a vote that has since been replaced.
    function _reconcileGauges(uint256 tokenId) private view returns (address[] memory gauges) {
        address[] memory voted = poolVote[tokenId];
        address[] memory allocated = controller.allocatedGauges(tokenId);
        gauges = new address[](voted.length + allocated.length);
        uint256 count;
        for (uint256 i; i < voted.length; ++i) {
            gauges[count++] = voted[i];
        }
        for (uint256 i; i < allocated.length; ++i) {
            if (_contains(voted, allocated[i])) continue;
            gauges[count++] = allocated[i];
        }
        assembly {
            mstore(gauges, count)
        }
    }

    function _contains(address[] memory gauges, address gauge) private pure returns (bool) {
        for (uint256 i; i < gauges.length; ++i) {
            if (gauges[i] == gauge) return true;
        }
        return false;
    }
}
