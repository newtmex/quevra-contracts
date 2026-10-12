// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BribeVotingRewards} from "../../src/rewards/BribeVotingRewards.sol";
import {NonStakingGauge} from "../../src/gauges/NonStakingGauge.sol";
import {StakingAgent} from "../../src/staking/controlled/StakingAgent.sol";
import {StakingController} from "../../src/staking/StakingController.sol";
import {StakingVault} from "../../src/staking/controlled/StakingVault.sol";
import {ValidatorsVoter} from "../../src/voting/ValidatorsVoter.sol";
import {VeMON} from "../../src/VeMON.sol";
import {VeValidator} from "../../src/VeValidator.sol";
import {BaseTest} from "./BaseTest.sol";

/// @dev Full Quevra stack used by cross-contract integration tests: controller,
///      veMON, veValidator, voter, gauges, and bribe reward beacons.
abstract contract QuevraProtocolFixture is BaseTest {
    StakingController internal controller;
    VeMON internal veMON;
    VeValidator internal veValidator;
    ValidatorsVoter internal validatorsVoter;
    ERC20Mock internal gaugeRewardToken;
    address internal sponsor = makeAddr("sponsor");

    function setUp() public virtual override {
        super.setUp();
        vm.deal(sponsor, 1_000_000 ether);

        StakingVault vaultImplementation = new StakingVault();
        StakingAgent agentImplementation = new StakingAgent();
        UpgradeableBeacon vaultBeacon = new UpgradeableBeacon(address(vaultImplementation), address(this));
        UpgradeableBeacon agentBeacon = new UpgradeableBeacon(address(agentImplementation), address(this));
        StakingController controllerImplementation = new StakingController();
        controller = StakingController(
            payable(address(
                    new ERC1967Proxy(
                        address(controllerImplementation),
                        abi.encodeCall(
                            StakingController.initialize, (address(this), 0, address(vaultBeacon), address(agentBeacon))
                        )
                    )
                ))
        );

        VeMON veMONImplementation = new VeMON();
        veMON = VeMON(
            address(
                new ERC1967Proxy(
                    address(veMONImplementation),
                    abi.encodeCall(VeMON.initialize, (address(controller), 4, address(this)))
                )
            )
        );
        controller.setVe(address(veMON));

        NonStakingGauge gaugeImplementation = new NonStakingGauge();
        BribeVotingRewards bribeImplementation = new BribeVotingRewards();
        UpgradeableBeacon gaugeBeacon = new UpgradeableBeacon(address(gaugeImplementation), address(this));
        UpgradeableBeacon bribeBeacon = new UpgradeableBeacon(address(bribeImplementation), address(this));
        ValidatorsVoter voterImplementation = new ValidatorsVoter();
        validatorsVoter = ValidatorsVoter(
            address(
                new ERC1967Proxy(
                    address(voterImplementation),
                    abi.encodeCall(
                        ValidatorsVoter.initialize,
                        (address(veMON), address(0), address(this), address(gaugeBeacon), address(bribeBeacon))
                    )
                )
            )
        );

        gaugeRewardToken = new ERC20Mock();
        VeValidator implementation = new VeValidator();
        veValidator = VeValidator(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        VeValidator.initialize,
                        (address(controller), address(validatorsVoter), address(gaugeRewardToken), 4, address(this))
                    )
                )
            )
        );
        validatorsVoter.setBoostableVe(address(veValidator));
        validatorsVoter.whitelistToken(address(gaugeRewardToken), true);
        controller.setValidatorVe(address(veValidator));
    }

    function _createValidator(bytes32 saltSeed) internal returns (uint256 tokenId) {
        address expectedAuthAddress = controller.predictVaultAddress(operator, saltSeed);
        vm.prank(operator);
        tokenId =
            veValidator.createValidator(saltSeed, expectedAuthAddress, _payload(expectedAuthAddress), secpSig, blsSig);
    }

    function _createValidatorWithKey(bytes32 saltSeed, uint8 keyNumber) internal returns (uint256 tokenId) {
        address expectedAuthAddress = controller.predictVaultAddress(operator, saltSeed);
        vm.prank(operator);
        tokenId = veValidator.createValidator(
            saltSeed, expectedAuthAddress, _payloadWithKey(expectedAuthAddress, keyNumber), secpSig, blsSig
        );
    }

    function _payload(address authAddress) internal view returns (bytes memory) {
        return bytes.concat(
            secpPubkey, blsPubkey, bytes20(authAddress), bytes32(uint256(100_000 ether)), bytes32(uint256(1e17))
        );
    }

    function _payloadWithKey(address authAddress, uint8 keyNumber) internal view returns (bytes memory) {
        bytes memory uniqueSecpPubkey = hex"02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5";
        bytes memory uniqueBlsPubkey =
            hex"a572cbea904d67468808c8eb50a9450c9721db309128012543902d0ac358a62ae28f75bb8f1c7c42c39a8c5529bf0f4e";
        if (keyNumber == 1) return _payload(authAddress);
        return bytes.concat(
            uniqueSecpPubkey,
            uniqueBlsPubkey,
            bytes20(authAddress),
            bytes32(uint256(100_000 ether)),
            bytes32(uint256(1e17))
        );
    }

    function _one(address value) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }

    function _oneAmount(uint256 value) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }

    function _oneToken(address token) internal pure returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = token;
    }

    function _setEpochAfterLockExpiry(uint256 tokenId, uint64 withdrawalEpoch) internal {
        (, uint256 lockEnd,,) = veMON.locked(tokenId);
        uint64 targetEpoch = withdrawalEpoch + 1;
        if (lockEnd > targetEpoch) targetEpoch = uint64(lockEnd);
        _setEpoch(targetEpoch, false);
    }
}
