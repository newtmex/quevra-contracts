# @quevra/contracts

Foundry package for Quevra protocol contracts on Monad.

`ValidatorRegistry` stores validator registration requests. Operators submit consensus keys and the signatures they generated for a Monad `addValidator` payload. A supported executor later calls `addValidator`, paying the stake and supplying the commission; the registry reconstructs the payload from the request, the executor address, `msg.value`, and the supplied commission before forwarding the stored signatures to the staking precompile at `0x1000`.

`StakingVault` binds one owner-controlled vault to one registry request. The vault can add that validator once, then delegate additional MON to the validator through the staking precompile.

Vault access control and reentrancy protection come from OpenZeppelin Contracts v5:

- `Ownable2Step` for two-step ownership transfer (`transferOwnership` then `acceptOwnership`)
- `ReentrancyGuardTransient` on vault staking actions (EIP-1153, Cancun)

The staking precompile interface is the official Monad `IMonadStaking` ABI.

`StakingController` exposes `signingConfig` and `signingConfigFor` for the
auth address, commission, and fixed `VALIDATOR_STAKE_AMOUNT` used in validator
registration signatures. The owner configures commission with `setCommission`;
the stake amount is a contract constant. Commission uses 1e18 scaling and is
capped at `MAX_COMMISSION` (100%), matching the staking precompile.

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
