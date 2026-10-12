# Upgradeable contract architecture

## Proxy choices

`StakingController`, `VeMON`, `VeValidator`, and `ValidatorsVoter` are UUPS implementations behind separate ERC-1967 proxies. Their implementations disable initialization in their constructors; proxy state is set through `initialize`. The implementation `_authorizeUpgrade` hooks are restricted to the current two-step owner.

`StakingVault`, `StakingAgent`, `NonStakingGauge`, and `BribeVotingRewards` are initializer-based Beacon implementations. `StakingController` creates vault and agent `BeaconProxy` instances. `ValidatorsVoter` creates gauge and bribe `BeaconProxy` instances. The beacon address is fixed in the factory's initialized storage. Beacon owners are the configured protocol owner, so changing an implementation affects every instance while preserving instance addresses and storage.

`StakingAdmin`, `VotingEscrow`, `NonStakingVoter`, `StakeControlled`, `Gauge`, `Reward`, and `VotingReward` are initializer-based parents, not independent proxy deployments. Stateless protocol libraries remain ordinary libraries.

## Initialization and authority

The fresh deployment order is:

1. Configure `PROTOCOL_OWNER_ADDRESS` as the direct owner and upgrade authority (prefer a Safe multisig address).
2. Deploy the four Beacon implementations and beacons with that owner.
3. Deploy the UUPS controller, initialized with that owner and the vault/agent beacons.
4. Deploy veMON with the controller address.
5. Deploy the voter with veMON and gauge/bribe beacons.
6. Deploy veValidator with controller, voter, reward token, and lock horizon.
7. Complete the controller's one-time veMON and veValidator bindings, bind the voter's boostable escrow, and whitelist the configured gauge reward token.
8. Check all cross-contract references and verify the configured owner on each core proxy and beacon.

There is no protocol Timelock or automated governance proposal/scheduling flow. The configured owner has immediate UUPS and Beacon upgrade authority. Use a Safe as the owner address when multisignature authorization is required. UUPS proxy ownership uses two-step transfer; when the deployment key differs from the configured owner, the latter must call `acceptOwnership()` once per core proxy. Staking settlement and reward claiming retain their permissionless/user authorization rules. No privileged asset rescue or arbitrary delegatecall was added.

## Deterministic validator vaults

The controller's `predictVaultAddress(requester, salt)` and deployment path use the same CREATE2 deployer, salt derivation, `BeaconProxy` creation code, beacon constructor argument, and empty initialization bytes. The proxy is initialized immediately in the same transaction, before the call returns. The predicted address therefore does not depend on the beacon's current implementation. New signed Monad validator registration payloads must use that predicted proxy address as the auth address. The controller records only its own created vaults as valid.

Agents are deterministically deployed from token IDs by the controller and initialized with the controller and token ID. Vaults and agents make native staking calls as their own proxy addresses, which preserves Monad's staking identity semantics.

## Storage and upgrade boundary

The protocol-owned state uses dedicated ERC-7201 namespaces so new protocol fields do not shift unrelated proxy storage. Namespaces are documented beside their structs: `StakingAdmin`, `StakingController`, `VotingEscrow`, `VeValidator`, `NonStakingVoter`, `ValidatorsVoter`, `StakeControlled`, `StakingVault`, `StakingAgent`, `Gauge`, `NonStakingGauge`, and `Reward`. OpenZeppelin upgradeable base contracts keep their own versioned storage layouts. Future namespace changes still require review and the Hardhat upgrade validation gate.

This is a fresh namespaced layout. It does not automatically migrate state from an already deployed implementation that kept these fields in sequential storage. Such a deployment requires an explicit, audited migration before replacing its implementation.

Before a production upgrade, run `upgrade:validate` and `upgrade:prepare` against the exact deployed implementation, apply the owner upgrade, then run `deploy:status` and `deploy:verify` so Sourcify evidence matches the live implementations. Keep append-only storage changes and add an explicit versioned reinitializer for any required migration. Do not use validation bypasses. The checked-in Hardhat upgrade tests cover representative UUPS and Beacon state preservation, but do not yet establish a complete V1-to-V2 economic-state audit for every module.

No same-address migration from previously deployed non-proxy contracts or EIP-1167 clones is performed. Existing deployments require a separately designed migration and asset-transfer procedure. Repository-local broadcast artifacts currently do not constitute evidence of a deployed Quevra protocol.

## EVM and size settings

Foundry and Hardhat use Solidity 0.8.28, Cancun, optimizer runs 200, metadata bytecode hash disabled, and `viaIR`. Monad's runtime code limit is 128 KiB (131,072 bytes), rather than Ethereum's EIP-170 limit of 24,576 bytes; `forge build --sizes` reports the Monad-sized margin. Keep deployment initcode and transaction gas limits in mind as separate constraints. Native Monad staking behavior still requires the Foundry Monad fork or Solonet integration; Hardhat's local EVM does not validate the `0x1000` precompile.

The contracts use OpenZeppelin `ReentrancyGuardTransient`, which relies on Cancun transient storage (`TSTORE`/`TLOAD`). Deploy only to a network that supports this EVM feature. The compiler warning about transient storage composability applies generally; the guard clears its transient slot on function exit.

## Attribution

This migration modified existing Quevra contract sources and added OpenZeppelin dependencies; it did not import or copy Tigris implementation source. Existing Tigris-derived voter/reward sources retain their `BUSL-1.1` or `MIT` SPDX headers and attribution comments. Do not change those headers without a separate source-by-source license review. OpenZeppelin dependencies are pinned to version 5.7.0 and retain their upstream MIT licensing.
