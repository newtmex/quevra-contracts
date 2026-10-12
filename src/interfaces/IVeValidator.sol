// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IVeValidator {
    /// @notice Registration payload and operator details associated with a validator position.
    struct ValidatorSubmission {
        bytes payload;
        bytes signedSecpMessage;
        bytes signedBlsMessage;
        address operator;
        bool existing;
        uint64 validatorId;
    }

    /// @notice Returns the original registration submission for a validator token.
    function validatorSubmission(uint256 tokenId) external view returns (ValidatorSubmission memory);

    /// @notice Returns a validator token's native ID and linked protocol entities.
    function validatorPosition(uint256 tokenId)
        external
        view
        returns (uint64 validatorId, address operator, address vault, address gauge, address bribeVotingRewards);
    /// @notice Records the native validator ID after the controller completes validator registration.
    function setValidatorIdFromController(uint256 tokenId, uint64 validatorId) external;
}
