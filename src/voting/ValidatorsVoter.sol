// SPDX-License-Identifier: BUSL-1.1
// Adapted from Tigris ValidatorsVoter.sol (BUSL-1.1).
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IValidatorsVoter} from "../interfaces/IValidatorsVoter.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {IVeMON} from "../interfaces/IVeMON.sol";
import {IVotingEscrowBooster} from "../interfaces/IVotingEscrowBooster.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {BoostLibrary} from "../libraries/BoostLibrary.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";
import {NonStakingVoter} from "./NonStakingVoter.sol";

/// @title ValidatorsVoter
/// @author Adapted from Tigris contributors
/// @notice Allocates veMON voting power to validator gauges in proportion to
///         each veMON NFT's active MON stake and distributes gauge bribes.
/// @dev StakingController synchronizes physical allocation changes; holders do
///      not cast or reset votes separately.
contract ValidatorsVoter is NonStakingVoter, IValidatorsVoter, UUPSUpgradeable {
    uint256 public constant BOOST_PRECISION = BoostLibrary.PRECISION;
    uint256 public constant MAX_BOOST = 5 * BoostLibrary.PRECISION;

    /// @custom:storage-location erc7201:quevra.ValidatorsVoter
    struct ValidatorsVoterStorage {
        address boostableVe;
        address gaugeBeacon;
        address bribeBeacon;
        mapping(uint256 tokenId => address gauge) boostableTokenIdToGauge;
        mapping(address gauge => address vault) gaugeToVault;
        mapping(address vault => address gauge) vaultToGauge;
        mapping(uint256 tokenId => mapping(address gauge => uint256 indexPlusOne)) gaugeVoteIndex;
    }

    bytes32 private constant VALIDATORS_VOTER_STORAGE_SLOT =
        0x5ba8fa3f0846c0f2d8c968f46b5ef017cd4fb9c4eda245b1225370e26fedb500;

    function _validatorsVoterStorage() internal pure returns (ValidatorsVoterStorage storage $) {
        bytes32 slot = VALIDATORS_VOTER_STORAGE_SLOT;
        assembly ("memory-safe") { $.slot := slot }
    }

    /// @inheritdoc IValidatorsVoter
    function boostableVe() public view override returns (address) {
        return _validatorsVoterStorage().boostableVe;
    }

    function gaugeBeacon() public view returns (address) {
        return _validatorsVoterStorage().gaugeBeacon;
    }

    function bribeBeacon() public view returns (address) {
        return _validatorsVoterStorage().bribeBeacon;
    }

    /// @inheritdoc IValidatorsVoter
    function boostableTokenIdToGauge(uint256 tokenId) public view override returns (address) {
        return _validatorsVoterStorage().boostableTokenIdToGauge[tokenId];
    }

    /// @inheritdoc IValidatorsVoter
    function gaugeToVault(address gauge) public view override returns (address) {
        return _validatorsVoterStorage().gaugeToVault[gauge];
    }

    function vaultToGauge(address vault) public view returns (address) {
        return _validatorsVoterStorage().vaultToGauge[vault];
    }

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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address votingVe_,
        // Zero intentionally supports the cycle-safe one-time binding after VeValidator deployment.
        address boostableVe_,
        address owner_,
        address gaugeBeacon_,
        address bribeBeacon_
    ) external initializer {
        if (
            gaugeBeacon_ == address(0) || bribeBeacon_ == address(0) || gaugeBeacon_.code.length == 0
                || bribeBeacon_.code.length == 0
        ) revert ZeroAddress();
        if (boostableVe_ != address(0) && boostableVe_.code.length == 0) revert ZeroAddress();
        __NonStakingVoter_init(votingVe_, owner_);
        // `NonStakingVoter` validates the voting escrow and owner. The
        // boostable escrow may be bound after deployment to break the
        // veValidator/ValidatorsVoter deployment cycle.
        _validatorsVoterStorage().boostableVe = boostableVe_;
        _validatorsVoterStorage().gaugeBeacon = gaugeBeacon_;
        _validatorsVoterStorage().bribeBeacon = bribeBeacon_;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @inheritdoc IValidatorsVoter
    function setBoostableVe(address boostableVe_) external override onlyOwner {
        if (_validatorsVoterStorage().boostableVe != address(0) || boostableVe_ == address(0)) {
            revert BoostableVeAlreadySet();
        }
        _validatorsVoterStorage().boostableVe = boostableVe_;
    }

    /// @inheritdoc IValidatorsVoter
    function createBoostGauge(uint256 boostableTokenId, address rewardToken)
        external
        virtual
        override
        nonReentrant
        returns (address gauge)
    {
        _requireGaugeCreator(boostableTokenId);
        if (!_voterStorage().isWhitelistedToken[rewardToken]) revert NotWhitelistedToken();
        gauge = _createBoostGauge(boostableTokenId, rewardToken);
    }

    /// @inheritdoc IValidatorsVoter
    function createBoostGauge(uint256 boostableTokenId, address rewardToken, address vault)
        external
        virtual
        override
        nonReentrant
        returns (address gauge)
    {
        if (vault == address(0)) revert ZeroAddress();
        _requireGaugeCreator(boostableTokenId);
        if (!_voterStorage().isWhitelistedToken[rewardToken]) revert NotWhitelistedToken();
        gauge = _createBoostGauge(boostableTokenId, rewardToken);
        _validatorsVoterStorage().gaugeToVault[gauge] = vault;
        _validatorsVoterStorage().vaultToGauge[vault] = gauge;
    }

    /// @notice Creates and registers the gauge and bribe rewards for a boostable position.
    /// @dev Override this hook to use protocol-specific gauge and reward factories.
    function _createBoostGauge(uint256 boostableTokenId, address rewardToken) internal virtual returns (address gauge) {
        if (_validatorsVoterStorage().boostableVe == address(0)) revert ZeroAddress();
        if (_validatorsVoterStorage().boostableTokenIdToGauge[boostableTokenId] != address(0)) {
            revert GaugeExistsForLock();
        }

        // forge-lint: disable-next-line(unused-return)
        (int128 amount, uint256 end, bool isPermanent,) =
            IVotingEscrow(_validatorsVoterStorage().boostableVe).locked(boostableTokenId);
        if (amount < 0 || (!isPermanent && amount == 0)) revert LockDoesNotExist();
        if (!isPermanent && end <= _currentEpoch()) revert LockExpired();

        gauge = address(new BeaconProxy(_validatorsVoterStorage().gaugeBeacon, bytes("")));
        (bool gaugeOk,) = gauge.call(
            abi.encodeWithSignature(
                "initialize(address,address,address)",
                rewardToken,
                address(this),
                IVotingEscrow(_validatorsVoterStorage().boostableVe).ownerOf(boostableTokenId)
            )
        );
        if (!gaugeOk) revert ZeroAddress();
        address bribeVotingRewards = address(new BeaconProxy(_validatorsVoterStorage().bribeBeacon, bytes("")));
        (bool bribeOk,) = bribeVotingRewards.call(
            abi.encodeWithSignature("initialize(address,address[])", address(this), new address[](0))
        );
        if (!bribeOk) revert ZeroAddress();
        _validatorsVoterStorage().boostableTokenIdToGauge[boostableTokenId] = gauge;
        _registerGauge(gauge, bribeVotingRewards);
        emit BoostGaugeCreated(boostableTokenId, gauge, rewardToken);
        emit BribeVotingRewardsCreated(boostableTokenId, bribeVotingRewards);
    }

    /// @inheritdoc IValidatorsVoter
    function poke(uint256 boostableTokenId) external override nonReentrant {
        _pokeBoost(boostableTokenId);
    }

    /// @inheritdoc IValidatorsVoter
    function pokeBoost(uint256 boostableTokenId) external override nonReentrant {
        _pokeBoost(boostableTokenId);
    }

    /// @inheritdoc IValidatorsVoter
    function pokeMany(uint256[] calldata boostableTokenIds) external override nonReentrant {
        for (uint256 i; i < boostableTokenIds.length; ++i) {
            _pokeBoost(boostableTokenIds[i]);
        }
    }

    /// @inheritdoc IValidatorsVoter
    function pokeBoosts(uint256[] calldata boostableTokenIds) external override nonReentrant {
        for (uint256 i; i < boostableTokenIds.length; ++i) {
            _pokeBoost(boostableTokenIds[i]);
        }
    }

    /// @inheritdoc IValidatorsVoter
    function getBoost(uint256 boostableTokenId) public view virtual override returns (uint256) {
        return _getBoost(boostableTokenId);
    }

    /// @dev Internal boost calculation hook, matching the extensible Tigris voter API.
    function _getBoost(uint256 boostableTokenId) internal view virtual returns (uint256) {
        address target = _validatorsVoterStorage().boostableTokenIdToGauge[boostableTokenId];
        uint256 votingTotal = IVotingEscrow(ve()).totalVotingPower();
        uint256 targetWeight = _voterStorage().weights[target];
        uint256 targetPower =
            IVotingEscrow(_validatorsVoterStorage().boostableVe).unboostedVotingPowerOf(boostableTokenId);
        uint256 targetTotal = IVotingEscrow(_validatorsVoterStorage().boostableVe).unboostedTotalVotingPower();
        if (target == address(0) || votingTotal == 0 || targetWeight == 0 || targetPower == 0) {
            return BoostLibrary.PRECISION;
        }

        uint256 votingRatio = targetWeight * BoostLibrary.PRECISION / votingTotal;
        uint256 targetRatio = targetTotal * BoostLibrary.PRECISION / targetPower;
        uint256 boost = BoostLibrary.PRECISION + 4 * Math.mulDiv(targetRatio, votingRatio, BoostLibrary.PRECISION);
        return Math.min(MAX_BOOST, boost);
    }

    /// @inheritdoc IValidatorsVoter
    function notifyBoostableBurned(uint256 boostableTokenId) external virtual override {
        if (msg.sender != _validatorsVoterStorage().boostableVe) revert NotBoostableVe();
        address target = _validatorsVoterStorage().boostableTokenIdToGauge[boostableTokenId];
        if (target == address(0)) return;
        delete _validatorsVoterStorage().boostableTokenIdToGauge[boostableTokenId];
        address vault = _validatorsVoterStorage().gaugeToVault[target];
        delete _validatorsVoterStorage().gaugeToVault[target];
        delete _validatorsVoterStorage().vaultToGauge[vault];
        _unregisterGauge(target);
        emit BoostableTokenBurned(boostableTokenId, target);
    }

    /// @inheritdoc IValidatorsVoter
    function syncStakeAllocation(uint256 tokenId, address vault, uint256 allocation) external override nonReentrant {
        if (msg.sender != IVeMON(ve()).controller()) revert NotStakingController();
        address gauge = _validatorsVoterStorage().vaultToGauge[vault];
        if (gauge == address(0)) revert GaugeVaultNotSet(vault);

        (uint256 votingPower, int128 lockedAmount) = IVotingEscrow(ve()).votingPowerAndLockedAmount(tokenId);
        uint256 principal = lockedAmount > 0 ? uint256(uint128(lockedAmount)) : 0;
        // Allocate only the fraction of the veMON NFT's voting power backed by
        // its currently allocated MON. Unstaked principal does not vote.
        uint256 newWeight = principal == 0 ? 0 : Math.mulDiv(votingPower, Math.min(allocation, principal), principal);
        uint256 oldWeight = _voterStorage().votes[tokenId][gauge];

        if (newWeight > oldWeight) {
            uint256 increase = newWeight - oldWeight;
            _voterStorage().weights[gauge] += increase;
            _voterStorage().usedWeights[tokenId] += increase;
            _notifyGaugeWeight(gauge, increase, tokenId);
        } else if (oldWeight > newWeight) {
            uint256 decrease = oldWeight - newWeight;
            _voterStorage().weights[gauge] -= decrease;
            _voterStorage().usedWeights[tokenId] -= decrease;
            _withdrawGaugeWeight(gauge, decrease, tokenId);
        }

        if (oldWeight == 0 && newWeight != 0) {
            _voterStorage().gaugeVote[tokenId].push(gauge);
            _validatorsVoterStorage().gaugeVoteIndex[tokenId][gauge] = _voterStorage().gaugeVote[tokenId].length;
        } else if (oldWeight != 0 && newWeight == 0) {
            _removeGaugeVote(tokenId, gauge);
        }

        _voterStorage().votes[tokenId][gauge] = newWeight;
        emit StakeVoteSynced(tokenId, gauge, allocation, oldWeight, newWeight);
    }

    function _requireGaugeCreator(uint256 boostableTokenId) internal view {
        if (
            !IVotingEscrow(_validatorsVoterStorage().boostableVe).isApprovedOrOwner(msg.sender, boostableTokenId)
                && msg.sender != _validatorsVoterStorage().boostableVe
        ) {
            revert NotApprovedOrOwner();
        }
    }

    function _pokeBoost(uint256 boostableTokenId) internal virtual {
        uint256 boost = getBoost(boostableTokenId);
        emit BoostPoked(boostableTokenId, boost);
        IVotingEscrowBooster(_validatorsVoterStorage().boostableVe).updateBoost(boostableTokenId, boost);
    }

    function _removeGaugeVote(uint256 tokenId, address gauge) internal {
        uint256 indexPlusOne = _validatorsVoterStorage().gaugeVoteIndex[tokenId][gauge];
        if (indexPlusOne == 0) return;

        address[] storage gauges = _voterStorage().gaugeVote[tokenId];
        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = gauges.length - 1;
        if (index != lastIndex) {
            address lastGauge = gauges[lastIndex];
            gauges[index] = lastGauge;
            _validatorsVoterStorage().gaugeVoteIndex[tokenId][lastGauge] = index + 1;
        }
        gauges.pop();
        delete _validatorsVoterStorage().gaugeVoteIndex[tokenId][gauge];
    }

    function _currentEpoch() internal virtual returns (uint256 epoch) {
        (epoch,) = ProtocolTimeLibrary.currentEpoch();
    }

    function _validBeacon(address beacon) private view returns (bool) {
        if (beacon == address(0) || beacon.code.length == 0) return false;
        try IBeacon(beacon).implementation() returns (address implementation) {
            return implementation.code.length != 0;
        } catch {
            return false;
        }
    }
}
