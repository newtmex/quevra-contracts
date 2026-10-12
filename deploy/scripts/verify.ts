import { verifyContract } from "@nomicfoundation/hardhat-verify/verify";
import hre from "hardhat";
import { context, loadManifest, recordCodeHash, writeManifest } from "../lib/runtime.js";

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

const upgradeableBeaconAbi = ["function implementation() view returns (address)"];

type ProviderName = "sourcify" | "etherscan";

type Submission = {
  label: string;
  name: string;
  address: string;
  contract: string;
  constructorArgs?: unknown[];
  creationTxHash?: string;
};

function explorerLinks(chainId: number, address: string): { sourcify: string; monadVision: string; monadscan: string } {
  if (chainId === 143) {
    return {
      sourcify: `https://sourcify-api-monad.blockvision.org/repo-ui/${chainId}/${address}`,
      monadVision: `https://monadvision.com/address/${address}`,
      monadscan: `https://monadscan.com/address/${address}`,
    };
  }
  return {
    sourcify: `https://sourcify-api-monad.blockvision.org/repo-ui/${chainId}/${address}`,
    monadVision: `https://testnet.monadvision.com/address/${address}`,
    monadscan: `https://testnet.monadscan.com/address/${address}`,
  };
}

function providersToRun(): ProviderName[] {
  const requested = (process.env.VERIFY_PROVIDERS ?? "sourcify")
    .split(",")
    .map((value) => value.trim().toLowerCase())
    .filter(Boolean);
  const providers: ProviderName[] = [];
  for (const name of requested) {
    if (name === "sourcify" || name === "etherscan") providers.push(name);
  }
  if (providers.length === 0) providers.push("sourcify");
  return [...new Set(providers)];
}

async function submit(
  submission: Submission,
  provider: ProviderName,
  results: Record<string, string>,
): Promise<void> {
  const key = `${provider}:${submission.address}`;
  try {
    const ok = await verifyContract(
      {
        address: submission.address,
        contract: submission.contract,
        constructorArgs: submission.constructorArgs ?? [],
        ...(submission.creationTxHash ? { creationTxHash: submission.creationTxHash } : {}),
        provider,
        force: process.env.VERIFY_FORCE === "1",
      },
      hre,
    );
    results[key] = ok ? "verified" : "not verified";
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (/already verified/i.test(message)) {
      results[key] = "already verified";
      return;
    }
    results[key] = `failed: ${message}`;
  }
}

const ctx = await context();
const manifest = await loadManifest(ctx.networkName, ctx.chainId, await ctx.deployer.getAddress());
const providers = providersToRun();
const results: Record<string, string> = {};
const submissions: Submission[] = [];

// Verify the live Quevra implementations. Shared UpgradeableBeacon contracts are
// stock OpenZeppelin bytecode; this script verifies their implementation() targets.
for (const [name, record] of Object.entries(manifest.contracts)) {
  const contractFqn = fqn[name];
  if (!contractFqn) continue;

  let implementation = record.implementation;
  if (record.proxy) {
    implementation = await ctx.upgrades.erc1967.getImplementationAddress(record.proxy);
  } else if (record.beacon) {
    implementation = await (await ctx.ethers.getContractAt(upgradeableBeaconAbi, record.beacon)).implementation();
  }
  if (!implementation) continue;

  record.implementation = implementation;
  record.implementationCodeHash = await recordCodeHash(ctx.ethers.provider, implementation);
  submissions.push({
    label: `${name} implementation`,
    name,
    address: implementation,
    contract: contractFqn,
    // UUPS / beacon implementations use empty constructors with _disableInitializers().
    constructorArgs: [],
  });
}

console.log(
  JSON.stringify(
    {
      network: ctx.networkName,
      chainId: ctx.chainId,
      providers,
      submissions: submissions.map((entry) => ({
        label: entry.label,
        address: entry.address,
        contract: entry.contract,
        hasCreationTx: Boolean(entry.creationTxHash),
        explorers: explorerLinks(ctx.chainId, entry.address),
      })),
    },
    null,
    2,
  ),
);

for (const provider of providers) {
  for (const submission of submissions) {
    console.log(`Verifying ${submission.label} on ${provider}: ${submission.address}`);
    await submit(submission, provider, results);
    console.log(`  -> ${results[`${provider}:${submission.address}`]}`);
  }
}

manifest.verification = {
  ...results,
  verifiedAt: new Date().toISOString(),
  providers: providers.join(","),
  gitCommit: manifest.gitCommit,
};
await writeManifest(manifest, ctx.ethers.provider);

const failed = Object.entries(results).filter(([, status]) => status.startsWith("failed"));
console.log(JSON.stringify({ results, failed: failed.length }, null, 2));
if (failed.length > 0) process.exitCode = 1;
