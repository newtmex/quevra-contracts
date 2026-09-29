// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IValidatorRegistry} from "../interfaces/IValidatorRegistry.sol";
import {IBaseVoter} from "../interfaces/IBaseVoter.sol";
import {IStakingController} from "../interfaces/IStakingController.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
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
    address[] private _registeredGauges;
    mapping(address => bool) private _isVault;
    mapping(address => bool) private _isAgent;
    mapping(uint256 tokenId => uint256 amount) public override balanceOf;
    mapping(uint256 tokenId => address agent) public override agentByToken;
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
        _registeredGauges.push(gauge);
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
        address vault = vaultByGauge[gauge];
        if (vault == address(0)) return 0;
        allocation = StakingVault(payable(vault)).balanceOf(tokenId);
        uint64 validatorId = StakingVault(payable(vault)).validatorId();
        address agent = agentByToken[tokenId];
        if (agent != address(0) && validatorId != 0) {
            allocation += StakingAgent(payable(agent)).balanceOf(validatorId);
        }
    }

    function pendingOf(uint256 tokenId, address gauge) external view returns (uint256 pending) {
        address vault = vaultByGauge[gauge];
        if (vault == address(0)) return 0;
        uint64 validatorId = StakingVault(payable(vault)).validatorId();
        pending = StakingVault(payable(vault)).pendingWithdrawal(tokenId);
        address agent = agentByToken[tokenId];
        if (agent != address(0) && validatorId != 0) {
            pending += StakingAgent(payable(agent)).pendingWithdrawal(validatorId);
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

        for (uint256 i; i < amounts.length; ++i) {
            if (amounts[i] == 0) revert ZeroAmount();
        }
        for (uint256 i; i < gauges.length; ++i) {
            _stake(tokenId, gauges[i], amounts[i]);
        }
        emit Staked(tokenId, _sum(amounts));
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

        for (uint256 i; i < gauges.length; ++i) {
            if (amounts[i] == 0) revert ZeroAmount();
            _unstake(tokenId, gauges[i], amounts[i]);
        }
        emit Unstaked(tokenId, _sum(amounts));
    }

    function _stake(uint256 tokenId, address gauge, uint256 amount) internal {
        address vault = vaultByGauge[gauge];
        if (vault == address(0)) revert InvalidVault();
        _finalize(tokenId, gauge);
        if (balanceOf[tokenId] < amount) revert InsufficientBalance();
        balanceOf[tokenId] -= amount;
        uint256 deficit = StakingVault(payable(vault)).deficit();
        bool wasActivated = StakingVault(payable(vault)).validatorId() != 0;
        uint256 toVault = amount < deficit ? amount : deficit;
        if (toVault != 0) StakingVault(payable(vault)).deposit{value: toVault}(tokenId);
        uint256 remainder = amount - toVault;
        if (remainder != 0) {
            uint64 validatorId = StakingVault(payable(vault)).validatorId();
            if (validatorId == 0) revert ValidatorNotActivated();
            address agent = _agent(tokenId);
            uint64[] memory ids = new uint64[](1);
            uint256[] memory values = new uint256[](1);
            ids[0] = validatorId;
            values[0] = remainder;
            StakingAgent(payable(agent)).delegate{value: remainder}(ids, values);
            _notify(tokenId, gauge, int256(remainder));
        } else if (StakingVault(payable(vault)).validatorId() != 0 && wasActivated) {
            _notify(tokenId, gauge, int256(toVault));
        }
    }

    /// @dev Called by a vault exactly once when its validator is activated.
    function vaultActivated(address vault) external {
        if (!_isVault[msg.sender] || msg.sender != vault) revert InvalidVault();
        address gauge;
        // Gauges are the external key for vaults. There is intentionally no
        // second vault->gauge mapping; scan is bounded by the number of
        // registered validators and activation is a one-time operation.
        // The callback is therefore only used for the vault's own token list.
        for (uint256 i; i < _registeredGauges.length; ++i) {
            if (vaultByGauge[_registeredGauges[i]] == vault) {
                gauge = _registeredGauges[i];
                break;
            }
        }
        if (gauge == address(0)) revert InvalidVault();
        uint256 length = StakingVault(payable(vault)).tokenIdsLength();
        for (uint256 i; i < length; ++i) {
            uint256 tokenId = StakingVault(payable(vault)).tokenIdAt(i);
            _notify(tokenId, gauge, int256(StakingVault(payable(vault)).balanceOf(tokenId)));
        }
    }

    function _unstake(uint256 tokenId, address gauge, uint256 amount) internal {
        address vault = vaultByGauge[gauge];
        if (vault == address(0)) revert InvalidVault();
        _finalize(tokenId, gauge);
        uint64 validatorId = StakingVault(payable(vault)).validatorId();
        address agent = agentByToken[tokenId];
        uint256 agentAmount =
            agent == address(0) || validatorId == 0 ? 0 : StakingAgent(payable(agent)).balanceOf(validatorId);
        uint256 fromAgent = amount < agentAmount ? amount : agentAmount;
        if (fromAgent != 0) {
            uint64[] memory ids = new uint64[](1);
            uint256[] memory values = new uint256[](1);
            ids[0] = validatorId;
            values[0] = fromAgent;
            StakingAgent(payable(agent)).undelegate(ids, values);
            _notify(tokenId, gauge, -int256(fromAgent));
        }
        uint256 fromVault = amount - fromAgent;
        if (fromVault != 0) {
            if (StakingVault(payable(vault)).balanceOf(tokenId) < fromVault) revert InvalidUnstakeAmount();
            StakingVault(payable(vault)).undelegate(tokenId, fromVault);
            _notify(tokenId, gauge, -int256(fromVault));
        }
    }

    function _finalize(uint256 tokenId, address gauge) internal {
        address vault = vaultByGauge[gauge];
        uint256 beforeBalance = address(this).balance;
        if (StakingVault(payable(vault)).pendingWithdrawal(tokenId) != 0) {
            StakingVault(payable(vault)).withdraw(tokenId);
        }
        address agent = agentByToken[tokenId];
        if (agent != address(0)) {
            uint64 validatorId = StakingVault(payable(vault)).validatorId();
            if (validatorId != 0 && StakingAgent(payable(agent)).pendingWithdrawal(validatorId) != 0) {
                uint64[] memory ids = new uint64[](1);
                ids[0] = validatorId;
                try StakingAgent(payable(agent)).withdraw(ids) {} catch {}
            }
        }
        balanceOf[tokenId] += address(this).balance - beforeBalance;
    }

    function _agent(uint256 tokenId) internal returns (address agent) {
        agent = agentByToken[tokenId];
        if (agent == address(0)) {
            agent = address(new StakingAgent());
            agentByToken[tokenId] = agent;
            _isAgent[agent] = true;
            emit AgentCreated(tokenId, agent);
        }
    }

    function _notify(uint256 tokenId, address gauge, int256 amount) internal {
        if (amount != 0 && voter != address(0)) {
            (bool ok,) = voter.call(
                abi.encodeWithSignature("updateStakingAmount(uint256,address,int256)", tokenId, gauge, amount)
            );
            if (!ok) revert UnexpectedEtherSender();
        }
    }

    function _sum(uint256[] calldata values) private pure returns (uint256 total) {
        for (uint256 i; i < values.length; ++i) {
            total += values[i];
        }
    }

    /// @notice Complete a prior `unstake` after Monad's withdrawal delay.
    function withdraw(uint256 tokenId, address[] calldata gauges) external override nonReentrant {
        if (msg.sender != voter) revert NotVoter();
        if (gauges.length == 0) revert EmptyArray();

        uint256 reclaimed;
        for (uint256 i; i < gauges.length; ++i) {
            address vault = vaultByGauge[gauges[i]];
            if (vault == address(0)) revert InvalidVault();
            uint256 beforeBalance = address(this).balance;
            _finalize(tokenId, gauges[i]);
            reclaimed += address(this).balance - beforeBalance;
        }

        if (reclaimed == 0) revert InvalidUnstakeAmount();
        emit Withdrawn(tokenId, reclaimed);
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
        return IBaseVoter(voter).ve();
    }
}
