// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {StakingVault} from "./controlled/StakingVault.sol";
import {StakingAgent} from "./controlled/StakingAgent.sol";
import {StakingAdmin} from "./StakingAdmin.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";
import {StakingRewards} from "../rewards/StakingRewards.sol";
import {StakingControllerRewardsLibrary} from "../libraries/StakingControllerRewardsLibrary.sol";

/// @title StakingController
/// @notice Owns validator vaults and routes MON deposits through the bound vault.
/// @dev User-selected allocations are intent; this contract only settles
///      physical MON toward that intent.
contract StakingController is StakingAdmin, ReentrancyGuardTransient {
    // -------------------------------------------------------------------------
    // Storage and construction
    // -------------------------------------------------------------------------
    using EnumerableSet for EnumerableSet.AddressSet;
    using StakingControllerRewardsLibrary for uint256;

    mapping(uint256 tokenId => uint256 amount) public override balanceOf;
    mapping(uint256 tokenId => address agent) public override agentByToken;
    mapping(uint256 tokenId => uint64 cycle) public override stakingCycleOf;
    
    mapping(uint256 tokenId => mapping(address vault => uint256 amount)) public override intentOf;
    mapping(uint256 tokenId => mapping(address vault => uint256 amount)) public attributedStakeOf;

    mapping(uint256 tokenId => EnumerableSet.AddressSet) private _tokenVaultLists;
    mapping(uint256 tokenId => EnumerableSet.AddressSet) private _tokenRewardVaultLists;
    mapping(uint256 tokenId => address[]) private _intentVaultLists;
    mapping(uint256 tokenId => mapping(address vault => uint256 indexPlusOne)) private _intentVaultIndex;

    constructor(address registry_, address owner_, uint256 initialCommission_)
        StakingAdmin(registry_, owner_, initialCommission_)
    {}

    // -------------------------------------------------------------------------
    // Validator admission and cycle guards
    // -------------------------------------------------------------------------

    /// @notice Submit a new validator request and create its vault and canonical stakingRewards.
    /// @dev The controller is the registry requester; `msg.sender` is the operator
    ///      whose salt determines the vault address and whose identity is registered.
    function createValidator(
        bytes32 saltSeed,
        address expectedAuthAddress,
        bytes calldata payload,
        bytes calldata signedSecpMessage,
        bytes calldata signedBlsMessage
    ) external override nonReentrant returns (uint256 requestId, address vault, address stakingRewards) {
        return _createValidator(msg.sender, saltSeed, expectedAuthAddress, payload, signedSecpMessage, signedBlsMessage);
    }

    modifier onlyNewCycle(uint256 tokenId) {
        uint64 currentCycle = ProtocolTimeLibrary.currentCycle();
        if (_intentVaultLists[tokenId].length != 0 && currentCycle <= stakingCycleOf[tokenId]) {
            revert StakingCycleNotAdvanced();
        }
        // Keep the cycle marker in the modifier, like Tigris records
        // `lastVoted` for a successful vote. A revert in the body rolls this
        // assignment back, so invalid requests do not consume the cycle.
        stakingCycleOf[tokenId] = currentCycle;
        _;
    }

    // -------------------------------------------------------------------------
    // External state-changing API
    // -------------------------------------------------------------------------

    function deposit(uint256 tokenId) external payable override nonReentrant {
        if (ve == address(0) || msg.sender != ve) revert NotVe();
        if (msg.value == 0) revert InvalidDepositAmount();
        balanceOf[tokenId] += msg.value;
        emit MONDeposited(tokenId, msg.value);
    }

    /// @dev Receives redeemed MON from a token's vault or agent.
    receive() external payable {
        if (!_isVault[msg.sender] && !_isAgent[msg.sender]) revert UnexpectedEtherSender();
    }

    // -------------------------------------------------------------------------
    // External state-changing API: intent and rebalancing
    // -------------------------------------------------------------------------

    /// @notice Set the token's validator allocation intent for this cycle.
    /// @dev The first call allocates from `balanceOf(tokenId)`. Later calls
    ///      replace the prior intent and begin a physical rebalance. A later
    ///      cycle does not require a caller-side `unstake` first.
    function stake(uint256 tokenId, address[] calldata vaults, uint256[] calldata amounts)
        external
        override
        nonReentrant
        onlyNewCycle(tokenId)
    {
        _requireTokenOwner(tokenId);
        if (vaults.length == 0) revert EmptyArray();
        if (vaults.length != amounts.length) revert LengthMismatch();

        uint256 total = 0;
        for (uint256 i; i < vaults.length; ++i) {
            if (amounts[i] == 0) revert ZeroAmount();
            if (stakingRewardsByVault[vaults[i]] == address(0)) revert InvalidVault();
            for (uint256 j; j < i; ++j) {
                if (vaults[j] == vaults[i]) revert DuplicateVault();
            }
            total += amounts[i];
        }

        bool initialStake = _intentVaultLists[tokenId].length == 0;
        _setIntent(tokenId, vaults, amounts);
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
        address[] memory vaults = _tokenRewardVaultLists[tokenId].values();
        if (vaults.length == 0) revert EmptyArray();

        uint256 beforeBalance = address(this).balance;
        uint256[] memory stakingRewardsRewards = new uint256[](vaults.length);
        address agent = agentByToken[tokenId];
        uint64[] memory agentValidators = new uint64[](vaults.length);
        uint256[] memory agentStakingRewardsIndexes = new uint256[](vaults.length);
        uint256 agentValidatorCount;

        for (uint256 i; i < vaults.length; ++i) {
            address vault = vaults[i];
            if (stakingRewardsByVault[vault] == address(0)) revert InvalidVault();

            StakingVault vaultContract = StakingVault(payable(vault));
            uint64 validatorId = vaultContract.validatorId();
            if (validatorId == 0) continue;

            stakingRewardsRewards[i] = vaultContract.claimReward(tokenId, address(this));
            if (agent != address(0) && StakingAgent(payable(agent)).usedValidator(validatorId)) {
                agentValidators[agentValidatorCount] = validatorId;
                agentStakingRewardsIndexes[agentValidatorCount] = i;
                ++agentValidatorCount;
            }
        }

        uint256[] memory agentRewards;
        if (agentValidatorCount != 0) {
            assembly ("memory-safe") {
                mstore(agentValidators, agentValidatorCount)
                mstore(agentStakingRewardsIndexes, agentValidatorCount)
            }
            agentRewards = StakingAgent(payable(agent)).claimRewards(agentValidators);
            for (uint256 i; i < agentRewards.length; ++i) {
                stakingRewardsRewards[agentStakingRewardsIndexes[i]] += agentRewards[i];
            }
        }

        amount = address(this).balance - beforeBalance;
        if (amount == 0) {
            emit Compounded(tokenId, 0);
            return 0;
        }

        // The harvested MON is now a token-specific liquid principal balance.
        balanceOf[tokenId] += amount;
        for (uint256 i; i < vaults.length; ++i) {
            uint256 reward = stakingRewardsRewards[i];
            if (reward == 0) continue;
            _recordCompoundedReward(tokenId, vaults[i], reward);
        }
        IVotingEscrow(ve).increaseAmountFromController(tokenId, amount);
        _poke(tokenId);

        emit Compounded(tokenId, amount);
    }

    /// @notice Begin reclaiming MON previously allocated by `stake` for a token.
    /// @dev Monad requires undelegation and withdrawal to happen in different
    ///      epochs.
    function unstake(uint256 tokenId, address[] calldata vaults, uint256[] calldata amounts)
        external
        override
        nonReentrant
    {
        uint64 currentCycle = ProtocolTimeLibrary.currentCycle();
        if (_intentVaultLists[tokenId].length != 0 && currentCycle <= stakingCycleOf[tokenId]) {
            revert StakingCycleNotAdvanced();
        }

        _requireTokenOwner(tokenId);
        if (vaults.length == 0) revert EmptyArray();
        if (vaults.length != amounts.length) revert LengthMismatch();

        for (uint256 i; i < vaults.length; ++i) {
            address vault = vaults[i];
            if (amounts[i] == 0) revert ZeroAmount();
            if (stakingRewardsByVault[vault] == address(0)) revert InvalidVault();
            if (_pendingOf(tokenId, vault) != 0) _withdraw(tokenId, vault);
            tokenId.rememberVault(vault, _tokenVaultLists, _tokenRewardVaultLists);
            _undelegate(tokenId, vault, amounts[i]);
            _removeVaultStake(tokenId, vault, amounts[i]);
            tokenId.reduceIntent(vault, amounts[i], intentOf);
        }
        emit Unstaked(tokenId, _sum(amounts));
    }

    /// @notice Withdraw every matured validator position and send the liquid balance to the NFT owner.
    function withdraw(uint256 tokenId) external override nonReentrant returns (uint256 amount) {
        return _withdrawToken(tokenId);
    }

    /// @notice Claim native rewards earned by this token's validator positions.
    function claimRewards(uint256 tokenId, address[] calldata vaults) external override nonReentrant {
        _claimTokenRewardsToOwner(tokenId, vaults);
    }

    // -------------------------------------------------------------------------
    // External and public read API
    // -------------------------------------------------------------------------

    function allocationOf(uint256 tokenId, address vault) external view override returns (uint256 allocation) {
        allocation = _allocationOf(tokenId, vault);
    }

    function isValidatorActive(address stakingRewards) external view override returns (bool) {
        if (!isStakingRewards[stakingRewards]) return false;
        address vault = vaultByStakingRewards[stakingRewards];
        return vault != address(0) && StakingVault(payable(vault)).validatorId() != 0;
    }

    function pendingOf(uint256 tokenId, address vault) external view returns (uint256 pending) {
        pending = _pendingOf(tokenId, vault);
    }

    function isFullyUnstaked(uint256 tokenId) external view override returns (bool) {
        return _isFullyUnstaked(tokenId);
    }

    // -------------------------------------------------------------------------
    // Internal state transitions
    // -------------------------------------------------------------------------

    function _isFullyUnstaked(uint256 tokenId) internal view returns (bool) {
        address[] memory vaults = _tokenVaultLists[tokenId].values();
        address agent = agentByToken[tokenId];
        for (uint256 i; i < vaults.length; ++i) {
            Position memory position = _positionOf(tokenId, vaults[i], agent);
            if (
                position.vaultAllocation + position.agentAllocation != 0
                    || position.vaultPending + position.agentPending != 0 || intentOf[tokenId][vaults[i]] != 0
            ) return false;
        }
        return true;
    }

    function _poke(uint256 tokenId) internal returns (bool satisfied) {
        if (_intentVaultLists[tokenId].length == 0) return true;

        EnumerableSet.AddressSet storage vaults = _tokenVaultLists[tokenId];
        PokeBatch memory batch = PokeBatch({
            agent: agentByToken[tokenId],
            liquid: balanceOf[tokenId],
            delegateCount: 0,
            delegateValue: 0,
            delegateValidators: new uint64[](vaults.length()),
            delegateAmounts: new uint256[](vaults.length())
        });
        uint256 i;
        satisfied = true;

        while (i < vaults.length()) {
            address vault = vaults.at(i);
            if (!_processPokeVault(tokenId, vault, batch)) satisfied = false;
            if (vaults.contains(vault)) ++i;
        }

        _executeDelegateBatch(tokenId, batch);

        balanceOf[tokenId] = batch.liquid;
    }

    function _processPokeVault(uint256 tokenId, address vault, PokeBatch memory batch)
        internal
        returns (bool satisfied)
    {
        Position memory position = _positionOf(tokenId, vault, batch.agent);
        if (position.vaultPending != 0 || position.agentPending != 0) {
            uint256 reclaimed;
            (reclaimed, satisfied) = _withdrawFromPosition(tokenId, vault, position);
            batch.liquid += reclaimed;
            if (!satisfied) return false;
        }

        uint256 current = position.vaultAllocation + position.agentAllocation;
        uint256 target = intentOf[tokenId][vault];
        if (current > target) {
            // A new withdrawal is not liquid until a later poke.
            if (position.validatorId == 0) {
                position.validatorId = StakingVault(payable(position.vault)).validatorId();
            }
            _tryUndelegate(tokenId, position, current - target);
            uint256 currentAfterUndelegate = _allocationOf(tokenId, vault);
            if (current > currentAfterUndelegate) {
                _removeVaultStake(tokenId, vault, current - currentAfterUndelegate);
            }
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

    function _executeDelegateBatch(uint256 tokenId, PokeBatch memory batch) internal {
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
        for (uint256 i; i < batch.delegateCount; ++i) {
            address stakingRewards = stakingRewardsForValidatorId(batch.delegateValidators[i]);
            address vault = vaultForStakingRewards[stakingRewards];
            _attributeStakingRewardsStake(tokenId, vault, batch.delegateAmounts[i]);
        }
    }

    function _setIntent(uint256 tokenId, address[] calldata vaults, uint256[] calldata amounts) internal {
        tokenId.setIntent(vaults, amounts, _intentVaultLists, _intentVaultIndex, intentOf);
        for (uint256 i; i < vaults.length; ++i) {
            tokenId.rememberVault(vaults[i], _tokenVaultLists, _tokenRewardVaultLists);
        }
        emit StakingIntentSet(tokenId, stakingCycleOf[tokenId]);
    }

    // -------------------------------------------------------------------------
    // Internal position movement and withdrawal settlement
    // -------------------------------------------------------------------------

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
        address stakingRewards = stakingRewardsByVault[position.vault];
        if (isStakingRewards[stakingRewards]) {
            if (toVault != 0) _attributeStakingRewardsStake(tokenId, position.vault, toVault);
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

    /// @dev Undelegates from the token-bound agent first, then from the
    ///      validator vault. The caller must validate the amount, vault, and
    ///      any existing pending withdrawal before calling this function.
    function _undelegate(uint256 tokenId, address vault, uint256 amount) internal {
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
    function _withdraw(uint256 tokenId, address vault) internal returns (uint256 reclaimed) {
        Position memory position = _positionOf(tokenId, vault, agentByToken[tokenId]);
        (reclaimed,) = _withdrawFromPosition(tokenId, vault, position);
        balanceOf[tokenId] += reclaimed;
    }

    function _withdrawFromPosition(uint256 tokenId, address vault, Position memory position)
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
            if (position.vaultAllocation == 0 && position.agentAllocation == 0 && intentOf[tokenId][vault] == 0) {
                tokenId.removeVault(vault, _tokenVaultLists);
            }
        }
    }

    function _sum(uint256[] calldata values) private pure returns (uint256 total) {
        for (uint256 i; i < values.length; ++i) {
            total += values[i];
        }
    }

    function _allocationOf(uint256 tokenId, address vault) internal view returns (uint256 allocation) {
        Position memory position = _positionOf(tokenId, vault, agentByToken[tokenId]);
        allocation = position.vaultAllocation + position.agentAllocation;
    }

    function _positionOf(uint256 tokenId, address vaultAddress, address agent)
        internal
        view
        returns (Position memory position)
    {
        position.vault = vaultAddress;
        if (vaultAddress == address(0) || stakingRewardsByVault[vaultAddress] == address(0)) return position;
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

    function _pendingOf(uint256 tokenId, address vault) internal view returns (uint256 pending) {
        Position memory position = _positionOf(tokenId, vault, agentByToken[tokenId]);
        pending = position.vaultPending + position.agentPending;
    }

    // -------------------------------------------------------------------------
    // StakingRewards weight attribution
    // -------------------------------------------------------------------------

    /// @dev Capture this delegation's veMON power proportionally to the locked
    ///      MON. The stored attribution does not change as ve power decays later.
    function _attributeStakingRewardsStake(uint256 tokenId, address vault, uint256 amount) internal {
        if (amount == 0) return;
        address stakingRewards = stakingRewardsByVault[vault];
        if (!isStakingRewards[stakingRewards]) revert InvalidStakingRewards();

        (uint256 votingPower, int128 lockedAmount) = IVotingEscrow(ve).votingPowerAndLockedAmount(tokenId);
        if (lockedAmount <= 0) revert InvalidStakeAttribution();
        uint256 weight = Math.mulDiv(amount, votingPower, uint256(uint128(lockedAmount)));

        attributedStakeOf[tokenId][vault] += amount;
        _increaseStakingRewardsWeight(stakingRewards, tokenId, weight);
    }

    /// @dev Remove the same pro-rata share of previously attributed weight when
    ///      MON is undelegated, including while its withdrawal is still pending.
    function _removeVaultStake(uint256 tokenId, address vault, uint256 amount) internal {
        if (amount == 0) return;
        address stakingRewards = stakingRewardsByVault[vault];
        uint256 previousStake = attributedStakeOf[tokenId][vault];
        if (amount > previousStake) revert InvalidUnstakeAmount();

        uint256 previousWeight = StakingRewards(stakingRewards).balanceOf(tokenId);
        uint256 remainingStake = previousStake - amount;
        uint256 remainingWeight = remainingStake == 0 ? 0 : Math.mulDiv(previousWeight, remainingStake, previousStake);
        attributedStakeOf[tokenId][vault] = remainingStake;
        _decreaseStakingRewardsWeight(stakingRewards, tokenId, previousWeight - remainingWeight);
    }

    // -------------------------------------------------------------------------
    // Internal reward and withdrawal settlement
    // -------------------------------------------------------------------------

    function _withdrawToken(uint256 tokenId) internal returns (uint256 amount) {
        if (msg.sender != _ve()) revert NotVe();
        address tokenOwner = IVotingEscrow(_ve()).ownerOf(tokenId);

        uint256 i;
        EnumerableSet.AddressSet storage vaults = _tokenVaultLists[tokenId];
        while (i < vaults.length()) {
            address vault = vaults.at(i);
            if (stakingRewardsByVault[vault] == address(0)) revert InvalidVault();
            _withdraw(tokenId, vault);
            if (vaults.contains(vault)) ++i;
        }

        if (!_isFullyUnstaked(tokenId)) revert InvalidUnstakeAmount();
        amount = balanceOf[tokenId];
        if (amount == 0) revert InvalidUnstakeAmount();

        amount += _claimTokenRewards(tokenId, _tokenRewardVaultLists[tokenId].values());

        balanceOf[tokenId] = 0;
        tokenId.clearVaultLists(_tokenVaultLists);
        tokenId.clearVaultLists(_tokenRewardVaultLists);
        (bool success,) = payable(tokenOwner).call{value: amount}("");
        if (!success) revert TransferFailed();
        emit Withdrawn(tokenId, amount);
    }

    /// @notice Claim only rewards earned by this token's own positions.
    function _claimTokenRewardsToOwner(uint256 tokenId, address[] calldata vaults) internal {
        address tokenOwner = IVotingEscrow(_ve()).ownerOf(tokenId);
        if (tokenOwner != msg.sender) revert NotTokenOwner();
        uint256 beforeBalance = address(this).balance;
        for (uint256 i; i < vaults.length; ++i) {
            address vault = vaults[i];
            if (stakingRewardsByVault[vault] == address(0)) revert InvalidVault();
            for (uint256 j; j < i; ++j) {
                if (vaults[j] == vault) revert DuplicateVault();
            }

            if (!_tokenRewardVaultLists[tokenId].contains(vault)) {
                revert NotVaultParticipant();
            }
            _claimStakingRewardsReward(tokenId, vault);
        }

        uint256 amount = address(this).balance - beforeBalance;
        if (amount != 0) {
            (bool success,) = payable(tokenOwner).call{value: amount}("");
            if (!success) revert TransferFailed();
        }
        _pruneTokenRewardVaultLists(tokenId, vaults);
        emit RewardsClaimed(tokenId, amount);
    }

    // -------------------------------------------------------------------------
    // Internal reward accounting
    // -------------------------------------------------------------------------

    function _claimTokenRewards(uint256 tokenId, address[] memory vaults) internal returns (uint256 amount) {
        uint256 beforeBalance = address(this).balance;
        uint256 length = vaults.length;
        for (uint256 i; i < length; ++i) {
            _claimStakingRewardsReward(tokenId, vaults[i]);
        }
        amount = address(this).balance - beforeBalance;
    }

    function _claimStakingRewardsReward(uint256 tokenId, address vaultAddress) internal {
        if (stakingRewardsByVault[vaultAddress] == address(0)) revert InvalidVault();
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

    function _pruneTokenRewardVaultLists(uint256 tokenId, address[] calldata vaults) internal {
        for (uint256 i; i < vaults.length; ++i) {
            address vault = vaults[i];
            if (_allocationOf(tokenId, vault) == 0 && _pendingOf(tokenId, vault) == 0) {
                if (stakingRewardsByVault[vault] == address(0) || StakingVault(payable(vault)).earned(tokenId) == 0) {
                    tokenId.removeRewardVault(vault, _tokenRewardVaultLists);
                }
            }
        }
    }

    function _recordCompoundedReward(uint256 tokenId, address vault, uint256 amount) internal {
        tokenId.recordReward(
            vault, amount, _tokenVaultLists, _tokenRewardVaultLists, _intentVaultLists, _intentVaultIndex, intentOf
        );
    }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    function _ve() private view returns (address) {
        return ve;
    }

    function _requireTokenOwner(uint256 tokenId) private view {
        if (msg.sender != IVotingEscrow(_ve()).ownerOf(tokenId)) {
            revert NotTokenOwner();
        }
    }
}
