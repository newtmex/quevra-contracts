// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IMonadStaking} from "../src/interfaces/IMonadStaking.sol";
import {ProtocolTimeLibrary} from "../src/libraries/ProtocolTimeLibrary.sol";

contract ProtocolTimeLibraryTest is Test {
    address internal constant MONAD_VM = 0xc0FFeeCD43A10e1C2b0De63c6CDCFe5B7d0e0CEA;

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

    function _setEpoch(uint64 epoch, bool inDelayPeriod) internal {
        (bool ok,) = MONAD_VM.call(abi.encodeWithSignature("setEpoch(uint64,bool)", epoch, inDelayPeriod));
        require(ok, "setEpoch");
    }
}
