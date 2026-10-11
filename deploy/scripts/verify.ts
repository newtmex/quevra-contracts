import { verifyContract } from "@nomicfoundation/hardhat-verify/verify";
import hre from "hardhat";
import { context, loadManifest, writeManifest } from "../lib/runtime.js";

const ctx = await context();
const manifest = await loadManifest(ctx.networkName, ctx.chainId, await ctx.deployer.getAddress());
const fqn: Record<string, string> = {
  StakingController: "src/staking/StakingController.sol:StakingController",
  VeMON: "src/VeMON.sol:VeMON",
  VeValidator: "src/VeValidator.sol:VeValidator",
  ValidatorsVoter: "src/voting/ValidatorsVoter.sol:ValidatorsVoter",
  StakingVault: "src/staking/controlled/StakingVault.sol:StakingVault",
  StakingAgent: "src/staking/controlled/StakingAgent.sol:StakingAgent",
  NonStakingGauge: "src/gauges/NonStakingGauge.sol:NonStakingGauge",
  BribeVotingRewards: "src/rewards/BribeVotingRewards.sol:BribeVotingRewards",
};
const results: Record<string, string> = {};
for (const [name, record] of Object.entries(manifest.contracts)) {
  const contractName = name;
  const submissions = [
    ...(record.implementation ? [{ address: record.implementation, contract: fqn[contractName] }] : []),
    ...(record.beacon ? [{ address: record.beacon, contract: "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol:UpgradeableBeacon" }] : []),
    ...(record.proxy ? [{ address: record.proxy }] : []),
  ];
  for (const submission of submissions) {
    const address = submission.address;
    try {
      const ok = await verifyContract(submission, hre);
      results[address] = ok ? "verified" : "not verified";
    } catch (error) {
      results[address] = `manual verification required: ${(error as Error).message}`;
    }
  }
}
manifest.verification = { ...manifest.verification, ...results };
await writeManifest(manifest);
console.log(JSON.stringify(results, null, 2));
