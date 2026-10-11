import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import {
  context,
  loadManifest,
  recordCodeHash,
  requireEnv,
  writeManifest,
} from "./runtime.js";

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

function kindFromEnv(): UpgradeKind {
  const kind = process.env.UPGRADE_KIND;
  if (kind !== "uups" && kind !== "beacon") throw new Error("UPGRADE_KIND must be uups or beacon");
  return kind;
}

function preparedPath(network: string, chainId: number, target: string) {
  return path.resolve("deployments", "upgrades", `${chainId}-${target.toLowerCase()}.json`);
}

async function savePrepared(prepared: PreparedUpgrade) {
  const file = preparedPath(prepared.network, prepared.chainId, prepared.target);
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, `${JSON.stringify(prepared, null, 2)}\n`, { mode: 0o600 });
}

export async function validateUpgrade() {
  const ctx = await context();
  const kind = kindFromEnv();
  const target = requireEnv("UPGRADE_TARGET");
  const contractName = requireEnv("UPGRADE_CONTRACT");
  const Factory = await ctx.ethers.getContractFactory(contractName);
  const result = await ctx.upgrades.validateUpgrade(target, Factory, { kind });
  console.log(JSON.stringify({ target, contractName, kind, storageValidation: "passed", result }, null, 2));
}

export async function prepareUpgrade() {
  const ctx = await context();
  const kind = kindFromEnv();
  const target = requireEnv("UPGRADE_TARGET");
  const contractName = requireEnv("UPGRADE_CONTRACT");
  const Factory = await ctx.ethers.getContractFactory(contractName);
  const implementation = await ctx.upgrades.prepareUpgrade(target, Factory, { kind });
  if (typeof implementation !== "string") throw new Error("Expected prepareUpgrade to return an implementation address");
  const previousImplementation = kind === "uups"
    ? await ctx.upgrades.erc1967.getImplementationAddress(target)
    : await (await ctx.ethers.getContractAt("UpgradeableBeacon", target)).implementation();
  const migrationCalldata = process.env.UPGRADE_MIGRATION_CALLDATA ?? "0x";
  const record: PreparedUpgrade = {
    network: ctx.networkName,
    chainId: ctx.chainId,
    kind,
    target,
    contract: contractName,
    previousImplementation,
    implementation,
    previousCodeHash: await recordCodeHash(ctx.ethers.provider, previousImplementation),
    newCodeHash: await recordCodeHash(ctx.ethers.provider, implementation),
    migrationCalldata,
    validated: true,
  };
  await savePrepared(record);
  const manifest = await loadManifest(ctx.networkName, ctx.chainId, await ctx.deployer.getAddress());
  manifest.upgrades.push({ ...record, preparedAt: new Date().toISOString() });
  await writeManifest(manifest);
  console.log(JSON.stringify(record, null, 2));
}

export async function executeUpgradeLocally() {
  const ctx = await context();
  if (ctx.chainId !== 31337 || ctx.networkName !== "local") throw new Error("Direct upgrade execution is restricted to the Hardhat local network (31337)");
  const kind = kindFromEnv();
  const target = requireEnv("UPGRADE_TARGET");
  const contractName = requireEnv("UPGRADE_CONTRACT");
  const Factory = await ctx.ethers.getContractFactory(contractName);
  const instance = kind === "uups"
    ? await ctx.upgrades.upgradeProxy(target, Factory, { kind, call: migrationCall() })
    : await ctx.upgrades.upgradeBeacon(target, Factory);
  await instance.waitForDeployment();
  console.log(JSON.stringify({ target, implementation: await ctx.upgrades.erc1967.getImplementationAddress(target), kind }, null, 2));
}

function migrationCall(): { fn: string; args?: unknown[] } | undefined {
  const fn = process.env.UPGRADE_MIGRATION_FUNCTION;
  if (!fn) return undefined;
  return { fn, args: JSON.parse(process.env.UPGRADE_MIGRATION_ARGS ?? "[]") as unknown[] };
}
