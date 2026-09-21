# @quevra/contracts

Foundry package for Quevra protocol contracts on Monad.

`ValidatorRegistry` stores validator registration requests as an opaque, complete 165-byte Monad `addValidator` payload and its two signatures. The payload is forwarded unchanged to the staking precompile at `0x1000`; contracts do not store public keys separately or index them. `addValidator` forwards the signed payload and `msg.value` without interpreting or changing either.

`StakingVault` binds one owner-controlled vault to one registry request. The vault can add that validator once, then delegate additional MON to the validator through the staking precompile.

Vault access control and reentrancy protection come from OpenZeppelin Contracts v5:

- `Ownable2Step` for two-step ownership transfer (`transferOwnership` then `acceptOwnership`)
- `ReentrancyGuardTransient` on vault staking actions (EIP-1153, Cancun)

The staking precompile interface is the official Monad `IMonadStaking` ABI.

`StakingController` exposes `signingConfig` after vault creation and
`signingConfigFor(requester, saltSeed)` before submission. The caller can use
the resulting auth address, configured commission, and fixed
`VALIDATOR_STAKE_AMOUNT` to construct and sign the complete payload.
The constructor sets the initial commission immediately. Later owner updates
through `setCommission` take effect at the start of cycle + 2. The stake amount
is a contract constant. Commission uses 1e18 scaling and is capped at
`MAX_COMMISSION` (100%), matching the staking precompile.

## Usage

```shell
forge build
forge test
forge fmt
anvil --network monad
```

## Solonet e2e

`script/e2e` deploys `ValidatorRegistry` on a running [Solonet](../../services/solonet), requests freshly generated consensus keys, calls `addValidator` through the registry, and checks the staking precompile at `0x1000`.

Solonet must already be up (RPC at `http://localhost:8080`, docker container named `solonet`). On Apple Silicon, Colima needs QEMU with `--cpu-type max` so the VM exposes `pdpe1gb` (1GB hugepages):

```shell
pnpm --filter @quevra/contracts test:e2e
```
