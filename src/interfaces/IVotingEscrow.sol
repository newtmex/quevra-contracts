// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IVotingEscrow {
    struct LockedBalance {
        int128 amount;
        uint256 end;
        bool isPermanent;
        uint256 boost;
    }
}
