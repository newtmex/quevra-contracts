// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IValidatorVoter {
    struct ValidatorStack {
        address vault;
        address gauge;
        uint64 validatorId;
        address operator;
    }

    event ValidatorGaugeCreated(
        uint256 indexed requestId, uint64 indexed validatorId, address indexed operator, address vault, address gauge
    );
    event VoteCast(uint256 indexed tokenId, uint256 indexed cycle, address indexed gauge, uint256 weight);
    event VoteReset(uint256 indexed tokenId, uint256 indexed cycle);

    error GaugeExistsForValidator();
    error NotRequestOperator();
    error UnknownStack();

    function createValidator(
        address expectedAuthAddress,
        bytes calldata secpPubkey,
        bytes calldata blsPubkey,
        bytes calldata signedSecpMessage,
        bytes calldata signedBlsMessage
    ) external returns (uint256 requestId, address vault, address gauge);

    function stackByRequest(uint256 requestId) external view returns (ValidatorStack memory);

    function isRewardTokenWhitelisted(address token) external view returns (bool);

    function validatorAccepted(uint256 requestId, uint256 cycle) external view returns (bool);

    function vote(uint256 tokenId, address[] calldata gauges, uint256[] calldata weights) external;
    function reset(uint256 tokenId) external;
    function poke(uint256 tokenId) external;
    function voterWeight(uint256 tokenId, address gauge, uint256 cycle) external view returns (uint256);
    function totalGaugeWeight(address gauge, uint256 cycle) external view returns (uint256);
    function isGaugeAccepted(address gauge, uint256 cycle) external view returns (bool);
    function veMON() external view returns (address);
}
