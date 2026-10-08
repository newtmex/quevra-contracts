// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVeValidator} from "../../src/interfaces/IVeValidator.sol";
import {IStakingController} from "../../src/interfaces/IStakingController.sol";
import {BaseTest} from "./BaseTest.sol";

contract TestValidatorVe is IVeValidator {
    uint256 public nextTokenId = 1;
    mapping(uint256 tokenId => ValidatorSubmission) private _submissions;

    function registerNew(address operator, bytes calldata payload, bytes calldata secp, bytes calldata bls)
        external
        returns (uint256 tokenId)
    {
        tokenId = nextTokenId++;
        _submissions[tokenId] = ValidatorSubmission(payload, secp, bls, operator, false, 0);
    }

    function registerExisting(address operator, uint64 validatorId) external returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        _submissions[tokenId] = ValidatorSubmission("", "", "", operator, true, validatorId);
    }

    function validatorSubmission(uint256 tokenId) external view override returns (ValidatorSubmission memory) {
        return _submissions[tokenId];
    }

    function setValidatorIdFromController(uint256, uint64) external pure override {}

    function deploy(
        IStakingController controller,
        address operator,
        uint256 tokenId,
        bytes32 saltSeed,
        address expectedAuthAddress
    ) external returns (address vault) {
        vault = controller.deployValidatorVault(operator, tokenId, saltSeed, expectedAuthAddress);
    }
}

abstract contract VeValidatorFixture is BaseTest {
    TestValidatorVe internal validatorVe;
    uint256 internal tokenId;

    function setUp() public virtual override {
        super.setUp();
        validatorVe = new TestValidatorVe();
    }

    function _requestValidator() internal returns (uint256 id) {
        id = validatorVe.registerNew(operator, validatorPayload, secpSig, blsSig);
    }

    function _requestBoundValidator() internal returns (uint256 id) {
        id = _requestValidator();
        tokenId = id;
    }
}
