// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IValidatorRegistry} from "./interfaces/IValidatorRegistry.sol";

/// @title ValidatorGauge
/// @notice Metadata target for future voting and capital-routing integrations.
/// @dev This intentionally contains no voting, rewards, or capital-allocation
///      logic yet. Its immutable links make the target relationship explicit.
contract ValidatorGauge {
    address public immutable registry;
    address public immutable vault;
    address public immutable operator;
    uint256 public immutable requestId;

    constructor(address registry_, address vault_, address operator_, uint256 requestId_) {
        registry = registry_;
        vault = vault_;
        operator = operator_;
        requestId = requestId_;
    }

    /// @notice Becomes nonzero after the vault executes its bound request.
    function validatorId() external view returns (uint64) {
        return IValidatorRegistry(registry).getProposal(requestId).validatorId;
    }
}
