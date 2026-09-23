// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";
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
    /// @dev Enumerable positions only. Amounts are always read from the vault and agent.
    mapping(uint256 tokenId => address[] gauges) private _allocatedGauges;
    mapping(uint256 tokenId => mapping(address gauge => uint256 indexPlusOne)) private _allocatedGaugeIndex;
    IMonadStaking private constant STAKING = IMonadStaking(0x0000000000000000000000000000000000001000);
    uint8 private constant WITHDRAW_ID = 0;

    struct UnstakePlan {
        uint64 validatorId;
        uint256 agentAmount;
        uint256 vaultAmount;
    }
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

    /// @inheritdoc IStakingController
    function allocationOf(uint256 tokenId, address gauge) public view override returns (uint256) {
        address vaultAddress = vaultByGauge[gauge];
        if (vaultAddress == address(0)) return 0;
        StakingVault vault = StakingVault(payable(vaultAddress));
        uint256 allocated = vault.exiting() ? 0 : vault.balanceOf(tokenId);
        address agent = agentByToken[tokenId];
        uint64 validatorId = vault.validatorId();
        if (agent == address(0) || validatorId == 0) return allocated;
        return allocated + StakingAgent(payable(agent)).balanceOf(validatorId);
    }

    /// @inheritdoc IStakingController
    function allocatedGauges(uint256 tokenId) external view override returns (address[] memory) {
        return _allocatedGauges[tokenId];
    }

    /// @inheritdoc IStakingController
    function executableStake(address gauge, uint256 amount) public view override returns (uint256) {
        address vaultAddress = vaultByGauge[gauge];
        if (vaultAddress == address(0) || amount == 0) return 0;
        StakingVault vault = StakingVault(payable(vaultAddress));
        if (vault.validatorId() != 0) return amount;
        uint256 deficit = vault.deficit();
        // Covering the deficit activates the validator inside `stake`, which can also delegate the surplus.
        if (deficit != 0 && amount >= deficit) return amount;
        return amount < deficit ? amount : 0;
    }

    /// @inheritdoc IStakingController
    function executableUnstake(uint256 tokenId, address gauge, uint256 amount)
        external
        view
        override
        returns (uint256)
    {
        if (amount == 0 || vaultByGauge[gauge] == address(0)) return 0;
        UnstakePlan memory plan = _planUnstake(tokenId, gauge, amount);
        return plan.agentAmount + plan.vaultAmount;
    }

    /// @inheritdoc IStakingController
    function withdrawalReady(uint256 tokenId, address gauge) external override returns (bool) {
        address vaultAddress = vaultByGauge[gauge];
        if (vaultAddress == address(0)) return false;
        StakingVault vault = StakingVault(payable(vaultAddress));
        if (_vaultReady(vault, tokenId)) return true;
        return _agentReady(agentByToken[tokenId], vault.validatorId());
    }

    function deposit(uint256 tokenId) external payable override nonReentrant {
        if (voter == address(0) || msg.sender != _ve()) revert NotVe();
        if (msg.value == 0) revert InvalidDepositAmount();
        balanceOf[tokenId] += msg.value;
        emit MONDeposited(tokenId, msg.value);
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
        for (uint256 i; i < amounts.length; ++i) {
            if (amounts[i] == 0) revert ZeroAmount();
            total += amounts[i];
        }
        if (total > balanceOf[tokenId]) revert InsufficientBalance();
        balanceOf[tokenId] -= total;

        address agent = agentByToken[tokenId];
        if (agent == address(0)) {
            agent = address(new StakingAgent());
            agentByToken[tokenId] = agent;
            _isAgent[agent] = true;
            emit AgentCreated(tokenId, agent);
        }

        uint64[] memory validatorIds = new uint64[](gauges.length);
        uint256[] memory delegated = new uint256[](gauges.length);
        uint256 delegatedCount;
        uint256 delegatedTotal;
        for (uint256 i; i < gauges.length; ++i) {
            (uint64 validatorId, uint256 remainder) = _allocate(tokenId, gauges[i], amounts[i]);
            if (remainder != 0) {
                validatorIds[delegatedCount] = validatorId;
                delegated[delegatedCount] = remainder;
                delegatedTotal += remainder;
                ++delegatedCount;
            }
        }
        if (delegatedTotal != 0) {
            assembly {
                mstore(validatorIds, delegatedCount)
                mstore(delegated, delegatedCount)
            }
            StakingAgent(payable(agent)).delegate{value: delegatedTotal}(validatorIds, delegated);
        }
        for (uint256 i; i < gauges.length; ++i) {
            _trackGauge(tokenId, gauges[i]);
        }
        emit Staked(tokenId, total);
    }

    /// @notice Begin reclaiming MON previously allocated by `stake` for a token.
    /// @dev Agent delegation is consumed before vault auth stake. Monad requires
    ///      undelegation and withdrawal to happen in different epochs, except for
    ///      vault MON that was never delegated, which is returned immediately.
    function unstake(uint256 tokenId, address[] calldata gauges, uint256[] calldata amounts)
        external
        override
        nonReentrant
    {
        if (msg.sender != voter) revert NotVoter();
        if (gauges.length == 0) revert EmptyArray();
        if (gauges.length != amounts.length) revert LengthMismatch();

        address agent = agentByToken[tokenId];
        uint64[] memory validatorIds = new uint64[](gauges.length);
        uint256[] memory delegated = new uint256[](gauges.length);
        bool[] memory unwindVault = new bool[](gauges.length);
        uint256 delegatedCount;
        uint256 total;

        for (uint256 i; i < gauges.length; ++i) {
            if (amounts[i] == 0) revert ZeroAmount();
            UnstakePlan memory plan = _planUnstake(tokenId, gauges[i], amounts[i]);
            if (plan.agentAmount + plan.vaultAmount != amounts[i]) revert InvalidUnstakeAmount();
            if (plan.agentAmount != 0) {
                if (agent == address(0)) revert InvalidUnstakeAmount();
                validatorIds[delegatedCount] = plan.validatorId;
                delegated[delegatedCount] = plan.agentAmount;
                ++delegatedCount;
            }
            unwindVault[i] = plan.vaultAmount != 0;
            total += amounts[i];
        }

        // Undelegate agent allocations before touching the vault. Monad may
        // reject validator operations when the vault is undelegated first.
        if (delegatedCount != 0) {
            assembly {
                mstore(validatorIds, delegatedCount)
                mstore(delegated, delegatedCount)
            }
            StakingAgent(payable(agent)).undelegate(validatorIds, delegated);
        }

        uint256 returnedToLiquid;
        for (uint256 i; i < gauges.length; ++i) {
            if (!unwindVault[i]) continue;
            address vaultAddress = vaultByGauge[gauges[i]];
            if (StakingVault(payable(vaultAddress)).validatorId() == 0) {
                returnedToLiquid += _collectVault(tokenId, vaultAddress);
            } else {
                StakingVault(payable(vaultAddress)).undelegate();
            }
        }
        if (returnedToLiquid != 0) {
            balanceOf[tokenId] += returnedToLiquid;
            emit Withdrawn(tokenId, returnedToLiquid);
        }
        for (uint256 i; i < gauges.length; ++i) {
            _trackGauge(tokenId, gauges[i]);
        }
        emit Unstaked(tokenId, total);
    }

    /// @notice Complete a prior `unstake` after Monad's withdrawal delay.
    /// @dev Only pulls vault balances that are exiting and agent withdrawals that have matured.
    function withdraw(uint256 tokenId, address[] calldata gauges) external override nonReentrant {
        if (msg.sender != voter) revert NotVoter();
        if (gauges.length == 0) revert EmptyArray();

        uint256 reclaimed;
        address agent = agentByToken[tokenId];
        uint64[] memory validatorIds = new uint64[](gauges.length);
        uint256 validatorCount;

        for (uint256 i; i < gauges.length; ++i) {
            address vaultAddress = vaultByGauge[gauges[i]];
            if (vaultAddress == address(0)) revert InvalidVault();
            StakingVault vault = StakingVault(payable(vaultAddress));
            if (_vaultReady(vault, tokenId)) reclaimed += _collectVault(tokenId, vaultAddress);

            uint64 validatorId = vault.validatorId();
            if (_agentReady(agent, validatorId) && !_contains(validatorIds, validatorCount, validatorId)) {
                validatorIds[validatorCount] = validatorId;
                ++validatorCount;
            }
        }

        if (validatorCount != 0) {
            assembly {
                mstore(validatorIds, validatorCount)
            }
            uint256 beforeBalance = address(this).balance;
            StakingAgent(payable(agent)).withdraw(validatorIds);
            reclaimed += address(this).balance - beforeBalance;
        }
        if (reclaimed == 0) revert InvalidUnstakeAmount();
        balanceOf[tokenId] += reclaimed;
        for (uint256 i; i < gauges.length; ++i) {
            _trackGauge(tokenId, gauges[i]);
        }
        emit Withdrawn(tokenId, reclaimed);
    }

    /// @dev Agent stake is spent before vault auth stake. A busy agent withdrawal slot blocks
    ///      another undelegation, and the vault moves only when the request takes its entire balance.
    function _planUnstake(uint256 tokenId, address gauge, uint256 amount)
        private
        view
        returns (UnstakePlan memory plan)
    {
        address vaultAddress = vaultByGauge[gauge];
        if (vaultAddress == address(0)) revert InvalidVault();
        StakingVault vault = StakingVault(payable(vaultAddress));
        plan.validatorId = vault.validatorId();
        uint256 activeVault = vault.exiting() ? 0 : vault.balanceOf(tokenId);

        uint256 agentBalance;
        bool agentBlocked;
        address agent = agentByToken[tokenId];
        if (agent != address(0) && plan.validatorId != 0) {
            StakingAgent stakingAgent = StakingAgent(payable(agent));
            agentBalance = stakingAgent.balanceOf(plan.validatorId);
            agentBlocked = stakingAgent.pendingWithdrawal(plan.validatorId) != 0;
        }
        // Occupied slot: leave the vault in place until the agent stake can move with it.
        if (agentBlocked && agentBalance != 0) return plan;

        uint256 coveredByAgent = amount < agentBalance ? amount : agentBalance;
        uint256 vaultNeed = amount - coveredByAgent;
        plan.agentAmount = coveredByAgent;
        if (vaultNeed != 0 && vaultNeed == activeVault) plan.vaultAmount = vaultNeed;
    }

    function _allocate(uint256 tokenId, address gauge, uint256 amount)
        private
        returns (uint64 validatorId, uint256 remainder)
    {
        address vault = vaultByGauge[gauge];
        if (vault == address(0)) revert InvalidVault();
        uint256 deficit = StakingVault(payable(vault)).deficit();
        uint256 toVault = amount < deficit ? amount : deficit;
        if (toVault != 0) StakingVault(payable(vault)).deposit{value: toVault}(tokenId);
        remainder = amount - toVault;
        if (remainder != 0) {
            validatorId = StakingVault(payable(vault)).validatorId();
            if (validatorId == 0) revert ValidatorNotActivated();
        }
    }

    function _ve() private view returns (address) {
        return IBaseVoter(voter).ve();
    }

    function _collectVault(uint256 tokenId, address vaultAddress) private returns (uint256 amount) {
        uint256 beforeBalance = address(this).balance;
        StakingVault(payable(vaultAddress)).withdraw(tokenId);
        return address(this).balance - beforeBalance;
    }

    function _positionOf(uint256 tokenId, address gauge) private view returns (uint256) {
        address vaultAddress = vaultByGauge[gauge];
        if (vaultAddress == address(0)) return 0;
        StakingVault vault = StakingVault(payable(vaultAddress));
        uint256 position = vault.balanceOf(tokenId);
        address agent = agentByToken[tokenId];
        uint64 validatorId = vault.validatorId();
        if (agent == address(0) || validatorId == 0) return position;
        StakingAgent stakingAgent = StakingAgent(payable(agent));
        return position + stakingAgent.balanceOf(validatorId) + stakingAgent.pendingWithdrawal(validatorId);
    }

    function _trackGauge(uint256 tokenId, address gauge) private {
        if (_positionOf(tokenId, gauge) == 0) {
            _forgetGauge(tokenId, gauge);
            return;
        }
        if (_allocatedGaugeIndex[tokenId][gauge] != 0) return;
        _allocatedGauges[tokenId].push(gauge);
        _allocatedGaugeIndex[tokenId][gauge] = _allocatedGauges[tokenId].length;
    }

    function _forgetGauge(uint256 tokenId, address gauge) private {
        uint256 indexPlusOne = _allocatedGaugeIndex[tokenId][gauge];
        if (indexPlusOne == 0) return;
        uint256 last = _allocatedGauges[tokenId].length;
        if (indexPlusOne != last) {
            address moved = _allocatedGauges[tokenId][last - 1];
            _allocatedGauges[tokenId][indexPlusOne - 1] = moved;
            _allocatedGaugeIndex[tokenId][moved] = indexPlusOne;
        }
        _allocatedGauges[tokenId].pop();
        delete _allocatedGaugeIndex[tokenId][gauge];
    }

    function _vaultReady(StakingVault vault, uint256 tokenId) private returns (bool) {
        uint256 amount = vault.balanceOf(tokenId);
        if (amount == 0 || !vault.exiting()) return false;
        if (vault.availableBalance() >= amount) return true;
        uint64 validatorId = vault.validatorId();
        if (validatorId == 0) return false;
        return _mature(validatorId, address(vault));
    }

    function _agentReady(address agent, uint64 validatorId) private returns (bool) {
        if (agent == address(0) || validatorId == 0) return false;
        if (StakingAgent(payable(agent)).pendingWithdrawal(validatorId) == 0) return false;
        return _mature(validatorId, agent);
    }

    /// @dev Claimable on the epoch after the precompile's `withdrawEpoch`, matching Monad's withdrawal delay.
    function _mature(uint64 validatorId, address delegator) private returns (bool) {
        (uint256 amount,, uint64 withdrawEpoch) = STAKING.getWithdrawalRequest(validatorId, delegator, WITHDRAW_ID);
        if (amount == 0) return false;
        (uint64 epoch,) = ProtocolTimeLibrary.currentEpoch();
        return epoch > withdrawEpoch;
    }

    function _contains(uint64[] memory validatorIds, uint256 count, uint64 validatorId) private pure returns (bool) {
        for (uint256 i; i < count; ++i) {
            if (validatorIds[i] == validatorId) return true;
        }
        return false;
    }
}
