import { ZeroAddress, getAddress } from "ethers";
import type { ContractFactory } from "ethers";
import {
  context,
  deployedCode,
  deploymentTx,
  loadManifest,
  numericEnv,
  recordCodeHash,
  requireEnv,
  writeManifest,
  type DeploymentManifest,
} from "./runtime.js";

const upgradeableBeaconAbi = [
  "function implementation() view returns (address)",
  "function owner() view returns (address)",
];

async function deployBeacon(
  manifest: DeploymentManifest,
  ctx: Awaited<ReturnType<typeof context>>,
  key: string,
  contractName: string,
  owner: string,
) {
  const prior = manifest.contracts[key];
  if (prior?.beacon) {
    if (!(await deployedCode(ctx.ethers.provider, prior.beacon))) {
      throw new Error(`Manifest ${key} beacon ${prior.beacon} has no on-chain code; refusing to redeploy`);
    }
    const beacon = await ctx.ethers.getContractAt(upgradeableBeaconAbi, prior.beacon);
    if ((await beacon.owner()) !== owner) throw new Error(`${key} beacon owner differs from PROTOCOL_OWNER_ADDRESS`);
    const implementation = await beacon.implementation();
    manifest.contracts[key] = {
      ...prior,
      implementation,
      codeHash: await recordCodeHash(ctx.ethers.provider, prior.beacon),
      implementationCodeHash: await recordCodeHash(ctx.ethers.provider, implementation),
      lastOperation: { action: "unchanged" },
    };
    await writeManifest(manifest, ctx.ethers.provider);
    return prior.beacon;
  }
  const Factory = await ctx.ethers.getContractFactory(contractName);
  const beacon = await ctx.upgrades.deployBeacon(Factory, { initialOwner: owner });
  const confirmation = await deploymentTx(beacon);
  const address = await beacon.getAddress();
  manifest.contracts[key] = {
    beacon: address,
    transactionHash: confirmation.hash,
    receipt: confirmation.receipt,
    lastOperation: { action: "deployed", transactionHash: confirmation.hash },
  };
  await writeManifest(manifest, ctx.ethers.provider);
  const implementation = await (await ctx.ethers.getContractAt(upgradeableBeaconAbi, address)).implementation();
  manifest.contracts[key] = {
    ...manifest.contracts[key],
    implementation,
    codeHash: await recordCodeHash(ctx.ethers.provider, address),
    implementationCodeHash: await recordCodeHash(ctx.ethers.provider, implementation),
  };
  await writeManifest(manifest, ctx.ethers.provider);
  return address;
}

async function deployUups(
  manifest: DeploymentManifest,
  ctx: Awaited<ReturnType<typeof context>>,
  key: string,
  contractName: string,
  args: unknown[],
) {
  const prior = manifest.contracts[key];
  if (prior?.proxy) {
    if (!(await deployedCode(ctx.ethers.provider, prior.proxy))) {
      throw new Error(`Manifest ${key} proxy ${prior.proxy} has no on-chain code; refusing to redeploy`);
    }
    const instance = await ctx.ethers.getContractAt(contractName, prior.proxy);
    const implementation = await ctx.upgrades.erc1967.getImplementationAddress(prior.proxy);
    manifest.contracts[key] = {
      ...prior,
      implementation,
      codeHash: await recordCodeHash(ctx.ethers.provider, prior.proxy),
      implementationCodeHash: await recordCodeHash(ctx.ethers.provider, implementation),
      initializer: prior.initializer ?? { name: "initialize", args },
      lastOperation: { action: "unchanged" },
    };
    await writeManifest(manifest, ctx.ethers.provider);
    return instance;
  }
  const Factory = await ctx.ethers.getContractFactory(contractName);
  const proxy = await ctx.upgrades.deployProxy(Factory, args, { kind: "uups", initializer: "initialize" });
  const confirmation = await deploymentTx(proxy);
  const address = await proxy.getAddress();
  manifest.contracts[key] = {
    proxy: address,
    transactionHash: confirmation.hash,
    receipt: confirmation.receipt,
    initializer: { name: "initialize", args },
    lastOperation: { action: "deployed", transactionHash: confirmation.hash },
  };
  await writeManifest(manifest, ctx.ethers.provider);
  const implementation = await ctx.upgrades.erc1967.getImplementationAddress(address);
  manifest.contracts[key] = {
    ...manifest.contracts[key],
    implementation,
    codeHash: await recordCodeHash(ctx.ethers.provider, address),
    implementationCodeHash: await recordCodeHash(ctx.ethers.provider, implementation),
  };
  await writeManifest(manifest, ctx.ethers.provider);
  return proxy;
}

