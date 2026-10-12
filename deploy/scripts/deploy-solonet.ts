import { context, deployedCode, loadManifest, recordCodeHash, writeManifest } from "../lib/runtime.js";
import { deployAll } from "../lib/deploy.js";

const ctx = await context();
if (ctx.networkName !== "solonet" || ctx.chainId !== 20143) {
  throw new Error(`Solonet deployment requires network solonet (chain 20143), got ${ctx.networkName} (${ctx.chainId})`);
}

const deployer = await ctx.deployer.getAddress();
const manifest = await loadManifest(ctx.networkName, ctx.chainId, deployer);
const configuredRewardToken = process.env.SOLONET_GAUGE_REWARD_TOKEN_ADDRESS?.trim();
let rewardToken = configuredRewardToken || String(manifest.config.solonetRewardToken ?? "");

if (!rewardToken || !(await deployedCode(ctx.ethers.provider, rewardToken))) {
  const factory = await ctx.ethers.getContractFactory("SolonetRewardToken");
  const token = await factory.deploy();
  const transaction = token.deploymentTransaction();
  if (!transaction) throw new Error("Reward token deployment transaction is unavailable");
  await transaction.wait();
  rewardToken = await token.getAddress();
  manifest.config.solonetRewardToken = rewardToken;
  manifest.config.solonetRewardTokenTransactionHash = transaction.hash;
  manifest.config.solonetRewardTokenCodeHash = await recordCodeHash(ctx.ethers.provider, rewardToken);
  await writeManifest(manifest);
  console.log(`Deployed local Quevra reward token at ${rewardToken}`);
} else {
  manifest.config.solonetRewardToken = rewardToken;
  await writeManifest(manifest);
  console.log(`Using Solonet reward token at ${rewardToken}`);
}

process.env.GAUGE_REWARD_TOKEN_ADDRESS = rewardToken;
process.env.PROTOCOL_OWNER_ADDRESS = process.env.SOLONET_PROTOCOL_OWNER_ADDRESS ?? deployer;
await deployAll();
