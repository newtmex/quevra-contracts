// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Reward} from "../../rewards/Reward.sol";
import {BaseTest} from "./BaseTest.sol";

contract RewardVoterStub {
    address public immutable ve;

    constructor(address ve_) {
        ve = ve_;
    }
}

contract RewardTestToken is ERC20 {
    constructor() ERC20("Reward token", "RWD") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

// Expose the base hooks without adding a concrete reward contract's policies.
contract RewardHarness is Reward {
    constructor(address forwarder_, address voter_, address authorized_) Reward(forwarder_, voter_) {
        authorized = authorized_;
    }

    function getReward(uint256 tokenId, address[] memory tokens) external override nonReentrant {
        _getReward(_msgSender(), tokenId, tokens);
    }

    function notifyRewardAmount(address token, uint256 amount) external override nonReentrant {
        _notifyRewardAmount(_msgSender(), token, amount);
    }
}

abstract contract RewardFixture is BaseTest {
    RewardHarness internal reward;
    RewardVoterStub internal rewardVoter;
    RewardTestToken internal rewardToken;
    RewardTestToken internal otherToken;
    address internal forwarder = makeAddr("forwarder");
    address internal escrow = makeAddr("escrow");

    function setUp() public virtual override {
        super.setUp();
        rewardVoter = new RewardVoterStub(escrow);
        reward = new RewardHarness(forwarder, address(rewardVoter), address(this));
        rewardToken = new RewardTestToken();
        otherToken = new RewardTestToken();
        rewardToken.approve(address(reward), type(uint256).max);
        otherToken.approve(address(reward), type(uint256).max);
    }

    function _rewardTokens() internal view returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = address(rewardToken);
    }
}
