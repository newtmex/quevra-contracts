// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBaseVoter} from "../interfaces/IBaseVoter.sol";
import {IFactoryRegistry} from "../interfaces/factories/IFactoryRegistry.sol";
import {IValidatorGaugeFactory} from "../interfaces/factories/IValidatorGaugeFactory.sol";
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
import {IValidatorGauge} from "../interfaces/IValidatorGauge.sol";

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
    StakingController public controller;
    address public governor;
    mapping(address => bool) public override isWhitelistedToken;
    mapping(address => address) public gaugeToBribe;
    mapping(address => bool) public isGauge;
    mapping(address => uint256) public claimable;

    // Voting records are shared across staking voter implementations.
    mapping(uint256 => address[]) public poolVote;
    mapping(uint256 => address[]) private _allocationGauges;
    mapping(uint256 => uint256) public usedWeights;
    mapping(uint256 => mapping(address => VoteAllocation)) public votes;
    /// @dev Desired physical allocation. `votes[tokenId][gauge].stakeAmount`
    ///      is the observed active allocation and is updated by the controller.
    mapping(uint256 => mapping(address => uint256)) public targetStakeAmount;
    /// @notice Active MON supplied by an individual veNFT to a validator.
    /// @dev This excludes controller liquidity and pending undelegations.
    mapping(uint256 => mapping(address => uint256)) public activeStake;
    /// @notice Sum of active tokenId allocations backing a validator gauge.
    mapping(address => uint256) public validatorStakingAmount;
    /// @notice Minimum active MON required before a validator can distribute rewards.
    uint256 public constant MIN_ACTIVE_VALIDATOR_STAKE = 100_000 ether;
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
    error NotController();

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

    function __StakingVoter_init(address ve_, address factoryRegistry_, address controller_) internal {
        if (ve_ == address(0) || factoryRegistry_ == address(0) || controller_ == address(0)) revert ZeroAddress();
        ve = ve_;
        factoryRegistry = factoryRegistry_;
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

    function _createGauge(address gaugeFactory) internal returns (address gauge) {
        IFactoryRegistry registry = IFactoryRegistry(factoryRegistry);
        if (!registry.isGaugeFactoryApproved(gaugeFactory)) revert GaugeFactoryNotApproved();

        address rewardsFactory = registry.gaugeFactoryToVotingRewardsFactory(gaugeFactory);
        gauge = IValidatorGaugeFactory(gaugeFactory).createValidatorGauge(forwarder);
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
        (uint256 power, uint256 principal) = _votingInputs(tokenId);
        if (requested == 0 || power == 0 || principal == 0) revert InvalidVote();

        _rememberCurrentGauges(tokenId);
        _rememberGauges(tokenId, gauges);
        _reset(tokenId, cycle);
        _addVoteAllocations(tokenId, gauges, weights_, requested, power, principal, cycle);
        usedWeights[tokenId] = power;
        lastVotedCycle[tokenId] = cycle;
        emit Voted(_msgSender(), tokenId, power);
    }

    /// @notice Progress the token's physical allocation toward its latest vote.
    /// @dev Settlement is intentionally best-effort; pending Monad withdrawals
    ///      can leave a deficit for a later call.
    function rebalance(uint256 tokenId) external nonReentrant {
        address[] storage stored = _allocationGauges[tokenId];
        if (stored.length == 0) return;

        address[] memory gauges = new address[](stored.length);
        for (uint256 i; i < stored.length; ++i) {
            gauges[i] = stored[i];
        }
        try controller.withdraw(tokenId, gauges) {} catch {}

        address[] memory surplusGauges = new address[](stored.length);
        uint256[] memory surplus = new uint256[](stored.length);
        address[] memory deficitGauges = new address[](stored.length);
        uint256[] memory deficit = new uint256[](stored.length);
        uint256 surplusCount;
        uint256 deficitCount;
        uint256 liquid = controller.balanceOf(tokenId);

        for (uint256 i; i < stored.length; ++i) {
            address gauge = stored[i];
            uint256 current = controller.allocationOf(tokenId, gauge);
            uint256 target = targetStakeAmount[tokenId][gauge];
            if (current > target) {
                surplusGauges[surplusCount] = gauge;
                surplus[surplusCount++] = current - target;
            } else if (current < target) {
                uint256 amount = target - current;
                if (amount > liquid) amount = liquid;
                if (amount != 0) {
                    deficitGauges[deficitCount] = gauge;
                    deficit[deficitCount++] = amount;
                    liquid -= amount;
                }
            }
        }
        assembly {
            mstore(surplusGauges, surplusCount)
            mstore(surplus, surplusCount)
            mstore(deficitGauges, deficitCount)
            mstore(deficit, deficitCount)
        }
        if (surplusCount != 0) {
            try controller.unstake(tokenId, surplusGauges, surplus) {} catch {}
        }
        if (deficitCount != 0) {
            try controller.stake(tokenId, deficitGauges, deficit) {} catch {}
        }
    }

    /// @notice Record a physical allocation change reported by the controller.
    function updateStakingAmount(uint256 tokenId, address gauge, int256 delta) external {
        if (msg.sender != address(controller)) revert NotController();

        // The veNFT represents MON that is actually deployed to a validator,
        // not MON that is merely waiting in the controller. Update it before
        // exposing the amount to the validator gauge.
        IVotingEscrow(ve).adjustLockAmount(tokenId, delta);
        VoteAllocation storage allocation = votes[tokenId][gauge];
        // A controller allocation may exist before a token has voted for this
        // gauge. Active-liquidity accounting must not depend on vote metadata.
        if (allocation.weight != 0) {
            if (delta > 0) {
                allocation.stakeAmount = _toUint128(uint256(allocation.stakeAmount) + uint256(delta));
            } else {
                uint256 decrease = uint256(-delta);
                if (decrease > allocation.stakeAmount) revert InvalidVote();
                allocation.stakeAmount = uint128(uint256(allocation.stakeAmount) - decrease);
            }
        }

        uint256 previous = activeStake[tokenId][gauge];
        uint256 next;
        if (delta > 0) {
            next = previous + uint256(delta);
            validatorStakingAmount[gauge] += uint256(delta);
        } else {
            uint256 decrease = uint256(-delta);
            if (decrease > previous) revert InvalidVote();
            next = previous - decrease;
            validatorStakingAmount[gauge] -= decrease;
        }
        activeStake[tokenId][gauge] = next;
        // Monad's staking precompile is not re-entrant during validator
        // activation. The active accounting above is authoritative; a gauge
        // checkpoint can be retried by the next lifecycle action if needed.
        try IValidatorGauge(gauge).updateLiquidity(tokenId, next) {} catch {}
    }

    function isValidatorRewardEligible(address gauge) public view returns (bool) {
        return isGauge[gauge] && validatorStakingAmount[gauge] >= MIN_ACTIVE_VALIDATOR_STAKE;
    }

    function _rememberGauge(uint256 tokenId, address gauge) private {
        address[] storage gauges = _allocationGauges[tokenId];
        for (uint256 i; i < gauges.length; ++i) {
            if (gauges[i] == gauge) return;
        }
        gauges.push(gauge);
    }

    function _rememberCurrentGauges(uint256 tokenId) private {
        address[] storage current = poolVote[tokenId];
        for (uint256 i; i < current.length; ++i) {
            _rememberGauge(tokenId, current[i]);
        }
    }

    function _rememberGauges(uint256 tokenId, address[] calldata gauges) private {
        for (uint256 i; i < gauges.length; ++i) {
            _rememberGauge(tokenId, gauges[i]);
        }
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

    function _votingInputs(uint256 tokenId) private view returns (uint256 power, uint256 principal) {
        power = IVotingEscrow(ve).votingPowerOf(tokenId);
        (int128 lockedAmount, uint256 lockEnd,,) = IVotingEscrow(ve).locked(tokenId);
        if (lockedAmount > 0) return (power, uint256(uint128(lockedAmount)));

        // A freshly-created veNFT has MON waiting in the controller but no
        // locked amount until that MON is deployed to a validator. Allow its
        // owner to vote using the pending deposit so the vote can select the
        // validator that will receive the deposit.
        principal = controller.balanceOf(tokenId);
        (uint64 currentEpoch,) = ProtocolTimeLibrary.currentEpochView();
        uint64 maxLockEpochs = IVotingEscrow(ve).maxLockEpochs();
        power = lockEnd > currentEpoch ? principal * (lockEnd - currentEpoch) / maxLockEpochs : 0;
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
            delete targetStakeAmount[tokenId][gauge];
            IReward(gaugeToBribe[gauge])._withdraw(allocation.weight, tokenId);
            emit Abstained(tokenId, allocation.weight);
        }
        delete poolVote[tokenId];
        usedWeights[tokenId] = 0;
    }

    function _addVote(uint256 tokenId, address gauge, uint256 weight, uint256 stakeAmount, uint64 cycle) private {
        poolVote[tokenId].push(gauge);
        votes[tokenId][gauge] = VoteAllocation(_toUint128(weight), 0);
        targetStakeAmount[tokenId][gauge] = stakeAmount;
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
