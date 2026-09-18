// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IMonadStaking} from "../src/interfaces/IMonadStaking.sol";
import {ProtocolTimeLibrary} from "../src/libraries/ProtocolTimeLibrary.sol";

contract ProtocolTimeLibraryTest is Test {
    address internal constant MONAD_VM = 0xc0FFeeCD43A10e1C2b0De63c6CDCFe5B7d0e0CEA;

    function test_cycleIsFortyMonadEpochs() public pure {
        assertEq(ProtocolTimeLibrary.EPOCHS_PER_CYCLE, 40);
        assertEq(ProtocolTimeLibrary.cycleDuration(), 40);
        assertEq(ProtocolTimeLibrary.cycleOf(0), 0);
        assertEq(ProtocolTimeLibrary.cycleStart(0), 0);
        assertEq(ProtocolTimeLibrary.cycleNext(0), 40);
        assertEq(ProtocolTimeLibrary.cycleStart(39), 0);
        assertEq(ProtocolTimeLibrary.cycleOf(40), 1);
        assertEq(ProtocolTimeLibrary.cycleStart(40), 40);
        assertEq(ProtocolTimeLibrary.cycleNext(79), 80);
        assertEq(ProtocolTimeLibrary.cycleOf(94), 2);
        assertEq(ProtocolTimeLibrary.cycleStart(94), 80);
        assertEq(ProtocolTimeLibrary.cycleNext(94), 120);
    }

    function test_voteWindowBuffersOneMonadEpoch() public pure {
        // Cycle covering Monad epochs [40, 80): vote [41, 79).
        assertEq(ProtocolTimeLibrary.VOTE_BUFFER_EPOCHS, 1);
        assertEq(ProtocolTimeLibrary.cycleVoteStart(52), 41);
        assertEq(ProtocolTimeLibrary.cycleVoteEnd(52), 79);
        assertEq(ProtocolTimeLibrary.cycleVoteStart(40), 41);
        assertEq(ProtocolTimeLibrary.cycleVoteEnd(79), 79);
        assertTrue(ProtocolTimeLibrary.inDistributeWindow(40));
        assertFalse(ProtocolTimeLibrary.inDistributeWindow(41));
        assertTrue(ProtocolTimeLibrary.inWhitelistWindow(79));
        assertFalse(ProtocolTimeLibrary.inWhitelistWindow(78));
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
        _setEpoch(52, false);
        (uint64 epoch, bool delay) = ProtocolTimeLibrary.currentEpoch();
        assertEq(epoch, 52);
        assertFalse(delay);
        assertEq(ProtocolTimeLibrary.currentCycle(), 1);
        assertEq(ProtocolTimeLibrary.cycleStart(epoch), 40);
        assertEq(ProtocolTimeLibrary.cycleNext(epoch), 80);

        _setEpoch(80, true);
        (epoch, delay) = ProtocolTimeLibrary.currentEpoch();
        assertEq(epoch, 80);
        assertTrue(delay);
        assertEq(ProtocolTimeLibrary.currentCycle(), 2);
        assertEq(ProtocolTimeLibrary.cycleStart(epoch), 80);
    }

    function _setEpoch(uint64 epoch, bool inDelayPeriod) internal {
        (bool ok,) = MONAD_VM.call(abi.encodeWithSignature("setEpoch(uint64,bool)", epoch, inDelayPeriod));
        require(ok, "setEpoch");
    }
}
