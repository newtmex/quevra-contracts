import { ZeroAddress } from "ethers";
import { context, loadManifest, writeManifest } from "../lib/runtime.js";
import { numericEnv, requireEnv } from "../lib/runtime.js";

const ctx = await context();
const manifest = await loadManifest(ctx.networkName, ctx.chainId, await ctx.deployer.getAddress());

const addressFor = (name: string) => {
  const record = manifest.contracts[name];
  const address = record?.proxy ?? record?.beacon;
  if (!address) throw new Error(`Missing ${name} in deployment state`);
  return address;
};
const vaultBeacon = addressFor("StakingVault");
const agentBeacon = addressFor("StakingAgent");
const gaugeBeacon = addressFor("NonStakingGauge");
const bribeBeacon = addressFor("BribeVotingRewards");
const controllerAddress = addressFor("StakingController");
const veAddress = addressFor("VeMON");
const voterAddress = addressFor("ValidatorsVoter");
const validatorVeAddress = addressFor("VeValidator");
const deployer = manifest.deployer;
const rewardToken = requireEnv("GAUGE_REWARD_TOKEN_ADDRESS");
const maxLockCycles = numericEnv("MAX_LOCK_CYCLES", 4);
const initialCommission = numericEnv("INITIAL_COMMISSION", 0);

const controller = await ctx.ethers.getContractAt("StakingController", controllerAddress);
const ve = await ctx.ethers.getContractAt("VeMON", veAddress);
const voter = await ctx.ethers.getContractAt("ValidatorsVoter", voterAddress);
const validatorVe = await ctx.ethers.getContractAt("VeValidator", validatorVeAddress);
const same = (left: string, right: string) => left.toLowerCase() === right.toLowerCase();
const crossReferences = {
  controllerVe: await controller.ve(),
  controllerValidatorVe: await controller.validatorVe(),
  voterVe: await voter.ve(),
  voterBoostableVe: await voter.boostableVe(),
  gaugeBeacon: await voter.gaugeBeacon(),
  bribeBeacon: await voter.bribeBeacon(),
};

if (
  !same(await controller.vaultBeacon(), vaultBeacon)
  || !same(await controller.agentBeacon(), agentBeacon)
  || !same(await ve.controller(), controllerAddress)
  || BigInt(await ve.maxLockCycles()) !== BigInt(maxLockCycles)
  || !same(crossReferences.controllerVe, veAddress)
  || !same(crossReferences.controllerValidatorVe, validatorVeAddress)
  || !same(crossReferences.voterVe, veAddress)
  || !same(crossReferences.voterBoostableVe, validatorVeAddress)
  || !same(crossReferences.gaugeBeacon, gaugeBeacon)
  || !same(crossReferences.bribeBeacon, bribeBeacon)
  || !same(await validatorVe.controller(), controllerAddress)
  || !same(await validatorVe.voter(), voterAddress)
  || !same(await validatorVe.gaugeRewardToken(), rewardToken)
  || BigInt(await validatorVe.maxLockCycles()) !== BigInt(maxLockCycles)
  || !(await voter.isWhitelistedToken(rewardToken))
) {
  throw new Error("On-chain deployment does not match the configured artifact metadata; no artifacts were exported");
}

manifest.config = {
  ...manifest.config,
  rewardToken,
  maxLockCycles,
  initialCommission,
  crossReferences,
};
manifest.contracts.StakingController.initializer ??= {
  name: "initialize",
  args: [deployer, initialCommission, vaultBeacon, agentBeacon],
};
manifest.contracts.VeMON.initializer ??= {
  name: "initialize",
  args: [controllerAddress, maxLockCycles, deployer],
};
manifest.contracts.ValidatorsVoter.initializer ??= {
  name: "initialize",
  args: [veAddress, ZeroAddress, deployer, gaugeBeacon, bribeBeacon],
};
manifest.contracts.VeValidator.initializer ??= {
  name: "initialize",
  args: [controllerAddress, voterAddress, rewardToken, maxLockCycles, deployer],
};
for (const record of Object.values(manifest.contracts)) {
  record.lastOperation ??= {
    action: "deployed",
    ...(record.transactionHash ? { transactionHash: record.transactionHash } : {}),
  };
}

await writeManifest(manifest, ctx.ethers.provider);

console.log(JSON.stringify({
  network: manifest.network,
  chainId: manifest.chainId,
  artifactsDirectory: `deployments/${manifest.network}`,
  contracts: Object.keys(manifest.contracts),
}, null, 2));
