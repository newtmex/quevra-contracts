// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IVeValidator {
    struct ValidatorSubmission {
        bytes payload;
        bytes signedSecpMessage;
        bytes signedBlsMessage;
        address operator;
        bool existing;
        uint64 validatorId;
    }

    function validatorSubmission(uint256 tokenId) external view returns (ValidatorSubmission memory);
    function setValidatorIdFromController(uint256 tokenId, uint64 validatorId) external;
}
