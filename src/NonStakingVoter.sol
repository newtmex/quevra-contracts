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

/// @notice Gauge creation and lifecycle hooks shared by validator voters.
/// @dev This carries the Tigris creation dependencies while leaving Quevra's
///      cycle voting and reward accounting in its existing voter contracts.
abstract contract NonStakingVoter is IBaseVoter, ERC2771Context, ReentrancyGuard {
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

    error ZeroAddress();
    error GaugeFactoryNotApproved();
    error GaugeDoesNotExist(address gauge);
    error GaugeAlreadyKilled();
    error NotGovernor();

    event GaugeCreated(address indexed gauge, address indexed bribeVotingReward, address indexed creator);
    event GaugeKilled(address indexed gauge);
    event SplitterSet(address indexed splitter);
    event WhitelistToken(address indexed whitelister, address indexed token, bool indexed whitelisted);

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
}
