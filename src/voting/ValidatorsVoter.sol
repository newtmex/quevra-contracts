// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IValidatorsVoter} from "../interfaces/IValidatorsVoter.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {IVeMON} from "../interfaces/IVeMON.sol";
import {IVotingEscrowBooster} from "../interfaces/IVotingEscrowBooster.sol";
import {IStakingController} from "../interfaces/IStakingController.sol";
import {NonStakingGauge} from "../gauges/NonStakingGauge.sol";
import {BribeVotingRewards} from "../rewards/BribeVotingRewards.sol";
import {BoostLibrary} from "../libraries/BoostLibrary.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";
import {NonStakingVoter} from "./NonStakingVoter.sol";

/// @title ValidatorsVoter
/// @notice Allocates voting veMON power to veMON positions and refreshes their boost.
/// @dev Gauge creation and reward funding live in the voter. Gauges own reward
///      accounting and payout, while this contract only allocates boost power.
contract ValidatorsVoter is NonStakingVoter, IValidatorsVoter {
    uint256 public constant BOOST_PRECISION = BoostLibrary.PRECISION;
    uint256 public constant MAX_BOOST = 5 * BoostLibrary.PRECISION;

    address public override boostableVe;

    mapping(uint256 tokenId => address gauge) public override boostableTokenIdToGauge;
    mapping(address gauge => address vault) public override gaugeToVault;
    mapping(address vault => address gauge) public vaultToGauge;
    mapping(uint256 tokenId => mapping(address gauge => uint256 amount)) public stakeRewardWeight;

    event BoostGaugeCreated(uint256 indexed boostableTokenId, address indexed gauge, address indexed rewardToken);
    event BribeVotingRewardsCreated(uint256 indexed boostableTokenId, address indexed bribeVotingRewards);
    event BoostPoked(uint256 indexed boostableTokenId, uint256 boost);
    event BoostableTokenBurned(uint256 indexed boostableTokenId, address indexed gauge);

    error GaugeExistsForLock();
    error NotBoostableVe();
    error LockDoesNotExist();
    error LockExpired();
    error BoostableVeAlreadySet();
    error GaugeVaultNotSet(address gauge);
    error NotStakingController();

    constructor(address votingVe_, address boostableVe_, address owner_) NonStakingVoter(votingVe_, owner_) {
        // `NonStakingVoter` validates the voting escrow and owner. The
        // boostable escrow may be bound after deployment to break the
        // veValidator/ValidatorsVoter deployment cycle.
        boostableVe = boostableVe_;
    }

    function setBoostableVe(address boostableVe_) external override onlyOwner {
        if (boostableVe != address(0) || boostableVe_ == address(0)) revert BoostableVeAlreadySet();
        boostableVe = boostableVe_;
    }

    function createBoostGauge(uint256 boostableTokenId, address rewardToken)
        external
        virtual
        override
        nonReentrant
        returns (address gauge)
    {
        _requireGaugeCreator(boostableTokenId);
        if (!isWhitelistedToken[rewardToken]) revert NotWhitelistedToken();
        gauge = _createBoostGauge(boostableTokenId, rewardToken);
    }

    /// @notice Create a validator gauge and bind it to the vault it represents.
    function createBoostGauge(uint256 boostableTokenId, address rewardToken, address vault)
        external
        virtual
        override
        nonReentrant
        returns (address gauge)
    {
        if (vault == address(0)) revert ZeroAddress();
        _requireGaugeCreator(boostableTokenId);
        if (!isWhitelistedToken[rewardToken]) revert NotWhitelistedToken();
        gauge = _createBoostGauge(boostableTokenId, rewardToken);
        gaugeToVault[gauge] = vault;
        vaultToGauge[vault] = gauge;
    }

    /// @notice Creates and registers the gauge and bribe rewards for a boostable position.
    /// @dev Override this hook to use protocol-specific gauge and reward factories.
    function _createBoostGauge(uint256 boostableTokenId, address rewardToken) internal virtual returns (address gauge) {
        if (boostableVe == address(0)) revert ZeroAddress();
        if (boostableTokenIdToGauge[boostableTokenId] != address(0)) revert GaugeExistsForLock();

        (int128 amount, uint256 end, bool isPermanent,) = IVotingEscrow(boostableVe).locked(boostableTokenId);
        if (amount < 0 || (!isPermanent && amount == 0)) revert LockDoesNotExist();
        if (!isPermanent && end <= _currentEpoch()) revert LockExpired();

        gauge = address(
            new NonStakingGauge(rewardToken, address(this), IVotingEscrow(boostableVe).ownerOf(boostableTokenId))
        );
        address bribeVotingRewards = address(new BribeVotingRewards(address(this), new address[](0)));
        boostableTokenIdToGauge[boostableTokenId] = gauge;
        _registerGauge(gauge, bribeVotingRewards);
        emit BoostGaugeCreated(boostableTokenId, gauge, rewardToken);
        emit BribeVotingRewardsCreated(boostableTokenId, bribeVotingRewards);
    }

    function poke(uint256 boostableTokenId) external override nonReentrant {
        _pokeBoost(boostableTokenId);
    }

    function pokeBoost(uint256 boostableTokenId) external override nonReentrant {
        _pokeBoost(boostableTokenId);
    }

    function pokeMany(uint256[] calldata boostableTokenIds) external override nonReentrant {
        for (uint256 i; i < boostableTokenIds.length; ++i) {
            _pokeBoost(boostableTokenIds[i]);
        }
    }

    function pokeBoosts(uint256[] calldata boostableTokenIds) external override nonReentrant {
        for (uint256 i; i < boostableTokenIds.length; ++i) {
            _pokeBoost(boostableTokenIds[i]);
        }
    }

    function getBoost(uint256 boostableTokenId) public view virtual override returns (uint256) {
        return _getBoost(boostableTokenId);
    }

    /// @dev Internal boost calculation hook, matching the extensible Tigris voter API.
    function _getBoost(uint256 boostableTokenId) internal view virtual returns (uint256) {
        address target = boostableTokenIdToGauge[boostableTokenId];
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

    function notifyBoostableBurned(uint256 boostableTokenId) external virtual override {
        if (msg.sender != boostableVe) revert NotBoostableVe();
        address target = boostableTokenIdToGauge[boostableTokenId];
        if (target == address(0)) return;
        delete boostableTokenIdToGauge[boostableTokenId];
        address vault = gaugeToVault[target];
        delete gaugeToVault[target];
        delete vaultToGauge[vault];
        _unregisterGauge(target);
        emit BoostableTokenBurned(boostableTokenId, target);
    }

    /// @notice Syncs this token's bribe weight after its controller allocation changes.
    function syncStakeWeight(uint256 tokenId, address vault) external override {
        if (msg.sender != IVeMON(ve).controller()) revert NotStakingController();
        address gauge = vaultToGauge[vault];
        if (gauge == address(0)) revert GaugeVaultNotSet(vault);

        IStakingController controller = IStakingController(msg.sender);
        uint256 newWeight = controller.isValidatorActive(vault) && controller.allocationOf(tokenId, vault) != 0
            ? votes[tokenId][gauge]
            : 0;
        uint256 oldWeight = stakeRewardWeight[tokenId][gauge];
        if (newWeight > oldWeight) {
            _notifyGaugeWeight(gauge, newWeight - oldWeight, tokenId);
        } else if (oldWeight > newWeight) {
            _withdrawGaugeWeight(gauge, oldWeight - newWeight, tokenId);
        }
        stakeRewardWeight[tokenId][gauge] = newWeight;
    }

    function _requireGaugeCreator(uint256 boostableTokenId) internal view {
        if (!IVotingEscrow(boostableVe).isApprovedOrOwner(msg.sender, boostableTokenId) && msg.sender != boostableVe) {
            revert NotApprovedOrOwner();
        }
    }

    function _pokeBoost(uint256 boostableTokenId) internal virtual {
        uint256 boost = getBoost(boostableTokenId);
        emit BoostPoked(boostableTokenId, boost);
        IVotingEscrowBooster(boostableVe).updateBoost(boostableTokenId, boost);
    }

    function _currentEpoch() internal virtual returns (uint256 epoch) {
        (epoch,) = ProtocolTimeLibrary.currentEpoch();
    }
}
