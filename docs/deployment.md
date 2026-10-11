# Deployment and inspection

## Requirements and environment

Use Node.js 22.13 or newer, pnpm, Foundry, an RPC endpoint for the selected network, a funded deployer key, the protocol owner address (a Safe if multisignature authorization is required), and a deployed ERC-20 gauge reward token.

Create an untracked `.env` file (never commit keys):

```dotenv
DEPLOYER_PRIVATE_KEY=0x...
MONAD_TESTNET_RPC_URL=https://your-testnet-rpc
MONAD_MAINNET_RPC_URL=https://your-mainnet-rpc
MONAD_EXPLORER_API_KEY=...
PROTOCOL_OWNER_ADDRESS=0x...
GAUGE_REWARD_TOKEN_ADDRESS=0x...
MAX_LOCK_CYCLES=4
INITIAL_COMMISSION=0
```

The networks are named `local` (31337), `monadTestnet` (10143), and `monadMainnet` (143). Use the real Monad RPC environment variables; the localhost defaults in Hardhat config are intended to fail closed on an unconfigured external network.

## Deploy

From the repository root, install the shared workspace dependencies first:

```bash
pnpm install --frozen-lockfile
pnpm --filter @quevra/contracts deploy:all -- --network monadTestnet
```

`deploy:all` deploys all core modules and beacons in dependency order. To run the core step explicitly:

```bash
pnpm --filter @quevra/contracts deploy:core -- --network monadTestnet
```

`PROTOCOL_OWNER_ADDRESS` becomes the owner of each UUPS proxy and Beacon, with immediate upgrade authority. If unset, the deployer is owner. The core deployment initializes all four proxies, completes the one-time circular bindings, checks references, and records the configured owner. Check each proxy's `owner()` and each Beacon's `owner()` after deployment.

Manifests are written atomically under `deployments/<chainId>.json`; upgrade records are under `deployments/upgrades/`. These paths should be treated as private operational artifacts if they contain sensitive internal metadata. The script refuses to reuse a manifest from another network/chain and checks deployed code for manifest addresses. Operators must review the on-chain configuration and resulting output before continuing an interrupted deployment. A partially completed deployment can be resumed by rerunning the same command with the same network and configuration; do not delete a manifest to force a fresh deployment.

## Verify and inspect

```bash
pnpm --filter @quevra/contracts deploy:status -- --network monadTestnet
pnpm --filter @quevra/contracts deploy:verify -- --network monadTestnet
```

Status reads proxy/beacon implementation addresses from chain and compares them with the manifest. Verification submits supported implementation, proxy, and beacon sources to the configured Hardhat verification providers. If an explorer does not support a proxy form, inspect the command's manual-verification result and submit the reported address and constructor/initializer data through that explorer's supported workflow. Never treat an unsupported submission as verified.

## Validator vault flow

`StakingController.predictVaultAddress(requester, salt)` provides the deterministic vault address. The controller's deployment function checks the predicted auth address against the signed registration payload and creates/initializes the proxy atomically. For a new validator, construct and sign the Monad payload using this exact predicted address, submit the veValidator creation/onboarding transaction with the required signatures, and then inspect `vaultOf(tokenId)`, the vault's `validatorId()`, and the controller's `isValidatorActive(vault)`. Existing-validator onboarding uses the existing validator ID path. Registration does not imply active-set admission.

The source-level prediction path and native staking lifecycle require Foundry on a Monad fork or the Solonet harness. A generic Hardhat run does not validate the precompile or native staking identity.

## Package commands

```bash
pnpm --filter @quevra/contracts check
pnpm --filter @quevra/contracts deploy:all -- --network monadTestnet
pnpm --filter @quevra/contracts deploy:status -- --network monadTestnet
pnpm --filter @quevra/contracts deploy:verify -- --network monadTestnet
```

Use `monadMainnet` only after reviewing the config, direct owner address, RPC chain ID, and funded deployer. There is no committed production key or hardcoded owner address.
