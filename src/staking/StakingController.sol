// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {StakingVault} from "./controlled/StakingVault.sol";
import {StakingAgent} from "./controlled/StakingAgent.sol";
import {StakingAdmin} from "./StakingAdmin.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";

/// @title StakingController
/// @notice Owns validator vaults and routes MON deposits through the bound vault.
/// @dev User-selected allocations are intent; this contract only settles
///      physical MON toward that intent.
contract StakingController is StakingAdmin, ReentrancyGuardTransient {
    mapping(uint256 tokenId => uint256 amount) public override balanceOf;
    mapping(uint256 tokenId => uint64 cycle) public override stakingCycleOf;
    mapping(uint256 tokenId => mapping(address gauge => uint256 amount)) public override intentOf;
    mapping(uint256 tokenId => address agent) public override agentByToken;
    mapping(uint256 tokenId => address[]) private _tokenGauges;
    mapping(uint256 tokenId => mapping(address gauge => uint256 indexPlusOne)) private _tokenGaugeIndex;
    mapping(uint256 tokenId => address[]) private _tokenRewardGauges;
    mapping(uint256 tokenId => mapping(address gauge => uint256 indexPlusOne)) private _tokenRewardGaugeIndex;
    mapping(uint256 tokenId => address[]) private _intentGauges;
    mapping(uint256 tokenId => mapping(address gauge => uint256 indexPlusOne)) private _intentGaugeIndex;

    struct Position {
        address vault;
        address agent;
        uint64 validatorId;
        uint256 vaultAllocation;
        uint256 agentAllocation;
        uint256 vaultPending;
        uint256 agentPending;
    }

    struct PokeBatch {
        address agent;
        uint256 liquid;
        uint256 delegateCount;
        uint256 delegateValue;
        uint64[] delegateValidators;
        uint256[] delegateAmounts;
    }
    constructor(address registry_, address owner_, uint256 initialCommission_)
        StakingAdmin(registry_, owner_, initialCommission_)
    {}

    /// @notice Submit a new validator request and create its vault and canonical gauge.
    /// @dev The controller is the registry requester; `msg.sender` is the operator
    ///      whose salt determines the vault address and whose identity is registered.
    function createValidator(
        bytes32 saltSeed,
        address expectedAuthAddress,
        bytes calldata payload,
        bytes calldata signedSecpMessage,
        bytes calldata signedBlsMessage
    ) external override nonReentrant returns (uint256 requestId, address vault, address gauge) {
        return _createValidator(msg.sender, saltSeed, expectedAuthAddress, payload, signedSecpMessage, signedBlsMessage);
    }

    modifier onlyNewCycle(uint256 tokenId) {
        uint64 currentCycle = ProtocolTimeLibrary.currentCycle();
        if (_intentGauges[tokenId].length != 0 && currentCycle <= stakingCycleOf[tokenId]) {
            revert StakingCycleNotAdvanced();
        }
        // Keep the cycle marker in the modifier, like Tigris records
        // `lastVoted` for a successful vote. A revert in the body rolls this
        // assignment back, so invalid requests do not consume the cycle.
        stakingCycleOf[tokenId] = currentCycle;
        _;
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
        if (!isValidatorGauge[gauge]) return false;
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
        address[] storage gauges = _tokenGauges[tokenId];
        address agent = agentByToken[tokenId];
        for (uint256 i; i < gauges.length; ++i) {
            Position memory position = _positionOf(tokenId, gauges[i], agent);
            if (
                position.vaultAllocation + position.agentAllocation != 0
                    || position.vaultPending + position.agentPending != 0 || intentOf[tokenId][gauges[i]] != 0
            ) return false;
        }
        return true;
    }

    /// @dev Receives redeemed MON from a token's vault or agent.
    receive() external payable {
        if (!_isVault[msg.sender] && !_isAgent[msg.sender]) revert UnexpectedEtherSender();
    }

    /// @notice Set the token's validator allocation intent for this cycle.
    /// @dev The first call allocates from `balanceOf(tokenId)`. Later calls
    ///      replace the prior intent and begin a physical rebalance. A later
    ///      cycle does not require a caller-side `unstake` first.
    function stake(uint256 tokenId, address[] calldata gauges, uint256[] calldata amounts)
        external
        override
        nonReentrant
        onlyNewCycle(tokenId)
    {
        _requireTokenOwner(tokenId);
        if (gauges.length == 0) revert EmptyArray();
        if (gauges.length != amounts.length) revert LengthMismatch();

        uint256 total = 0;
        for (uint256 i; i < gauges.length; ++i) {
            if (amounts[i] == 0) revert ZeroAmount();
            if (vaultByGauge[gauges[i]] == address(0)) revert InvalidVault();
            for (uint256 j; j < i; ++j) {
                if (gauges[j] == gauges[i]) revert DuplicateGauge();
            }
            total += amounts[i];
        }

        bool initialStake = _intentGauges[tokenId].length == 0;
        _setIntent(tokenId, gauges, amounts);
        if (initialStake && balanceOf[tokenId] < total) revert InsufficientBalance();

        _poke(tokenId);
        emit Staked(tokenId, total);
    }

    /// @notice Progress a token's physical allocations toward its latest intent.
    /// @dev Anyone may call this. Monad withdrawal delays make rebalancing
    ///      multi-step: matured withdrawals become liquid first, then surplus
    ///      is undelegated and available MON is delegated toward deficits.
    function poke(uint256 tokenId) external override nonReentrant returns (bool satisfied) {
        satisfied = _poke(tokenId);
        emit StakingPoked(tokenId, stakingCycleOf[tokenId], satisfied);
    }

    /// @notice Compound only this token's accrued vault and agent rewards.
    function compound(uint256 tokenId) external override nonReentrant returns (uint256 amount) {
        _requireTokenOwner(tokenId);
        address[] storage gauges = _tokenRewardGauges[tokenId];
        if (gauges.length == 0) revert EmptyArray();

        uint256 beforeBalance = address(this).balance;
        uint256[] memory gaugeRewards = new uint256[](gauges.length);
        address agent = agentByToken[tokenId];
        uint64[] memory agentValidators = new uint64[](gauges.length);
        uint256[] memory agentGaugeIndexes = new uint256[](gauges.length);
        uint256 agentValidatorCount;

        for (uint256 i; i < gauges.length; ++i) {
            address gauge = gauges[i];
            address vaultAddress = vaultByGauge[gauge];
            if (vaultAddress == address(0)) revert InvalidVault();

            StakingVault vault = StakingVault(payable(vaultAddress));
            uint64 validatorId = vault.validatorId();
            if (validatorId == 0) continue;

            gaugeRewards[i] = vault.claimReward(tokenId, address(this));
            if (agent != address(0) && StakingAgent(payable(agent)).usedValidator(validatorId)) {
                agentValidators[agentValidatorCount] = validatorId;
                agentGaugeIndexes[agentValidatorCount] = i;
                ++agentValidatorCount;
            }
        }

        uint256[] memory agentRewards;
        if (agentValidatorCount != 0) {
            assembly ("memory-safe") {
                mstore(agentValidators, agentValidatorCount)
                mstore(agentGaugeIndexes, agentValidatorCount)
            }
            agentRewards = StakingAgent(payable(agent)).claimRewards(agentValidators);
            for (uint256 i; i < agentRewards.length; ++i) {
                gaugeRewards[agentGaugeIndexes[i]] += agentRewards[i];
            }
        }

        amount = address(this).balance - beforeBalance;
        if (amount == 0) {
            emit Compounded(tokenId, 0);
            return 0;
        }

        // The harvested MON is now a token-specific liquid principal balance.
        balanceOf[tokenId] += amount;
        for (uint256 i; i < gauges.length; ++i) {
            uint256 reward = gaugeRewards[i];
            if (reward == 0) continue;
            address gauge = gauges[i];
            _rememberTokenGauge(tokenId, gauge);
            _increaseIntent(tokenId, gauge, reward);
        }
        IVotingEscrow(ve).increaseAmountFromController(tokenId, amount);
        _poke(tokenId);

        emit Compounded(tokenId, amount);
    }

    /// @notice Begin reclaiming MON previously allocated by `stake` for a token.
    /// @dev Monad requires undelegation and withdrawal to happen in different
    ///      epochs.
    function unstake(uint256 tokenId, address[] calldata gauges, uint256[] calldata amounts)
        external
        override
        nonReentrant
    {
        uint64 currentCycle = ProtocolTimeLibrary.currentCycle();
        if (_intentGauges[tokenId].length != 0 && currentCycle <= stakingCycleOf[tokenId]) {
            revert StakingCycleNotAdvanced();
        }

        _requireTokenOwner(tokenId);
        if (gauges.length == 0) revert EmptyArray();
        if (gauges.length != amounts.length) revert LengthMismatch();

        for (uint256 i; i < gauges.length; ++i) {
            address gauge = gauges[i];
            if (amounts[i] == 0) revert ZeroAmount();
            if (vaultByGauge[gauge] == address(0)) revert InvalidVault();
            if (_pendingOf(tokenId, gauge) != 0) _withdraw(tokenId, gauge);
            _rememberTokenGauge(tokenId, gauge);
            _undelegate(tokenId, gauge, amounts[i]);
            _reduceIntent(tokenId, gauge, amounts[i]);
        }
        emit Unstaked(tokenId, _sum(amounts));
    }

    function _poke(uint256 tokenId) internal returns (bool satisfied) {
        if (_intentGauges[tokenId].length == 0) return true;

        address[] storage gauges = _tokenGauges[tokenId];
        PokeBatch memory batch = PokeBatch({
            agent: agentByToken[tokenId],
            liquid: balanceOf[tokenId],
            delegateCount: 0,
            delegateValue: 0,
            delegateValidators: new uint64[](gauges.length),
            delegateAmounts: new uint256[](gauges.length)
        });
        uint256 i;
        satisfied = true;

        while (i < gauges.length) {
            address gauge = gauges[i];
            if (!_processPokeGauge(tokenId, gauge, batch)) satisfied = false;
            if (_tokenGaugeIndex[tokenId][gauge] != 0) ++i;
        }

        _executeDelegateBatch(batch);

        balanceOf[tokenId] = batch.liquid;
    }

    function _processPokeGauge(uint256 tokenId, address gauge, PokeBatch memory batch)
        internal
        returns (bool satisfied)
    {
        Position memory position = _positionOf(tokenId, gauge, batch.agent);
        if (position.vaultPending != 0 || position.agentPending != 0) {
            uint256 reclaimed;
            (reclaimed, satisfied) = _withdrawFromPosition(tokenId, gauge, position);
            batch.liquid += reclaimed;
            if (!satisfied) return false;
        }

        uint256 current = position.vaultAllocation + position.agentAllocation;
        uint256 target = intentOf[tokenId][gauge];
        if (current > target) {
            // A new withdrawal is not liquid until a later poke.
            if (position.validatorId == 0) {
                position.validatorId = StakingVault(payable(position.vault)).validatorId();
            }
            _tryUndelegate(tokenId, position, current - target);
            return false;
        }

        satisfied = true;
        if (current < target) {
            uint256 amount = target - current;
            if (amount > batch.liquid) amount = batch.liquid;
            if (amount != 0) {
                batch.liquid -= amount;
                uint64 validatorId;
                uint256 remainder;
                (batch.agent, validatorId, remainder) = _queueDelegate(tokenId, position, amount, batch.agent);
                if (remainder != 0) {
                    batch.delegateValidators[batch.delegateCount] = validatorId;
                    batch.delegateAmounts[batch.delegateCount] = remainder;
                    batch.delegateValue += remainder;
                    ++batch.delegateCount;
                }
                current += amount;
            }
        }

        if (current != target) satisfied = false;
    }

    function _executeDelegateBatch(PokeBatch memory batch) internal {
        if (batch.delegateCount == 0) return;
        if (batch.delegateCount == 1) {
            StakingAgent(payable(batch.agent)).delegate{value: batch.delegateValue}(
                batch.delegateValidators[0], batch.delegateAmounts[0]
            );
        } else {
            uint64[] memory validators = batch.delegateValidators;
            uint256[] memory amounts = batch.delegateAmounts;
            uint256 count = batch.delegateCount;
            assembly {
                mstore(validators, count)
                mstore(amounts, count)
            }
            StakingAgent(payable(batch.agent)).delegate{value: batch.delegateValue}(validators, amounts);
        }
    }

    function _setIntent(uint256 tokenId, address[] calldata gauges, uint256[] calldata amounts) internal {
        address[] storage previous = _intentGauges[tokenId];
        for (uint256 i; i < previous.length; ++i) {
            delete intentOf[tokenId][previous[i]];
            delete _intentGaugeIndex[tokenId][previous[i]];
        }
        delete _intentGauges[tokenId];
        for (uint256 i; i < gauges.length; ++i) {
            address gauge = gauges[i];
            previous.push(gauge);
            _intentGaugeIndex[tokenId][gauge] = i + 1;
            intentOf[tokenId][gauge] = amounts[i];
            _rememberTokenGauge(tokenId, gauge);
        }
        emit StakingIntentSet(tokenId, stakingCycleOf[tokenId]);
    }

    function _tryUndelegate(uint256 tokenId, Position memory position, uint256 amount) internal returns (bool success) {
        if (amount == 0) return true;

        uint256 agentAmount = position.agent == address(0) || position.validatorId == 0 ? 0 : position.agentAllocation;
        uint256 fromAgent = amount < agentAmount ? amount : agentAmount;

        if (fromAgent != 0) {
            try StakingAgent(payable(position.agent)).undelegate(position.validatorId, fromAgent) {}
            catch {
                return false;
            }
        }

        uint256 fromVault = amount - fromAgent;
        if (fromVault == 0) return true;
        if (position.vaultAllocation < fromVault) return false;
        try StakingVault(payable(position.vault)).undelegate(tokenId, fromVault) {}
        catch {
            return false;
        }
        return true;
    }

    /// @dev Routes a token's allocation through its validator vault first, then
    ///      delegates any remainder through the token-bound agent.
    ///      The caller must verify and deduct the token's available balance
    ///      before calling this function.
    function _queueDelegate(uint256 tokenId, Position memory position, uint256 amount, address agent)
        internal
        returns (address, uint64 validatorId, uint256 remainder)
    {
        uint256 deficit = StakingVault(payable(position.vault)).deficit();
        uint256 toVault = amount < deficit ? amount : deficit;
        validatorId = position.validatorId;
        if (toVault != 0) {
            validatorId = StakingVault(payable(position.vault)).deposit{value: toVault}(tokenId);
        }

        remainder = amount - toVault;
        if (validatorId == 0) validatorId = StakingVault(payable(position.vault)).validatorId();
        address validatorGauge = gaugeByVault[position.vault];
        if (validatorId != 0 && isValidatorGauge[validatorGauge]) {
            _bindValidatorGauge(validatorGauge, validatorId);
        }
        if (remainder == 0) return (agent, 0, 0);

        if (validatorId == 0) revert ValidatorNotActivated();

        if (agent == address(0)) {
            agent = Clones.cloneDeterministic(agentImplementation, bytes32(tokenId));
            agentByToken[tokenId] = agent;
            _isAgent[agent] = true;
            emit AgentCreated(tokenId, agent);
        }
        return (agent, validatorId, remainder);
    }

    function _reduceIntent(uint256 tokenId, address gauge, uint256 amount) internal {
        uint256 target = intentOf[tokenId][gauge];
        if (target <= amount) {
            delete intentOf[tokenId][gauge];
            return;
        }
        intentOf[tokenId][gauge] = target - amount;
    }

    /// @dev Undelegates from the token-bound agent first, then from the
    ///      validator vault. The caller must validate the amount, vault, and
    ///      any existing pending withdrawal before calling this function.
    function _undelegate(uint256 tokenId, address gauge, uint256 amount) internal {
        address vault = vaultByGauge[gauge];
        uint64 validatorId = StakingVault(payable(vault)).validatorId();
        address agent = agentByToken[tokenId];
        uint256 agentAmount =
            agent == address(0) || validatorId == 0 ? 0 : StakingAgent(payable(agent)).balanceOf(validatorId);
        uint256 fromAgent = amount < agentAmount ? amount : agentAmount;
        if (fromAgent != 0) {
            StakingAgent(payable(agent)).undelegate(validatorId, fromAgent);
        }

        uint256 fromVault = amount - fromAgent;
        if (fromVault != 0) {
            if (StakingVault(payable(vault)).balanceOf(tokenId) < fromVault) revert InvalidUnstakeAmount();
            StakingVault(payable(vault)).undelegate(tokenId, fromVault);
        }
    }

    /// @dev Withdraws matured validator proceeds and credits them to the token balance.
    ///      The caller can later release that balance to the veNFT owner.
    function _withdraw(uint256 tokenId, address gauge) internal returns (uint256 reclaimed) {
        Position memory position = _positionOf(tokenId, gauge, agentByToken[tokenId]);
        (reclaimed,) = _withdrawFromPosition(tokenId, gauge, position);
        balanceOf[tokenId] += reclaimed;
    }

    function _withdrawFromPosition(uint256 tokenId, address gauge, Position memory position)
        internal
        returns (uint256 reclaimed, bool complete)
    {
        uint256 beforeBalance = address(this).balance;
        complete = true;
        if (position.vaultPending != 0) {
            if (StakingVault(payable(position.vault)).withdraw(tokenId) == 0) complete = false;
        }
        if (position.agentPending != 0) {
            try StakingAgent(payable(position.agent)).withdraw(position.validatorId) {}
            catch {
                complete = false;
            }
        }
        reclaimed = address(this).balance - beforeBalance;
        if ((position.vaultPending != 0 || position.agentPending != 0) && complete) {
            if (position.vaultAllocation == 0 && position.agentAllocation == 0 && intentOf[tokenId][gauge] == 0) {
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
        Position memory position = _positionOf(tokenId, gauge, agentByToken[tokenId]);
        allocation = position.vaultAllocation + position.agentAllocation;
    }

    function _positionOf(uint256 tokenId, address gauge, address agent)
        internal
        view
        returns (Position memory position)
    {
        position.vault = vaultByGauge[gauge];
        if (position.vault == address(0)) return position;
        StakingVault vault = StakingVault(payable(position.vault));
        (position.vaultAllocation, position.vaultPending, position.validatorId) = vault.positionOf(tokenId);
        position.agent = agent;
        if (agent != address(0)) {
            if (position.validatorId != 0) {
                StakingAgent tokenAgent = StakingAgent(payable(agent));
                (position.agentAllocation, position.agentPending) = tokenAgent.positionOf(position.validatorId);
            }
        }
    }

    function _pendingOf(uint256 tokenId, address gauge) internal view returns (uint256 pending) {
        Position memory position = _positionOf(tokenId, gauge, agentByToken[tokenId]);
        pending = position.vaultPending + position.agentPending;
    }

    function _rememberTokenGauge(uint256 tokenId, address gauge) internal {
        if (_tokenGaugeIndex[tokenId][gauge] == 0) {
            _tokenGauges[tokenId].push(gauge);
            _tokenGaugeIndex[tokenId][gauge] = _tokenGauges[tokenId].length;
        }
        if (_tokenRewardGaugeIndex[tokenId][gauge] == 0) {
            _tokenRewardGauges[tokenId].push(gauge);
            _tokenRewardGaugeIndex[tokenId][gauge] = _tokenRewardGauges[tokenId].length;
        }
    }

    function _increaseIntent(uint256 tokenId, address gauge, uint256 amount) internal {
        if (amount == 0) return;
        intentOf[tokenId][gauge] += amount;
        if (_intentGaugeIndex[tokenId][gauge] == 0) {
            _intentGauges[tokenId].push(gauge);
            _intentGaugeIndex[tokenId][gauge] = _intentGauges[tokenId].length;
        }
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

    /// @notice Withdraw every matured validator position and send the liquid balance to the NFT owner.
    function withdraw(uint256 tokenId) external override nonReentrant returns (uint256 amount) {
        if (msg.sender != _ve()) revert NotVe();
        address tokenOwner = IVotingEscrow(_ve()).ownerOf(tokenId);

        uint256 i;
        while (i < _tokenGauges[tokenId].length) {
            address gauge = _tokenGauges[tokenId][i];
            if (vaultByGauge[gauge] == address(0)) revert InvalidVault();
            _withdraw(tokenId, gauge);
            if (_tokenGaugeIndex[tokenId][gauge] != 0) ++i;
        }

        if (!_isFullyUnstaked(tokenId)) revert InvalidUnstakeAmount();
        amount = balanceOf[tokenId];
        if (amount == 0) revert InvalidUnstakeAmount();

        amount += _claimTokenRewards(tokenId, _tokenRewardGauges[tokenId]);

        balanceOf[tokenId] = 0;
        delete _tokenGauges[tokenId];
        _clearTokenRewardGauges(tokenId);
        (bool success,) = payable(tokenOwner).call{value: amount}("");
        if (!success) revert TransferFailed();
        emit Withdrawn(tokenId, amount);
    }

    /// @notice Claim only rewards earned by this token's own positions.
    function claimRewards(uint256 tokenId, address[] calldata gauges) external override nonReentrant {
        address tokenOwner = IVotingEscrow(_ve()).ownerOf(tokenId);
        if (tokenOwner != msg.sender) revert NotTokenOwner();
        uint256 beforeBalance = address(this).balance;
        for (uint256 i; i < gauges.length; ++i) {
            address gauge = gauges[i];
            address vault = vaultByGauge[gauge];
            if (vault == address(0)) revert InvalidVault();
            for (uint256 j; j < i; ++j) {
                if (gauges[j] == gauge) revert DuplicateGauge();
            }

            if (_tokenRewardGaugeIndex[tokenId][gauge] == 0) revert NotGaugeParticipant();
            _claimGaugeReward(tokenId, gauge);
        }

        uint256 amount = address(this).balance - beforeBalance;
        if (amount != 0) {
            (bool success,) = payable(tokenOwner).call{value: amount}("");
            if (!success) revert TransferFailed();
        }
        _pruneTokenRewardGauges(tokenId, gauges);
        emit RewardsClaimed(tokenId, amount);
    }

    function _claimTokenRewards(uint256 tokenId, address[] storage gauges) internal returns (uint256 amount) {
        uint256 beforeBalance = address(this).balance;
        uint256 length = gauges.length;
        for (uint256 i; i < length; ++i) {
            _claimGaugeReward(tokenId, gauges[i]);
        }
        amount = address(this).balance - beforeBalance;
    }

    function _claimGaugeReward(uint256 tokenId, address gauge) internal {
        address vaultAddress = vaultByGauge[gauge];
        if (vaultAddress == address(0)) revert InvalidVault();
        StakingVault vault = StakingVault(payable(vaultAddress));
        uint64 validatorId = vault.validatorId();
        if (validatorId == 0) return;

        vault.claimReward(tokenId, address(this));
        address agent = agentByToken[tokenId];
        if (agent != address(0) && StakingAgent(payable(agent)).usedValidator(validatorId)) {
            uint64[] memory validatorIds = new uint64[](1);
            validatorIds[0] = validatorId;
            StakingAgent(payable(agent)).claimRewards(validatorIds);
        }
    }

    function _removeTokenRewardGauge(uint256 tokenId, address gauge) internal {
        uint256 indexPlusOne = _tokenRewardGaugeIndex[tokenId][gauge];
        if (indexPlusOne == 0) return;
        address[] storage gauges = _tokenRewardGauges[tokenId];
        uint256 index = indexPlusOne - 1;
        uint256 last = gauges.length - 1;
        if (index != last) {
            address replacement = gauges[last];
            gauges[index] = replacement;
            _tokenRewardGaugeIndex[tokenId][replacement] = index + 1;
        }
        gauges.pop();
        delete _tokenRewardGaugeIndex[tokenId][gauge];
    }

    function _pruneTokenRewardGauges(uint256 tokenId, address[] calldata gauges) internal {
        for (uint256 i; i < gauges.length; ++i) {
            address gauge = gauges[i];
            if (_allocationOf(tokenId, gauge) == 0 && _pendingOf(tokenId, gauge) == 0) {
                address vault = vaultByGauge[gauge];
                if (vault == address(0) || StakingVault(payable(vault)).earned(tokenId) == 0) {
                    _removeTokenRewardGauge(tokenId, gauge);
                }
            }
        }
    }

    function _clearTokenRewardGauges(uint256 tokenId) internal {
        address[] storage gauges = _tokenRewardGauges[tokenId];
        while (gauges.length != 0) {
            address gauge = gauges[gauges.length - 1];
            delete _tokenRewardGaugeIndex[tokenId][gauge];
            gauges.pop();
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
