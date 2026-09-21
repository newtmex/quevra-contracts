// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IReward} from "../../src/interfaces/IReward.sol";
import {BribeVotingReward} from "../../src/rewards/BribeVotingReward.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {VeMON} from "../../src/VeMON.sol";
import {StakingController} from "../../src/staking/StakingController.sol";
import {ValidatorRegistry} from "../../src/validators/ValidatorRegistry.sol";
import {ValidatorsVoter} from "../../src/ValidatorsVoter.sol";
import {FactoryRegistry} from "../../src/factories/FactoryRegistry.sol";
import {GaugeFactory} from "../../src/factories/GaugeFactory.sol";
import {VotingRewardsFactory} from "../../src/factories/VotingRewardsFactory.sol";
import {BaseTest} from "./BaseTest.sol";

contract RewardTestToken is ERC20 {
    constructor() ERC20("Reward token", "RWD") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

abstract contract RewardFixture is BaseTest {
    BribeVotingReward internal reward;
    ValidatorRegistry internal registry;
    StakingController internal controller;
    VeMON internal veMON;
    ValidatorsVoter internal rewardVoter;
    FactoryRegistry internal factoryRegistry;
    GaugeFactory internal gaugeFactory;
    VotingRewardsFactory internal rewardsFactory;
    address internal bribe;
    RewardTestToken internal rewardToken;
    RewardTestToken internal otherToken;
    address internal forwarder = makeAddr("forwarder");

    function setUp() public virtual override {
        super.setUp();
        registry = new ValidatorRegistry();
        controller = new StakingController(address(registry), address(this), 0);
        veMON = new VeMON(address(controller), 4);
        rewardToken = new RewardTestToken();
        otherToken = new RewardTestToken();
        factoryRegistry = new FactoryRegistry();
        gaugeFactory = new GaugeFactory();
        rewardsFactory = new VotingRewardsFactory();
        factoryRegistry.approveGaugeFactory(address(gaugeFactory), address(rewardsFactory));
        address implementation = address(new ValidatorsVoter(forwarder));
        bytes memory init = abi.encodeCall(
            ValidatorsVoter.initialize,
            (
                address(veMON),
                address(factoryRegistry),
                address(0),
                address(registry),
                address(controller),
                address(gaugeFactory)
            )
        );
        rewardVoter = ValidatorsVoter(address(new ERC1967Proxy(implementation, init)));
        controller.setVoter(address(rewardVoter));
        // Deploy a real validator gauge/bribe so Reward's voter and ve relationships
        // are established through the same factory and voter contracts as production.
        bytes memory secp = hex"0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
        bytes memory bls =
            hex"97f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb";
        bytes32 saltSeed = keccak256("reward-validator");
        address auth = controller.predictVaultAddress(operator, saltSeed);
        bytes memory payload =
            bytes.concat(secp, bls, bytes20(auth), bytes32(uint256(100_000 ether)), bytes32(uint256(0)));
        vm.prank(operator);
        (,, address gauge) =
            rewardVoter.createValidator(saltSeed, auth, payload, hex"11", bytes.concat(bytes1(0x80), new bytes(95)));
        bribe = rewardVoter.gaugeToBribe(gauge);
        reward = BribeVotingReward(bribe);
        rewardToken.approve(address(reward), type(uint256).max);
        otherToken.approve(address(reward), type(uint256).max);
    }

    function _rewardTokens() internal view returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = address(rewardToken);
    }

    function _vote(uint256 amount) internal returns (uint256 tokenId) {
        vm.prank(operator);
        tokenId = veMON.createLock{value: amount}(amount, lockDuration);
        vm.prank(operator);
        veMON.lockPermanent(tokenId);
        address[] memory gauges = new address[](1);
        gauges[0] = rewardVoter.validatorToGauge(1);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;
        vm.prank(operator);
        rewardVoter.vote(tokenId, gauges, weights);
    }

    function _whitelistRewardTokens() internal {
        rewardVoter.whitelistToken(address(rewardToken), true);
        rewardVoter.whitelistToken(address(otherToken), true);
    }

    function _notify(address token, uint256 amount) internal {
        reward.notifyRewardAmount(token, amount);
    }
}
