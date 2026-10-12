import { readFile } from "node:fs/promises";
import path from "node:path";
import {
  context,
  loadManifest,
  recordCodeHash,
  requireEnv,
  writeManifest,
} from "../lib/runtime.js";

type UpgradeKind = "uups" | "beacon";

type PreparedUpgrade = {
  network: string;
  chainId: number;
  kind: UpgradeKind;
  target: string;
  contract: string;
  previousImplementation: string;
  implementation: string;
  previousCodeHash: string;
  newCodeHash: string;
  migrationCalldata: string;
  validated: true;
};

const upgradeableBeaconAbi = [
  "function implementation() view returns (address)",
  "function upgradeTo(address newImplementation)",
  "function owner() view returns (address)",
];

const uupsOwnerAbi = [
  "function owner() view returns (address)",
  "function upgradeToAndCall(address newImplementation, bytes data) payable",
];

function preparedPath(network: string, chainId: number, target: string) {
  return path.resolve("deployments", "upgrades", `${chainId}-${target.toLowerCase()}.json`);
}

async function loadPrepared(network: string, chainId: number, target: string): Promise<PreparedUpgrade> {
  const file = preparedPath(network, chainId, target);
  const value = JSON.parse(await readFile(file, "utf8")) as PreparedUpgrade;
  if (value.target.toLowerCase() !== target.toLowerCase()) {
    throw new Error(`Prepared upgrade target mismatch in ${file}`);
  }
  if (value.network !== network || value.chainId !== chainId) {
    throw new Error(`Prepared upgrade network mismatch in ${file}`);
  }
  if (!value.validated || !value.implementation) {
    throw new Error(`Prepared upgrade in ${file} is incomplete`);
  }
  return value;
}

const ctx = await context();
if (ctx.chainId === 143) {
  throw new Error("upgrade:apply refuses monadMainnet; submit the prepared owner transaction through the configured owner workflow");
}
if (ctx.chainId !== 31337 && process.env.UPGRADE_ALLOW_REMOTE !== "1") {
  throw new Error("Set UPGRADE_ALLOW_REMOTE=1 to apply a prepared upgrade on a non-local network");
}

const kind = (process.env.UPGRADE_KIND ?? "") as UpgradeKind;
if (kind !== "uups" && kind !== "beacon") throw new Error("UPGRADE_KIND must be uups or beacon");
const target = requireEnv("UPGRADE_TARGET");
const contractName = requireEnv("UPGRADE_CONTRACT");
const prepared = await loadPrepared(ctx.networkName, ctx.chainId, target);
if (prepared.kind !== kind) throw new Error(`Prepared kind ${prepared.kind} does not match UPGRADE_KIND=${kind}`);
if (prepared.contract !== contractName) {
  throw new Error(`Prepared contract ${prepared.contract} does not match UPGRADE_CONTRACT=${contractName}`);
}

const deployer = await ctx.deployer.getAddress();
const ownerContract = await ctx.ethers.getContractAt(
  kind === "uups" ? uupsOwnerAbi : upgradeableBeaconAbi,
  target,
);
const ownerAddress = await ownerContract.owner() as string;
if (ownerAddress.toLowerCase() !== deployer.toLowerCase()) {
  throw new Error(
    `Deployer ${deployer} is not the on-chain owner ${ownerAddress}; submit the prepared upgrade from the owner instead`,
  );
}

const liveHash = await recordCodeHash(ctx.ethers.provider, prepared.implementation);
if (liveHash !== prepared.newCodeHash) {
  throw new Error(
    `Prepared implementation ${prepared.implementation} code hash ${liveHash} does not match ${prepared.newCodeHash}`,
  );
}

let txHash: string | undefined;
if (kind === "uups") {
  const proxy = await ctx.ethers.getContractAt(uupsOwnerAbi, target);
  const tx = await proxy.upgradeToAndCall(prepared.implementation, prepared.migrationCalldata ?? "0x");
  const receipt = await tx.wait();
  if (!receipt || receipt.status !== 1) throw new Error(`UUPS upgrade transaction failed for ${target}`);
  txHash = tx.hash;
} else {
  const beacon = await ctx.ethers.getContractAt(upgradeableBeaconAbi, target);
  const tx = await beacon.upgradeTo(prepared.implementation);
  const receipt = await tx.wait();
  if (!receipt || receipt.status !== 1) throw new Error(`Beacon upgrade transaction failed for ${target}`);
  txHash = tx.hash;
}

const nextImplementation = kind === "uups"
  ? await ctx.upgrades.erc1967.getImplementationAddress(target)
  : await (await ctx.ethers.getContractAt(upgradeableBeaconAbi, target)).implementation();
if (nextImplementation.toLowerCase() !== prepared.implementation.toLowerCase()) {
  throw new Error(`On-chain implementation ${nextImplementation} does not match prepared ${prepared.implementation}`);
}

const manifest = await loadManifest(ctx.networkName, ctx.chainId, deployer);
const entry = Object.entries(manifest.contracts).find(([, record]) => {
  const address = record.proxy ?? record.beacon;
  return address?.toLowerCase() === target.toLowerCase();
});
if (!entry) throw new Error(`No manifest contract matches upgrade target ${target}`);
const [name, record] = entry;
manifest.contracts[name] = {
  ...record,
  implementation: nextImplementation,
  implementationCodeHash: liveHash,
  lastOperation: { action: "upgraded", transactionHash: txHash },
};
await writeManifest(manifest, ctx.ethers.provider);

console.log(
  JSON.stringify(
    {
      network: ctx.networkName,
      chainId: ctx.chainId,
      kind,
      target,
      contract: contractName,
      previousImplementation: prepared.previousImplementation,
      implementation: nextImplementation,
      transactionHash: txHash,
      manifestKey: name,
    },
    null,
    2,
  ),
);
