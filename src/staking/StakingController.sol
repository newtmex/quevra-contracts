// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IValidatorRegistry} from "../interfaces/IValidatorRegistry.sol";
import {IBaseVoter} from "../interfaces/IBaseVoter.sol";
import {IStakingController} from "../interfaces/IStakingController.sol";
import {StakingVault} from "./controlled/StakingVault.sol";
import {StakingAgent} from "./controlled/StakingAgent.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";
import {ValidatorPayloadLibrary} from "../libraries/ValidatorPayloadLibrary.sol";

/// @title StakingController
/// @notice Owns validator vaults and routes MON deposits through the bound vault.
/// @dev Accepts MON only through the ve token's explicit deposit call. Admin-controlled staking flow is deferred.
contract StakingController is Ownable2Step, ReentrancyGuardTransient, IStakingController {
    IValidatorRegistry public immutable override registry;
    address public override voter;
    address public immutable override vaultImplementation;
    mapping(address gauge => address vault) public override vaultByGauge;
    mapping(address => bool) private _isVault;
    mapping(address => bool) private _isAgent;
    mapping(uint256 tokenId => uint256 amount) public override balanceOf;
    mapping(uint256 tokenId => address agent) public override agentByToken;
    // Controller-owned allocation state. Vaults and agents only mirror the
    // precompile position they hold; this mapping is the policy/accounting
    // source used by rebalancing and voter notifications.
    mapping(uint256 tokenId => mapping(address gauge => uint256 amount)) public activeAllocation;
    mapping(uint256 tokenId => mapping(address gauge => uint256 amount)) public pendingWithdrawal;
    mapping(uint256 tokenId => mapping(address gauge => uint256 amount)) public pendingAgentWithdrawal;
    mapping(uint256 tokenId => mapping(address gauge => uint256 amount)) public pendingVaultWithdrawal;
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
    }

    /// @notice Bind the voter once. The owner must set this after both contracts are deployed.
    function setVoter(address voter_) external override onlyOwner {
        if (voter != address(0)) revert VoterAlreadySet();
        if (voter_ == address(0)) revert InvalidAddress();
        voter = voter_;
        emit VoterSet(voter_);
    }

    /// @notice Deploy, initialize, and register a vault with its gauge, only through the voter.
    function deployVault(
        uint256 requestId,
        address requester,
        bytes32 saltSeed,
        address expectedAuthAddress,
        address gauge
    ) external override returns (address vault) {
        if (msg.sender != voter) revert NotVoter();
        if (requester == address(0) || gauge == address(0) || vaultByGauge[gauge] != address(0)) {
            revert InvalidVault();
        }

        IValidatorRegistry.Submission memory submission = registry.getSubmission(requestId);
        if (submission.requester != voter || submission.status != IValidatorRegistry.Status.Submitted) {
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
        _isVault[vault] = true;
        emit VaultRegistered(requestId, vault, gauge, requester);
    }

    function predictVaultAddress(address requester, bytes32 saltSeed) public view override returns (address) {
        return Clones.predictDeterministicAddress(vaultImplementation, _vaultSalt(requester, saltSeed), address(this));
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
        if (voter == address(0) || requester == address(0)) revert InvalidAddress();
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
        if (voter == address(0) || msg.sender != _ve()) revert NotVe();
        if (msg.value == 0) revert InvalidDepositAmount();
        balanceOf[tokenId] += msg.value;
        emit MONDeposited(tokenId, msg.value);
    }

    function allocationOf(uint256 tokenId, address gauge) external view override returns (uint256 allocation) {
        allocation = activeAllocation[tokenId][gauge];
    }

    /// @notice Controller-side conservation view for a token position.
    /// @dev Pending amounts are still owned by the token even though they are
    /// no longer active validator backing.
    function economicBalanceOf(uint256 tokenId, address[] calldata gauges)
        external
        view
        returns (uint256 available, uint256 active, uint256 pending)
    {
        available = balanceOf[tokenId];
        for (uint256 i; i < gauges.length; ++i) {
            active += activeAllocation[tokenId][gauges[i]];
            pending += pendingWithdrawal[tokenId][gauges[i]];
        }
    }

    /// @dev Receives redeemed MON from a token's vault or agent.
    receive() external payable {
        if (!_isVault[msg.sender] && !_isAgent[msg.sender]) revert UnexpectedEtherSender();
    }

    /// @notice Allocate a token's available MON to validator requests selected by the voter.
    /// @dev A request's vault is topped up first. Any allocation left after activation is
    /// delegated by the token-bound agent, so changing allocations in a later cycle is safe.
    function stake(uint256 tokenId, address[] calldata gauges, uint256[] calldata amounts)
        external
        override
        nonReentrant
    {
        if (msg.sender != voter) revert NotVoter();
        if (gauges.length == 0) revert EmptyArray();
        if (gauges.length != amounts.length) revert LengthMismatch();

        uint256 total;
        for (uint256 i; i < gauges.length; ++i) {
            _stake(tokenId, gauges[i], amounts[i]);
            total += amounts[i];
        }
        emit Staked(tokenId, total);
    }

    /// @notice Begin reclaiming MON previously allocated by `stake` for a token.
    /// @dev Monad requires undelegation and withdrawal to happen in different epochs.
    function unstake(uint256 tokenId, address[] calldata gauges, uint256[] calldata amounts)
        external
        override
        nonReentrant
    {
        if (msg.sender != voter) revert NotVoter();
        if (gauges.length == 0) revert EmptyArray();
        if (gauges.length != amounts.length) revert LengthMismatch();

        uint256 total;
        for (uint256 i; i < gauges.length; ++i) {
            _unstake(tokenId, gauges[i], amounts[i]);
            total += amounts[i];
        }
        emit Unstaked(tokenId, total);
    }

    /// @dev The only primitive that increases one tokenId/validator pair.
    function _stake(uint256 tokenId, address gauge, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        address vault = vaultByGauge[gauge];
        if (vault == address(0)) revert InvalidVault();

        _finalize(tokenId, gauge);
        if (balanceOf[tokenId] < amount) revert InsufficientBalance();
        balanceOf[tokenId] -= amount;

        uint256 deficit = StakingVault(payable(vault)).deficit();
        uint256 toVault = amount < deficit ? amount : deficit;
        if (toVault != 0) StakingVault(payable(vault)).deposit{value: toVault}(tokenId);

        uint256 remainder = amount - toVault;
        if (remainder != 0) {
            uint64 validatorId = StakingVault(payable(vault)).validatorId();
            if (validatorId == 0) revert ValidatorNotActivated();
            address agent = _agentFor(tokenId);
            uint64[] memory ids = new uint64[](1);
            uint256[] memory values = new uint256[](1);
            ids[0] = validatorId;
            values[0] = remainder;
            StakingAgent(payable(agent)).delegate{value: remainder}(ids, values);
        }

        activeAllocation[tokenId][gauge] += amount;
        _notifyStakeChange(tokenId, gauge, amount, true);
    }

    /// @dev The only primitive that decreases one tokenId/validator pair.
    function _unstake(uint256 tokenId, address gauge, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        address vault = vaultByGauge[gauge];
        if (vault == address(0)) revert InvalidVault();

        // A matured request is free Controller balance and can be reused by
        // the same operation. It never changes active validator accounting.
        _finalize(tokenId, gauge);
        uint256 active = activeAllocation[tokenId][gauge];
        if (amount > active) revert InvalidUnstakeAmount();

        uint64 validatorId = StakingVault(payable(vault)).validatorId();
        address agent = agentByToken[tokenId];
        uint256 agentBalance =
            agent == address(0) || validatorId == 0 ? 0 : StakingAgent(payable(agent)).balanceOf(validatorId);
        uint256 fromAgent = amount < agentBalance ? amount : agentBalance;
        uint256 fromVault = amount - fromAgent;

        // Agent withdrawals are per-token and can be partial. Vault capital
        // is withdrawn only as a token-owned tranche, preserving the old
        // activation rule that a vault cannot be overfunded.
        if (fromAgent != 0) {
            uint64[] memory ids = new uint64[](1);
            uint256[] memory values = new uint256[](1);
            ids[0] = validatorId;
            values[0] = fromAgent;
            StakingAgent(payable(agent)).undelegate(ids, values);
        }
        if (fromVault != 0) {
            if (StakingVault(payable(vault)).balanceOf(tokenId) != fromVault) revert InvalidUnstakeAmount();
            StakingVault(payable(vault)).undelegate();
        }

        activeAllocation[tokenId][gauge] = active - amount;
        pendingWithdrawal[tokenId][gauge] += amount;
        pendingAgentWithdrawal[tokenId][gauge] += fromAgent;
        pendingVaultWithdrawal[tokenId][gauge] += fromVault;
        _notifyStakeChange(tokenId, gauge, amount, false);
    }

    /// @notice Complete a prior `unstake` after Monad's withdrawal delay.
    function withdraw(uint256 tokenId, address[] calldata gauges) external override nonReentrant {
        if (msg.sender != voter) revert NotVoter();
        if (gauges.length == 0) revert EmptyArray();

        uint256 reclaimed;
        for (uint256 i; i < gauges.length; ++i) {
            address vault = vaultByGauge[gauges[i]];
            if (vault == address(0)) revert InvalidVault();
            if (pendingWithdrawal[tokenId][gauges[i]] == 0) continue;
            uint256 beforeBalance = address(this).balance;
            if (pendingVaultWithdrawal[tokenId][gauges[i]] != 0 && StakingVault(payable(vault)).balanceOf(tokenId) != 0)
            {
                StakingVault(payable(vault)).withdraw(tokenId);
            }
            reclaimed += address(this).balance - beforeBalance;
            if (StakingVault(payable(vault)).balanceOf(tokenId) == 0) {
                pendingVaultWithdrawal[tokenId][gauges[i]] = 0;
            }
        }

        address agent = agentByToken[tokenId];
        if (agent != address(0)) {
            uint256 beforeBalance = address(this).balance;
            uint64[] memory validatorIds = new uint64[](gauges.length);
            uint256 validatorCount;
            for (uint256 i; i < gauges.length; ++i) {
                uint64 validatorId = StakingVault(payable(vaultByGauge[gauges[i]])).validatorId();
                if (
                    pendingWithdrawal[tokenId][gauges[i]] != 0
                        && StakingAgent(payable(agent)).pendingWithdrawal(validatorId) != 0
                ) {
                    validatorIds[validatorCount] = validatorId;
                    ++validatorCount;
                }
            }
            if (validatorCount != 0) {
                assembly {
                    mstore(validatorIds, validatorCount)
                }
                StakingAgent(payable(agent)).withdraw(validatorIds);
                reclaimed += address(this).balance - beforeBalance;
            }
            for (uint256 i; i < gauges.length; ++i) {
                uint64 validatorId = StakingVault(payable(vaultByGauge[gauges[i]])).validatorId();
                if (validatorId != 0 && StakingAgent(payable(agent)).pendingWithdrawal(validatorId) == 0) {
                    pendingAgentWithdrawal[tokenId][gauges[i]] = 0;
                }
            }
        }
        if (reclaimed == 0) revert InvalidUnstakeAmount();
        balanceOf[tokenId] += reclaimed;
        for (uint256 i; i < gauges.length; ++i) {
            address gauge = gauges[i];
            if (pendingAgentWithdrawal[tokenId][gauge] == 0 && pendingVaultWithdrawal[tokenId][gauge] == 0) {
                pendingWithdrawal[tokenId][gauge] = 0;
            }
        }
        emit Withdrawn(tokenId, reclaimed);
    }

    function _agentFor(uint256 tokenId) private returns (address agent) {
        agent = agentByToken[tokenId];
        if (agent == address(0)) {
            agent = address(new StakingAgent());
            agentByToken[tokenId] = agent;
            _isAgent[agent] = true;
            emit AgentCreated(tokenId, agent);
        }
    }

    /// @dev Finalization is deliberately shared by stake and unstake.
    function _finalize(uint256 tokenId, address gauge) private returns (uint256 received) {
        if (pendingWithdrawal[tokenId][gauge] == 0) return 0;
        address vault = vaultByGauge[gauge];
        uint256 beforeBalance = address(this).balance;
        uint256 vaultBalance = StakingVault(payable(vault)).balanceOf(tokenId);
        if (pendingVaultWithdrawal[tokenId][gauge] != 0 && vaultBalance != 0) {
            StakingVault(payable(vault)).withdraw(tokenId);
        }
        if (vaultBalance != 0 && StakingVault(payable(vault)).balanceOf(tokenId) == 0) {
            pendingVaultWithdrawal[tokenId][gauge] = 0;
        }
        address agent = agentByToken[tokenId];
        if (agent != address(0)) {
            uint64 validatorId = StakingVault(payable(vault)).validatorId();
            if (validatorId != 0 && StakingAgent(payable(agent)).pendingWithdrawal(validatorId) != 0) {
                uint64[] memory ids = new uint64[](1);
                ids[0] = validatorId;
                StakingAgent(payable(agent)).withdraw(ids);
            }
            if (validatorId != 0 && StakingAgent(payable(agent)).pendingWithdrawal(validatorId) == 0) {
                pendingAgentWithdrawal[tokenId][gauge] = 0;
            }
        }
        received = address(this).balance - beforeBalance;
        if (received != 0) balanceOf[tokenId] += received;
        // A failed/immature withdrawal leaves the request intact and lets a
        // later call retry it after Monad's withdrawal epoch.
        if (pendingAgentWithdrawal[tokenId][gauge] == 0 && pendingVaultWithdrawal[tokenId][gauge] == 0) {
            pendingWithdrawal[tokenId][gauge] = 0;
        }
        return received;
    }

    function _notifyStakeChange(uint256 tokenId, address gauge, uint256 amount, bool increase) private {
        if (voter == address(0)) return;
        IStakingAmountReceiver(voter).notifyStakeChange(tokenId, gauge, amount, increase);
    }

    function _ve() private view returns (address) {
        return IBaseVoter(voter).ve();
    }
}

interface IStakingAmountReceiver {
    function notifyStakeChange(uint256 tokenId, address gauge, uint256 amount, bool increase) external;
}
