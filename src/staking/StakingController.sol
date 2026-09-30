// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IValidatorRegistry} from "../interfaces/IValidatorRegistry.sol";
import {IStakingController} from "../interfaces/IStakingController.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {StakingVault} from "./controlled/StakingVault.sol";
import {StakingAgent} from "./controlled/StakingAgent.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";
import {ValidatorPayloadLibrary} from "../libraries/ValidatorPayloadLibrary.sol";

/// @title StakingController
/// @notice Owns validator vaults and routes MON deposits through the bound vault.
/// @dev User-selected allocations are intent; this contract only settles
///      physical MON toward that intent.
contract StakingController is Ownable2Step, ReentrancyGuardTransient, IStakingController {
    IValidatorRegistry public immutable override registry;
    address public override ve;
    address public immutable override vaultImplementation;
    address public immutable override agentImplementation;
    mapping(address gauge => address vault) public override vaultByGauge;
    mapping(address vault => address gauge) public gaugeByVault;
    mapping(address => bool) private _isVault;
    mapping(address => bool) private _isAgent;
    mapping(uint256 tokenId => uint256 amount) public override balanceOf;
    mapping(uint256 tokenId => address agent) public override agentByToken;
    mapping(uint256 tokenId => address[]) private _tokenGauges;
    mapping(uint256 tokenId => mapping(address gauge => uint256 indexPlusOne)) private _tokenGaugeIndex;
    mapping(uint256 tokenId => address[]) private _pendingGauges;
    mapping(uint256 tokenId => mapping(address gauge => uint256 indexPlusOne)) private _pendingGaugeIndex;
    uint256 private _commission;
    uint256 private _pendingCommission;
    uint64 private _pendingCommissionCycle;

    /// @notice Fixed stake amount committed to validator registration signatures.
    uint256 public constant VALIDATOR_STAKE_AMOUNT = 100_000 ether;
    /// @notice Maximum commission accepted by Monad's staking precompile (100%, scaled by 1e18).
    uint256 public constant MAX_COMMISSION = 1e18;

    constructor(address registry_, address owner_, uint256 initialCommission_) Ownable(owner_) {
        if (registry_ == address(0) || owner_ == address(0)) revert InvalidAddress();
        if (initialCommission_ > MAX_COMMISSION) revert InvalidCommission();
        registry = IValidatorRegistry(registry_);
        _commission = initialCommission_;
        vaultImplementation = address(new StakingVault());
        agentImplementation = address(new StakingAgent());
    }

    /// @notice Bind veMON once. The owner sets this after both contracts are deployed.
    function setVe(address ve_) external override onlyOwner {
        if (ve != address(0)) revert VeAlreadySet();
        if (ve_ == address(0)) revert InvalidAddress();
        ve = ve_;
        emit VeSet(ve_);
    }

    /// @notice Deploy, initialize, and register a vault for a validator request.
    function deployVault(
        uint256 requestId,
        address requester,
        bytes32 saltSeed,
        address expectedAuthAddress,
        address gauge
    ) external override returns (address vault) {
        if (msg.sender != requester) revert NotRequester();
        if (requester == address(0) || gauge == address(0) || vaultByGauge[gauge] != address(0)) {
            revert InvalidVault();
        }

        IValidatorRegistry.Submission memory submission = registry.getSubmission(requestId);
        if (submission.requester != requester || submission.status != IValidatorRegistry.Status.Submitted) {
            revert InvalidValidatorState();
        }
        if (ValidatorPayloadLibrary.authAddress(submission.payload) != expectedAuthAddress) {
            revert UnexpectedAuthAddress();
        }
        if (predictVaultAddress(requester, saltSeed) != expectedAuthAddress) {
            revert UnexpectedAuthAddress();
        }

        bytes32 salt = _vaultSalt(requester, saltSeed);
        vault = Clones.cloneDeterministic(vaultImplementation, salt);
        StakingVault(payable(vault)).initialize(address(registry), requestId);
        vaultByGauge[gauge] = vault;
        gaugeByVault[vault] = gauge;
        _isVault[vault] = true;
        emit VaultRegistered(requestId, vault, gauge, requester);
    }

    function predictVaultAddress(address requester, bytes32 saltSeed) public view override returns (address) {
        return Clones.predictDeterministicAddress(vaultImplementation, _vaultSalt(requester, saltSeed), address(this));
    }

    function predictAgentAddress(uint256 tokenId) public view override returns (address) {
        return Clones.predictDeterministicAddress(agentImplementation, bytes32(tokenId), address(this));
    }

    function _vaultSalt(address requester, bytes32 saltSeed) private pure returns (bytes32) {
        return keccak256(abi.encode(requester, saltSeed));
    }

    /// @notice Schedule commission for the cycle two cycles after the current cycle.
    function setCommission(uint256 commission_) external override onlyOwner {
        if (commission_ > MAX_COMMISSION) revert InvalidCommission();
        uint64 effectiveCycle = ProtocolTimeLibrary.currentCycle() + 2;
        _pendingCommission = commission_;
        _pendingCommissionCycle = effectiveCycle;
        emit ValidatorCommissionSet(commission_);
        emit ValidatorCommissionScheduled(commission_, effectiveCycle);
    }

    /// @notice Configuration to sign BEFORE requesting a validator.
    /// @dev Submit the returned authAddress as expectedAuthAddress.
    function signingConfigFor(address requester, bytes32 saltSeed)
        external
        override
        returns (address authAddress, uint256 commission_, uint256 amount)
    {
        if (ve == address(0) || requester == address(0)) revert InvalidAddress();
        authAddress = predictVaultAddress(requester, saltSeed);
        return (authAddress, _effectiveCommission(), VALIDATOR_STAKE_AMOUNT);
    }

    function _effectiveCommission() private returns (uint256) {
        uint64 pendingCycle = _pendingCommissionCycle;
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        if (pendingCycle != 0 && ProtocolTimeLibrary.cycleOf(epoch) >= pendingCycle) {
            _commission = _pendingCommission;
            _pendingCommission = 0;
            _pendingCommissionCycle = 0;
        }
        return _commission;
    }

    function commission() external override returns (uint256) {
        return _effectiveCommission();
    }

    function deposit(uint256 tokenId) external payable override nonReentrant {
        if (ve == address(0) || msg.sender != ve) revert NotVe();
        if (msg.value == 0) revert InvalidDepositAmount();
        balanceOf[tokenId] += msg.value;
        emit MONDeposited(tokenId, msg.value);
    }

    function allocationOf(uint256 tokenId, address gauge) external view override returns (uint256 allocation) {
        allocation = _allocationOf(tokenId, gauge);
    }

    function isValidatorActive(address gauge) external view override returns (bool) {
        address vault = vaultByGauge[gauge];
        return vault != address(0) && StakingVault(payable(vault)).validatorId() != 0;
    }

    function pendingOf(uint256 tokenId, address gauge) external view returns (uint256 pending) {
        pending = _pendingOf(tokenId, gauge);
    }

    function isFullyUnstaked(uint256 tokenId) external view override returns (bool) {
        return _isFullyUnstaked(tokenId);
    }

    function _isFullyUnstaked(uint256 tokenId) internal view returns (bool) {
        if (_pendingGauges[tokenId].length != 0) return false;
        address[] storage gauges = _tokenGauges[tokenId];
        for (uint256 i; i < gauges.length; ++i) {
            if (_allocationOf(tokenId, gauges[i]) != 0) return false;
        }
        return true;
    }

    /// @dev Receives redeemed MON from a token's vault or agent.
    receive() external payable {
        if (!_isVault[msg.sender] && !_isAgent[msg.sender]) revert UnexpectedEtherSender();
    }

    /// @notice Allocate a token's available MON to validator gauges.
    /// @dev A request's vault is topped up first. Any allocation left after
    ///      activation is delegated by the token-bound agent.
    function stake(uint256 tokenId, address[] calldata gauges, uint256[] calldata amounts)
        external
        override
        nonReentrant
    {
        _requireTokenOwner(tokenId);
        if (gauges.length == 0) revert EmptyArray();
        if (gauges.length != amounts.length) revert LengthMismatch();

        for (uint256 i; i < gauges.length; ++i) {
            if (amounts[i] == 0) revert ZeroAmount();
            if (vaultByGauge[gauges[i]] == address(0)) revert InvalidVault();
            if (_pendingGaugeIndex[tokenId][gauges[i]] != 0) _finalize(tokenId, gauges[i]);
            _rememberTokenGauge(tokenId, gauges[i]);
            if (balanceOf[tokenId] < amounts[i]) revert InsufficientBalance();
            balanceOf[tokenId] -= amounts[i];

            {
                address vault = vaultByGauge[gauges[i]];
                uint256 deficit = StakingVault(payable(vault)).deficit();
                uint256 toVault = amounts[i] < deficit ? amounts[i] : deficit;
                if (toVault != 0) StakingVault(payable(vault)).deposit{value: toVault}(tokenId);

                uint256 remainder = amounts[i] - toVault;
                if (remainder != 0) {
                    uint64 validatorId = StakingVault(payable(vault)).validatorId();
                    if (validatorId == 0) revert ValidatorNotActivated();

                    address agent = agentByToken[tokenId];
                    if (agent == address(0)) {
                        agent = Clones.cloneDeterministic(agentImplementation, bytes32(tokenId));
                        agentByToken[tokenId] = agent;
                        _isAgent[agent] = true;
                        emit AgentCreated(tokenId, agent);
                    }
                    StakingAgent(payable(agent)).delegate{value: remainder}(validatorId, remainder);
                }
            }
        }
        emit Staked(tokenId, _sum(amounts));
    }

    /// @notice Begin reclaiming MON previously allocated by `stake` for a token.
    /// @dev Monad requires undelegation and withdrawal to happen in different
    ///      epochs.
    function unstake(uint256 tokenId, address[] calldata gauges, uint256[] calldata amounts)
        external
        override
        nonReentrant
    {
        _requireTokenOwner(tokenId);
        if (gauges.length == 0) revert EmptyArray();
        if (gauges.length != amounts.length) revert LengthMismatch();

        for (uint256 i; i < gauges.length; ++i) {
            if (amounts[i] == 0) revert ZeroAmount();
            if (vaultByGauge[gauges[i]] == address(0)) revert InvalidVault();
            if (_pendingGaugeIndex[tokenId][gauges[i]] != 0) _finalize(tokenId, gauges[i]);
            _rememberTokenGauge(tokenId, gauges[i]);

            {
                uint64 validatorId = StakingVault(payable(vaultByGauge[gauges[i]])).validatorId();
                address agent = agentByToken[tokenId];
                uint256 agentAmount =
                    agent == address(0) || validatorId == 0 ? 0 : StakingAgent(payable(agent)).balanceOf(validatorId);
                uint256 fromAgent = amounts[i] < agentAmount ? amounts[i] : agentAmount;
                if (fromAgent != 0) {
                    StakingAgent(payable(agent)).undelegate(validatorId, fromAgent);
                    _rememberPendingGauge(tokenId, gauges[i]);
                }

                uint256 fromVault = amounts[i] - fromAgent;
                if (fromVault != 0) {
                    if (StakingVault(payable(vaultByGauge[gauges[i]])).balanceOf(tokenId) < fromVault) {
                        revert InvalidUnstakeAmount();
                    }
                    StakingVault(payable(vaultByGauge[gauges[i]])).undelegate(tokenId, fromVault);
                    _rememberPendingGauge(tokenId, gauges[i]);
                }
            }
        }
        emit Unstaked(tokenId, _sum(amounts));
    }

    function _finalize(uint256 tokenId, address gauge) internal {
        address vault = vaultByGauge[gauge];
        uint256 beforeBalance = address(this).balance;
        uint256 vaultPending = StakingVault(payable(vault)).pendingWithdrawal(tokenId);
        address agent = agentByToken[tokenId];
        uint64 validatorId;
        uint256 agentPending;
        if (agent != address(0)) {
            validatorId = StakingVault(payable(vault)).validatorId();
            if (validatorId != 0) agentPending = StakingAgent(payable(agent)).pendingWithdrawal(validatorId);
        }
        bool hadPending = vaultPending != 0 || agentPending != 0;
        if (vaultPending != 0) {
            StakingVault(payable(vault)).withdraw(tokenId);
        }
        if (agentPending != 0) {
            try StakingAgent(payable(agent)).withdraw(validatorId) {} catch {}
        }
        balanceOf[tokenId] += address(this).balance - beforeBalance;
        if (hadPending) {
            if (_pendingOf(tokenId, gauge) == 0) _removePendingGauge(tokenId, gauge);
            if (_allocationOf(tokenId, gauge) == 0 && _pendingOf(tokenId, gauge) == 0) {
                _removeTokenGauge(tokenId, gauge);
            }
        }
    }

    function _sum(uint256[] calldata values) private pure returns (uint256 total) {
        for (uint256 i; i < values.length; ++i) {
            total += values[i];
        }
    }

    function _allocationOf(uint256 tokenId, address gauge) internal view returns (uint256 allocation) {
        address vault = vaultByGauge[gauge];
        if (vault == address(0)) return 0;
        allocation = StakingVault(payable(vault)).balanceOf(tokenId);
        uint64 validatorId = StakingVault(payable(vault)).validatorId();
        address agent = agentByToken[tokenId];
        if (agent != address(0) && validatorId != 0) {
            allocation += StakingAgent(payable(agent)).balanceOf(validatorId);
        }
    }

    function _pendingOf(uint256 tokenId, address gauge) internal view returns (uint256 pending) {
        address vault = vaultByGauge[gauge];
        if (vault == address(0)) return 0;
        uint64 validatorId = StakingVault(payable(vault)).validatorId();
        pending = StakingVault(payable(vault)).pendingWithdrawal(tokenId);
        address agent = agentByToken[tokenId];
        if (agent != address(0) && validatorId != 0) {
            pending += StakingAgent(payable(agent)).pendingWithdrawal(validatorId);
        }
    }

    function _rememberTokenGauge(uint256 tokenId, address gauge) internal {
        if (_tokenGaugeIndex[tokenId][gauge] != 0) return;
        _tokenGauges[tokenId].push(gauge);
        _tokenGaugeIndex[tokenId][gauge] = _tokenGauges[tokenId].length;
    }

    function _removeTokenGauge(uint256 tokenId, address gauge) internal {
        uint256 indexPlusOne = _tokenGaugeIndex[tokenId][gauge];
        if (indexPlusOne == 0) return;
        address[] storage gauges = _tokenGauges[tokenId];
        uint256 index = indexPlusOne - 1;
        uint256 last = gauges.length - 1;
        if (index != last) {
            address replacement = gauges[last];
            gauges[index] = replacement;
            _tokenGaugeIndex[tokenId][replacement] = index + 1;
        }
        gauges.pop();
        delete _tokenGaugeIndex[tokenId][gauge];
    }

    function _rememberPendingGauge(uint256 tokenId, address gauge) internal {
        if (_pendingGaugeIndex[tokenId][gauge] != 0) return;
        _pendingGauges[tokenId].push(gauge);
        _pendingGaugeIndex[tokenId][gauge] = _pendingGauges[tokenId].length;
    }

    function _removePendingGauge(uint256 tokenId, address gauge) internal {
        uint256 indexPlusOne = _pendingGaugeIndex[tokenId][gauge];
        if (indexPlusOne == 0) return;
        address[] storage gauges = _pendingGauges[tokenId];
        uint256 index = indexPlusOne - 1;
        uint256 last = gauges.length - 1;
        if (index != last) {
            address replacement = gauges[last];
            gauges[index] = replacement;
            _pendingGaugeIndex[tokenId][replacement] = index + 1;
        }
        gauges.pop();
        delete _pendingGaugeIndex[tokenId][gauge];
    }

    /// @notice Complete prior undelegations after Monad's withdrawal delay.
    /// @dev The token owner can finalize a direct unstake.
    function withdraw(uint256 tokenId, address[] calldata gauges)
        external
        override
        nonReentrant
        returns (uint256 reclaimed)
    {
        _requireTokenOwner(tokenId);
        if (gauges.length == 0) revert EmptyArray();

        for (uint256 i; i < gauges.length; ++i) {
            address vault = vaultByGauge[gauges[i]];
            if (vault == address(0)) revert InvalidVault();
            uint256 beforeBalance = address(this).balance;
            _finalize(tokenId, gauges[i]);
            reclaimed += address(this).balance - beforeBalance;
        }

        if (reclaimed != 0) emit Withdrawn(tokenId, reclaimed);
    }

    /// @notice Finalize every pending withdrawal tracked for a token.
    /// @dev This is the single finalization pass used by veMON exit.
    function finalizeWithdrawals(uint256 tokenId) external override nonReentrant returns (uint256 reclaimed) {
        if (msg.sender != _ve() && msg.sender != IVotingEscrow(_ve()).ownerOf(tokenId)) {
            revert NotTokenOwner();
        }

        uint256 i;
        while (i < _pendingGauges[tokenId].length) {
            address gauge = _pendingGauges[tokenId][i];
            uint256 beforeBalance = address(this).balance;
            _finalize(tokenId, gauge);
            reclaimed += address(this).balance - beforeBalance;
            if (_pendingGaugeIndex[tokenId][gauge] != 0) ++i;
        }

        if (reclaimed != 0) emit Withdrawn(tokenId, reclaimed);
    }

    /// @notice Release liquid MON after a veNFT has no active or pending stake.
    function release(uint256 tokenId, address payable recipient)
        external
        override
        nonReentrant
        returns (uint256 amount)
    {
        if (msg.sender != _ve()) revert NotVe();
        if (recipient == address(0) || !_isFullyUnstaked(tokenId)) revert InvalidUnstakeAmount();

        amount = balanceOf[tokenId];
        if (amount == 0) revert InvalidUnstakeAmount();
        balanceOf[tokenId] = 0;
        delete _tokenGauges[tokenId];
        delete _pendingGauges[tokenId];
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();
        emit MONReleased(tokenId, recipient, amount);
    }

    /// @notice Claim staking rewards for a token's vault and agent allocations.
    /// @dev Only the current owner of the veNFT can claim its rewards.
    function claimRewards(uint256 tokenId, address[] calldata gauges) external override nonReentrant {
        address tokenOwner = IVotingEscrow(_ve()).ownerOf(tokenId);
        if (tokenOwner != msg.sender) revert NotTokenOwner();
        if (gauges.length == 0) revert EmptyArray();
        uint256 beforeBalance = address(this).balance;

        address agent = agentByToken[tokenId];
        uint64[] memory validatorIds = new uint64[](gauges.length);
        uint256 validatorCount;
        for (uint256 i; i < gauges.length; ++i) {
            address vault = vaultByGauge[gauges[i]];
            if (vault == address(0)) revert InvalidVault();

            StakingVault(payable(vault)).claimRewards();
            if (agent != address(0)) {
                uint64 validatorId = StakingVault(payable(vault)).validatorId();
                if (validatorId != 0) validatorIds[validatorCount++] = validatorId;
            }
        }

        if (validatorCount != 0) {
            assembly {
                mstore(validatorIds, validatorCount)
            }
            StakingAgent(payable(agent)).claimRewards(validatorIds);
        }

        uint256 claimed = address(this).balance - beforeBalance;
        if (claimed != 0) {
            (bool success,) = payable(tokenOwner).call{value: claimed}("");
            if (!success) revert UnexpectedEtherSender();
        }
    }

    function _ve() private view returns (address) {
        return ve;
    }

    function _requireTokenOwner(uint256 tokenId) private view {
        if (msg.sender != IVotingEscrow(_ve()).ownerOf(tokenId)) {
            revert NotTokenOwner();
        }
    }
}
