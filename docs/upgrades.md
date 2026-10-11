# Upgrade workflow

## Validate and prepare

Every UUPS or Beacon implementation must be compiled and validated against the current on-chain target before the owner submits the upgrade transaction. Set the variables for each run:

```dotenv
UPGRADE_KIND=uups                 # or beacon
UPGRADE_TARGET=0x...              # proxy for UUPS; beacon for Beacon
UPGRADE_CONTRACT=VeMON            # new implementation artifact name
UPGRADE_MIGRATION_CALLDATA=0x     # optional encoded reinitializer call
```

Then run:

```bash
pnpm --filter @quevra/contracts upgrade:validate -- --network monadTestnet
pnpm --filter @quevra/contracts upgrade:prepare -- --network monadTestnet
```

These commands use OpenZeppelin's validation and prepare APIs. Preparation deploys only the new implementation and records its address and code hash; it does not change the live proxy or beacon. The prepared record includes exact upgrade calldata for an owner-controlled transaction. Submit it directly from the configured owner (for example, through the Safe UI when the owner is a Safe). No Timelock delay or proposal builder is included.

For a versioned UUPS migration, encode `upgradeToAndCall(newImplementation, migrationCalldata)` and supply only the audited reinitializer calldata. The default is an empty `0x` call. Beacon upgrades use `upgradeTo(newImplementation)` and affect every proxy associated with that Beacon. A Beacon upgrade has no automatic rollback; any later downgrade is a new owner-authorized upgrade requiring compatible storage.

Direct execution is restricted to the local Hardhat chain:

```bash
UPGRADE_KIND=uups UPGRADE_TARGET=0x... UPGRADE_CONTRACT=VeMON \
  pnpm --filter @quevra/contracts upgrade:execute:local -- --network local
```

After execution, rerun `deploy:status`, read the new implementation from the proxy/beacon, verify the intended state and references, and update/retain the upgrade record with transaction hashes. The owner can upgrade immediately; secure that key/address according to the protocol's intended control model.

## Validation coverage and limitations

`@openzeppelin/hardhat-upgrades` validation is the required gate and the tooling does not set `unsafeSkipStorageCheck` or general `unsafeAllow` exceptions. The current checked-in Hardhat tests exercise authorized/unauthorized UUPS upgrades, rejection of a non-UUPS implementation, and a Beacon upgrade across two instances while preserving their independent state. They are representative tests, not a full proof of preservation for every principal, historical voting checkpoint, native pending withdrawal, and bribe entitlement.

Protocol-owned state now lives in the namespaces listed in [architecture.md](architecture.md). OpenZeppelin's validator checks these namespaces as part of the upgrade layout. This does not migrate state from older sequential-storage deployments. Test against the exact deployed build and require an explicit, independently reviewed migration before upgrading any instance that already stores protocol state sequentially.
