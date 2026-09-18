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
the registry operator; the `StakingController` owns the deployed
`StakingVault`, while the human caller is recorded as that validator's pool
operator.

The creation path is atomic: a failed request or later deployment failure
reverts the request and both deployments. The owner configures the exact
commission and amount used by the requester's signed messages. Users deposit
MON by creating veMON locks; veMON forwards the value to the controller. The
controller receive path only accepts value from veMON and custodies it for a
later admin-controlled staking flow.

Assumptions and deferred integration points:

- Before submitting, call
  `controller.signingConfigFor(requester, secpPubkey, blsPubkey)` to obtain
  `(authAddress, commission, amount)`. Sign the packed payload
  `secpPubkey || blsPubkey || authAddress || uint256(amount) || uint256(commission)`
  using the consensus keys. Submit via
  `voter.createValidator(authAddress, secpPubkey, blsPubkey, secpSignature, blsSignature)`
  from that same requester address. The controller uses OpenZeppelin
  `Clones.cloneDeterministic`; the salt binds requester, nonce, and both keys.
  The per-requester nonce is private and managed internally; it increments only
  on successful creation. Requesters only supply the expected authAddress. Registry
  request IDs and signatures do not affect the predicted clone address.
- The voter requests the validator and creates the gauge using the expected
  vault address. A single controller call then deploys and initializes the clone
  with the returned request ID and registers the complete vault/gauge pair.
  Every step is atomic: failure restores nonce, registry, vault and deployment state.
  Other requesters and direct registry requests cannot consume your nonce.
- Each controller deploys a fixed vault implementation in its constructor.
  The implementation has a no-argument constructor and disables initialization.
  Its immutable initializer authority is the deploying controller. Clones store
  their registry, staking precompile, request ID, and owner during a one-time
  controller-only initializer. Ownership is initialized explicitly with the
  existing OpenZeppelin Ownable2Step base. Clones have no upgrade mechanism.
  Deployment scripts need no separate implementation deployment.
- Cancellation never resets the nonce. Resubmission requires signing the new
  predicted address. A stale or incorrect expected address reverts with
  `UnexpectedAuthAddress` in the controller, rolling back the request and gauge.
- Global economics are read at execution time. Owner configuration changes
  can invalidate pending signatures; coordinate changes with requesters, who
  must cancel and resubmit with fresh signatures when their payload changes.
  The post-request `signingConfig(requestId)` helper remains available.

- Validator key lengths follow Monad's compressed secp256k1 (33-byte) and BLS
  (48-byte) formats. Signature bytes are passed through for the staking
  precompile to verify.
- `ValidatorGauge` is deliberately metadata-only for now. Voting, reward
  distribution, capital allocation, and vault rebalancing are deferred.
- The controller remains the vault owner. Users do not call vaults directly;
  they create veMON locks, and veMON forwards MON to the controller for custody.
- `ValidatorRegistry` owns all request state. `ValidatorVoter` stores only the
  request-to-vault/gauge/operator index needed for cancellation.
- `StakingController` is `Ownable2Step`, owns every vault, and lets its owner
  bind the voter exactly once. Its owner-managed global validator configuration
  is exposed through its distinct signing-config helpers, which return the vault auth
  address, commission, and exact amount expected by `addValidator` signatures.
- `StakingController.receive` accepts value only from veMON. It does not select
  a vault or call validator staking yet; that admin-controlled flow is deferred.
- The registry's direct request and `addValidator` entry points remain for
  compatibility with existing integrations. They do not create a vault or
  gauge; new integrations should use `ValidatorVoter`.
- The registry sees `ValidatorVoter` as the operator, so the human caller must
  cancel through `ValidatorVoter.cancel`; direct registry cancellation by the
  human caller fails authorization.
- Cancellation is available only before any weight is routed. It clears the
  controller pool and registry key reservations, preserving global configuration; deployed
  vault/gauge bytecode is not destroyed because Cancun/EIP-6780 contracts
  cannot generally be removed in a later transaction.
