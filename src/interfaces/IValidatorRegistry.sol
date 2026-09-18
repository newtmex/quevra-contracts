// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";

/// @title IValidatorRegistry
/// @notice Registry for validator registration requests and registry-owned delegation.
interface IValidatorRegistry {
    enum Status {
        Proposed,
        Executed,
        Cancelled
    }

    struct Proposal {
        bytes secpPubkey;
        bytes blsPubkey;
        bytes signedSecpMessage;
        bytes signedBlsMessage;

        address operator;
        Status status;

        address executor;
        uint64 validatorId;
    }

    event ValidatorRequested(uint256 indexed id, address indexed operator, bytes secpPubkey, bytes blsPubkey);

    event ValidatorAdded(
        uint256 indexed id,
        address indexed executor,
        uint64 indexed validatorId,
        address authAddress,
        uint256 amount,
        uint256 commission
    );

    event ValidatorRequestCancelled(uint256 indexed id);

    error KeyAlreadyRegistered();
    error UnknownProposal();
    error NotProposed();
    error NotOperator();
    error InvalidValidatorId();

    function staking() external view returns (IMonadStaking);

    function nextId() external view returns (uint256);

    function idBySecpPubkey(bytes32 secpKeyHash) external view returns (uint256 id);

    function idByBlsPubkey(bytes32 blsKeyHash) external view returns (uint256 id);

    function requestValidator(
        bytes calldata secpPubkey,
        bytes calldata blsPubkey,
        bytes calldata signedSecpMessage,
        bytes calldata signedBlsMessage
    ) external returns (uint256 id);

    function addValidator(uint256 id, uint256 commission) external payable returns (uint64 validatorId);

    function cancel(uint256 id) external;

    function getProposal(uint256 id) external view returns (Proposal memory);

    function stakingPayload(uint256 id, address authAddress, uint256 amount, uint256 commission)
        external
        view
        returns (bytes memory);
}
