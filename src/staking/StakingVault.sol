// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StakeControlled} from "./StakeControlled.sol";

import {IValidatorRegistry} from "../interfaces/IValidatorRegistry.sol";

/// @title StakingVault
/// @notice MON vault bound to exactly one validator.
contract StakingVault is StakeControlled {
    uint256 public constant MIN_AUTH_ADDRESS_STAKE = 100_000 ether;

    IValidatorRegistry public registry;
    mapping(uint256 tokenId => uint256 amount) public balanceOf;
    uint256 public totalBalance;

    /// @notice The only validator request this vault can execute.
    uint256 public requestId;

    /// @notice Set after the request is successfully executed.
    uint64 public validatorId;

    error ValidatorAlreadyAdded();
    error ValidatorNotAdded();
    error InvalidRequest();
    error AddValidatorFailed();
    error UndelegationFailed();
    error TransferFailed();
    error InvalidAmount();

    uint8 public constant WITHDRAW_ID = 0;

    /// @notice Called by the controller immediately after cloning.
    function initialize(address registry_, uint256 requestId_) external onlyController initializer {
        if (registry_ == address(0) || requestId_ == 0) revert InvalidRequest();

        registry = IValidatorRegistry(registry_);
        requestId = requestId_;
    }

    function deficit() public view returns (uint256) {
        return MIN_AUTH_ADDRESS_STAKE - totalBalance;
    }

    /// @notice Accounts deposits and uses the registry to activate the validator.
    /// @dev The controller caps the value forwarded here. The vault itself also
    ///      enforces the cap so it can never overfund validator creation.
    function deposit(uint256 tokenId) external payable onlyController {
        if (msg.value == 0 || deficit() < msg.value) revert InvalidAmount();

        balanceOf[tokenId] += msg.value;
        totalBalance += msg.value;

        if (deficit() != 0) return;

        uint256 balance = availableBalance();
        if (validatorId != 0) {
            STAKING.delegate{value: balance}(validatorId);
        } else {
            validatorId = registry.addValidator{value: balance}(requestId);
            if (validatorId == 0) revert AddValidatorFailed();
        }
    }

    /// @notice Begin withdrawing the vault's entire validator stake.
    function undelegate() external onlyController {
        (uint256 stake,,,,,,) = STAKING.getDelegator(validatorId, address(this));
        if (stake == 0 || !STAKING.undelegate(validatorId, stake, WITHDRAW_ID)) {
            revert UndelegationFailed();
        }
    }

    function withdraw(uint256 tokenId) external onlyController returns (uint256 amount) {
        amount = balanceOf[tokenId];
        if (amount == 0) revert InvalidAmount();

        if (availableBalance() < amount) {
            if (!STAKING.withdraw(validatorId, WITHDRAW_ID)) return 0;
        }

        delete balanceOf[tokenId];
        totalBalance -= amount;

        (bool success,) = payable(controller).call{value: amount}("");
        if (!success) revert TransferFailed();
    }
}
