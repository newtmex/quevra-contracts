// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProtocolTimeLibrary} from "../../src/libraries/ProtocolTimeLibrary.sol";
import {BaseTest} from "./BaseTest.sol";

contract ProtocolTimeLibraryHarness {
    function effectiveEpoch(uint64 epoch, bool inDelayPeriod) external pure returns (uint64) {
        return ProtocolTimeLibrary.effectiveEpoch(epoch, inDelayPeriod);
    }

    function currentEffectiveEpoch() external returns (uint64) {
        return ProtocolTimeLibrary.currentEffectiveEpoch();
    }
}

abstract contract ProtocolTimeLibraryFixture is BaseTest {
    ProtocolTimeLibraryHarness internal timeHarness;

    function setUp() public virtual override {
        super.setUp();
        timeHarness = new ProtocolTimeLibraryHarness();
    }
}
