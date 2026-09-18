# @quevra/contracts

Foundry package for Quevra protocol contracts on Monad.

`ValidatorRegistry` stores validator registration requests. Operators submit consensus keys and the signatures they generated for a Monad `addValidator` payload. A supported executor later calls `addValidator`, paying the stake and supplying the commission; the registry reconstructs the payload from the request, the executor address, `msg.value`, and the supplied commission before forwarding the stored signatures to the staking precompile at `0x1000`.

`StakingVault` binds one owner-controlled vault to one registry request. The vault can add that validator once, then delegate additional MON to the validator through the staking precompile.

Vault access control and reentrancy protection come from OpenZeppelin Contracts v5:

- `Ownable2Step` for two-step ownership transfer (`transferOwnership` then `acceptOwnership`)
- `ReentrancyGuardTransient` on vault staking actions (EIP-1153, Cancun)

The staking precompile interface is the official Monad `IMonadStaking` ABI.

## Usage

```shell
forge build
forge test
forge fmt
anvil --network monad
forge script script/DeployValidatorRegistry.s.sol:DeployValidatorRegistry --account monad-deployer --broadcast
```

## Solonet e2e

`script/e2e` deploys `ValidatorRegistry` on a running [Solonet](../../services/solonet), requests freshly generated consensus keys, calls `addValidator` through the registry, and checks the staking precompile at `0x1000`.

Solonet must already be up (RPC at `http://localhost:8080`, docker container named `solonet`). On Apple Silicon, Colima needs QEMU with `--cpu-type max` so the VM exposes `pdpe1gb` (1GB hugepages):

```shell
pnpm --filter @quevra/contracts test:e2e
```

# Quevra contracts

## Validator stack creation

`ValidatorVoter.createValidator` makes a normal registry call. The voter is
the registry operator; the human caller is recorded in the voter's deployment
index and owns the deployed `StakingVault` and `ValidatorGauge`.

The creation path is atomic: a failed request or later deployment failure
reverts the request and both deployments. The unchanged vault can subsequently
execute its bound request directly through the registry and delegate MON to the
resulting validator.

Assumptions and deferred integration points:

- Validator key lengths follow Monad's compressed secp256k1 (33-byte) and BLS
  (48-byte) formats. Signature bytes are passed through for the staking
  precompile to verify.
- `ValidatorGauge` is deliberately metadata-only for now. Voting, reward
  distribution, capital allocation, and vault rebalancing are deferred.
- The human caller remains the vault owner and uses the unchanged vault entry
  point to execute its one-time validator-add operation afterward.
- `ValidatorRegistry` owns all request state. `ValidatorVoter` stores only the
  request-to-vault/gauge/operator index needed for cancellation.
- The registry's direct request and `addValidator` entry points remain for
  compatibility with existing integrations. They do not create a vault or
  gauge; new integrations should use `ValidatorVoter`.
- The registry sees `ValidatorVoter` as the operator, so the human caller must
  cancel through `ValidatorVoter.cancel`; direct registry cancellation by the
  human caller fails authorization.
- Cancellation is logical retirement only: it removes the registry key
  reservations and voter index. Deployed vault/gauge bytecode cannot be
  destroyed in a later transaction on Cancun/EIP-6780 EVMs.