export async function deployCore() {
  const ctx = await context();
  const deployer = await ctx.deployer.getAddress();
  const manifest = await loadManifest(ctx.networkName, ctx.chainId, deployer);
  const owner = getAddress(process.env.PROTOCOL_OWNER_ADDRESS ?? await ctx.deployer.getAddress());
  if (Object.keys(manifest.contracts).length && manifest.owner !== owner) {
    throw new Error("Existing manifest has a different PROTOCOL_OWNER_ADDRESS; refusing to change the owner during recovery");
  }
  const rewardToken = getAddress(requireEnv("GAUGE_REWARD_TOKEN_ADDRESS"));
  if (!(await deployedCode(ctx.ethers.provider, rewardToken))) throw new Error("Configured gauge reward token has no code");
  const maxLockCycles = numericEnv("MAX_LOCK_CYCLES", 4);
  const initialCommission = numericEnv("INITIAL_COMMISSION", 0);

  const vaultBeacon = await deployBeacon(manifest, ctx, "StakingVault", "StakingVault", owner);
  const agentBeacon = await deployBeacon(manifest, ctx, "StakingAgent", "StakingAgent", owner);
  const gaugeBeacon = await deployBeacon(manifest, ctx, "NonStakingGauge", "NonStakingGauge", owner);
  const bribeBeacon = await deployBeacon(manifest, ctx, "BribeVotingRewards", "BribeVotingRewards", owner);

  const controller = await deployUups(manifest, ctx, "StakingController", "StakingController", [
    deployer, initialCommission, vaultBeacon, agentBeacon,
  ]);
  const ve = await deployUups(manifest, ctx, "VeMON", "VeMON", [
    await controller.getAddress(), maxLockCycles, deployer,
  ]);
  const voter = await deployUups(manifest, ctx, "ValidatorsVoter", "ValidatorsVoter", [
    await ve.getAddress(), ZeroAddress, deployer, gaugeBeacon, bribeBeacon,
  ]);
  const validatorVe = await deployUups(manifest, ctx, "VeValidator", "VeValidator", [
    await controller.getAddress(), await voter.getAddress(), rewardToken, maxLockCycles, deployer,
  ]);

  for (const [name, contract] of [["StakingController", controller], ["ValidatorsVoter", voter]] as const) {
    if ((await contract.owner()) !== deployer) {
      const pendingSetup = name === "StakingController"
        ? (await contract.ve()) === ZeroAddress || (await contract.validatorVe()) === ZeroAddress
        : (await contract.boostableVe()) === ZeroAddress || !(await contract.isWhitelistedToken(rewardToken));
      if (pendingSetup) throw new Error(`${name} has incomplete setup but the deployer no longer owns it`);
    }
  }
  if ((await controller.ve()) === ZeroAddress) await (await controller.setVe(await ve.getAddress())).wait();
  if ((await controller.validatorVe()) === ZeroAddress) await (await controller.setValidatorVe(await validatorVe.getAddress())).wait();
  if ((await voter.boostableVe()) === ZeroAddress) await (await voter.setBoostableVe(await validatorVe.getAddress())).wait();
  if (!(await voter.isWhitelistedToken(rewardToken))) await (await voter.whitelistToken(rewardToken, true)).wait();

  const bindings = {
    controllerVe: await controller.ve(),
    controllerValidatorVe: await controller.validatorVe(),
    voterVe: await voter.ve(),
    voterBoostableVe: await voter.boostableVe(),
    gaugeBeacon: await voter.gaugeBeacon(),
    bribeBeacon: await voter.bribeBeacon(),
  };
  if (
    bindings.controllerVe !== await ve.getAddress() || bindings.controllerValidatorVe !== await validatorVe.getAddress()
      || bindings.voterVe !== await ve.getAddress() || bindings.voterBoostableVe !== await validatorVe.getAddress()
      || bindings.gaugeBeacon !== gaugeBeacon || bindings.bribeBeacon !== bribeBeacon
  ) throw new Error("Cross-contract reference validation failed");

  if (
    (await controller.vaultBeacon()) !== vaultBeacon || (await controller.agentBeacon()) !== agentBeacon
      || (await ve.controller()) !== await controller.getAddress() || (await ve.maxLockCycles()) !== BigInt(maxLockCycles)
      || (await voter.ve()) !== await ve.getAddress() || (await voter.gaugeBeacon()) !== gaugeBeacon
      || (await voter.bribeBeacon()) !== bribeBeacon || (await validatorVe.controller()) !== await controller.getAddress()
      || (await validatorVe.voter()) !== await voter.getAddress()
      || (await validatorVe.gaugeRewardToken()) !== rewardToken
      || (await validatorVe.maxLockCycles()) !== BigInt(maxLockCycles)
  ) throw new Error("Existing deployment initialization parameters differ from requested configuration");

  const handoffPending: string[] = [];
  for (const name of ["StakingController", "VeMON", "VeValidator", "ValidatorsVoter"]) {
    const record = manifest.contracts[name];
    if (!record?.proxy) continue;
    const contract = await ctx.ethers.getContractAt(name, record.proxy);
    const currentOwner = await contract.owner();
    const pendingOwner = await contract.pendingOwner();
    if (currentOwner === owner) continue;
    if (currentOwner !== deployer) throw new Error(`${name} owner is neither deployer nor configured owner`);
    if (pendingOwner !== owner) await (await contract.transferOwnership(owner)).wait();
    handoffPending.push(name);
  }

  manifest.config = { ...manifest.config, rewardToken, maxLockCycles, initialCommission, crossReferences: bindings };
  manifest.owner = owner;
  manifest.config.ownershipHandoffPending = handoffPending;
  await writeManifest(manifest, ctx.ethers.provider);
  console.log(JSON.stringify({
    chainId: ctx.chainId,
    contracts: Object.fromEntries(Object.entries(manifest.contracts).map(([key, item]) => [key, item.proxy ?? item.beacon])),
    rewardToken,
    owner,
    ownershipHandoffPending: handoffPending,
  }, null, 2));
}

export async function deployAll() {
  await deployCore();
}

export async function deployChildFactory(factory: ContractFactory) {
  return factory;
}
