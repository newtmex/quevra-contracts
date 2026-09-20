// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";
import {ProtocolTimeLibrary} from "../src/libraries/ProtocolTimeLibrary.sol";
import {stdError} from "forge-std/StdError.sol";
import {ProtocolTimeLibraryFixture} from "./fixtures/ProtocolTimeLibraryFixture.sol";

contract ProtocolTimeLibraryTest is ProtocolTimeLibraryFixture {
    function test_effectiveEpochAtGenesisAndCycleRollover() public pure {
        assertEq(ProtocolTimeLibrary.effectiveEpoch(0, false), 1);
        assertEq(ProtocolTimeLibrary.effectiveEpoch(0, true), 2);
        assertEq(ProtocolTimeLibrary.effectiveEpoch(3, false), 4);
        assertEq(ProtocolTimeLibrary.effectiveEpoch(3, true), 5);
        assertEq(ProtocolTimeLibrary.effectiveEpoch(4, false), 5);
        assertEq(ProtocolTimeLibrary.effectiveEpoch(4, true), 6);
    }

    function testFuzz_effectiveEpochDelayAddsOneEpoch(uint64 epoch) public pure {
        epoch = uint64(bound(epoch, 0, type(uint64).max - 2));
        uint64 beforeDelay = ProtocolTimeLibrary.effectiveEpoch(epoch, false);
        uint64 duringDelay = ProtocolTimeLibrary.effectiveEpoch(epoch, true);

        assertEq(uint256(beforeDelay) - epoch, 1);
        assertEq(uint256(duringDelay) - epoch, 2);
        assertEq(duringDelay - beforeDelay, 1);
    }

    function test_effectiveEpochAtUint64Limit() public pure {
        assertEq(ProtocolTimeLibrary.effectiveEpoch(type(uint64).max - 1, false), type(uint64).max);
        assertEq(ProtocolTimeLibrary.effectiveEpoch(type(uint64).max - 2, true), type(uint64).max);
    }

    function test_effectiveEpochRevertsOnOverflow() public {
        vm.expectRevert(stdError.arithmeticError);
        timeHarness.effectiveEpoch(type(uint64).max, false);
        vm.expectRevert(stdError.arithmeticError);
        timeHarness.effectiveEpoch(type(uint64).max - 1, true);
        vm.expectRevert(stdError.arithmeticError);
        timeHarness.effectiveEpoch(type(uint64).max, true);
    }

    function test_currentEffectiveEpochTracksDelayAndEpochProgression() public {
        _setEpoch(3, false);
        assertEq(ProtocolTimeLibrary.currentEffectiveEpoch(), 4);
        _setEpoch(3, true);
        assertEq(ProtocolTimeLibrary.currentEffectiveEpoch(), 5);
        _setEpoch(4, false);
        assertEq(ProtocolTimeLibrary.currentEffectiveEpoch(), 5);
        _setEpoch(4, true);
        assertEq(ProtocolTimeLibrary.currentEffectiveEpoch(), 6);
        _setEpoch(5, false);
        assertEq(ProtocolTimeLibrary.currentEffectiveEpoch(), 6);
    }

    function testFuzz_currentEffectiveEpochReadsStakingState(uint64 epoch, bool inDelayPeriod) public {
        epoch = uint64(bound(epoch, 0, type(uint64).max - 2));
        _setEpoch(epoch, inDelayPeriod);
        assertEq(uint256(ProtocolTimeLibrary.currentEffectiveEpoch()) - epoch, inDelayPeriod ? 2 : 1);
    }

    function test_currentEffectiveEpochRevertsOnOverflow() public {
        _setEpoch(type(uint64).max, false);
        vm.expectRevert(stdError.arithmeticError);
        timeHarness.currentEffectiveEpoch();
        _setEpoch(type(uint64).max - 1, true);
        vm.expectRevert(stdError.arithmeticError);
        timeHarness.currentEffectiveEpoch();
    }

    function test_currentCycleStartChangesOnlyAtCycleBoundary() public {
        assertEq(ProtocolTimeLibrary.currentCycleStart(), 0);
        for (uint64 epoch = 10; epoch < 15; ++epoch) {
            _setEpoch(epoch, false);
            assertEq(ProtocolTimeLibrary.currentCycleStart(), 10);
            _setEpoch(epoch, true);
            assertEq(ProtocolTimeLibrary.currentCycleStart(), 10);
        }
        _setEpoch(15, false);
        assertEq(ProtocolTimeLibrary.currentCycleStart(), 15);
        _setEpoch(15, true);
        assertEq(ProtocolTimeLibrary.currentCycleStart(), 15);
    }

    function testFuzz_currentCycleStartContainsCurrentEpoch(uint64 epoch, bool inDelayPeriod) public {
        _setEpoch(epoch, inDelayPeriod);
        uint64 start = ProtocolTimeLibrary.currentCycleStart();
        assertEq(start % ProtocolTimeLibrary.EPOCHS_PER_CYCLE, 0);
        assertLe(start, epoch);
        assertLt(epoch - start, ProtocolTimeLibrary.EPOCHS_PER_CYCLE);
    }

    function test_cycleIsFiveMonadEpochs() public pure {
        assertEq(ProtocolTimeLibrary.EPOCHS_PER_CYCLE, 5);
        assertEq(ProtocolTimeLibrary.cycleOf(0), 0);
        assertEq(ProtocolTimeLibrary.cycleStart(0), 0);
        assertEq(ProtocolTimeLibrary.cycleNext(0), 5);
        assertEq(ProtocolTimeLibrary.cycleStart(4), 0);
        assertEq(ProtocolTimeLibrary.cycleOf(5), 1);
        assertEq(ProtocolTimeLibrary.cycleStart(5), 5);
        assertEq(ProtocolTimeLibrary.cycleNext(9), 10);
        assertEq(ProtocolTimeLibrary.cycleOf(14), 2);
        assertEq(ProtocolTimeLibrary.cycleStart(14), 10);
        assertEq(ProtocolTimeLibrary.cycleNext(14), 15);
    }

    function test_voteWindowBuffersOneMonadEpoch() public pure {
        // Cycle covering Monad epochs [10, 15): vote [11, 14).
        assertEq(ProtocolTimeLibrary.VOTE_BUFFER_EPOCHS, 1);
        assertEq(ProtocolTimeLibrary.cycleVoteStart(12), 11);
        assertEq(ProtocolTimeLibrary.cycleVoteEnd(12), 14);
        assertEq(ProtocolTimeLibrary.cycleVoteStart(10), 11);
        assertEq(ProtocolTimeLibrary.cycleVoteEnd(14), 14);
    }

    function testFuzz_cycleBounds(uint64 epoch) public pure {
        epoch = uint64(bound(epoch, 0, type(uint64).max - ProtocolTimeLibrary.EPOCHS_PER_CYCLE));
        uint64 start = ProtocolTimeLibrary.cycleStart(epoch);
        uint64 next = ProtocolTimeLibrary.cycleNext(epoch);

        assertEq(start % ProtocolTimeLibrary.EPOCHS_PER_CYCLE, 0);
        assertEq(next, start + ProtocolTimeLibrary.EPOCHS_PER_CYCLE);
        assertEq(ProtocolTimeLibrary.cycleOf(epoch) * ProtocolTimeLibrary.EPOCHS_PER_CYCLE, start);
        assertLe(start, epoch);
        assertGt(next, epoch);
        assertLt(epoch - start, ProtocolTimeLibrary.EPOCHS_PER_CYCLE);
    }

    function test_currentEpochMatchesStakingPrecompile() public {
        IMonadStaking staking = IMonadStaking(ProtocolTimeLibrary.STAKING_PRECOMPILE);
        (uint64 expectedEpoch, bool expectedDelay) = staking.getEpoch();
        (uint64 epoch, bool delay) = ProtocolTimeLibrary.currentEpoch();
        assertEq(epoch, expectedEpoch);
        assertEq(delay, expectedDelay);
        assertEq(ProtocolTimeLibrary.currentCycle(), ProtocolTimeLibrary.cycleOf(expectedEpoch));
    }

    function test_currentCycleTracksSetEpoch() public {
        _setEpoch(12, false);
        (uint64 epoch, bool delay) = ProtocolTimeLibrary.currentEpoch();
        assertEq(epoch, 12);
        assertFalse(delay);
        assertEq(ProtocolTimeLibrary.currentCycle(), 2);
        assertEq(ProtocolTimeLibrary.cycleStart(epoch), 10);
        assertEq(ProtocolTimeLibrary.cycleNext(epoch), 15);

        _setEpoch(15, true);
        (epoch, delay) = ProtocolTimeLibrary.currentEpoch();
        assertEq(epoch, 15);
        assertTrue(delay);
        assertEq(ProtocolTimeLibrary.currentCycle(), 3);
        assertEq(ProtocolTimeLibrary.cycleStart(epoch), 15);
    }
}
