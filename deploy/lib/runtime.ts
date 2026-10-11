import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import path from "node:path";
import hre from "hardhat";
import { upgrades as createUpgradesApi } from "@openzeppelin/hardhat-upgrades";

export type ContractRecord = {
  proxy?: string;
  implementation?: string;
  beacon?: string;
  transactionHash?: string;
  codeHash?: string;
  implementationCodeHash?: string;
};

export type DeploymentManifest = {
  schemaVersion: 1;
  network: string;
  chainId: number;
  timestamp: string;
  gitCommit: string;
  compiler: { solc: string; evmVersion: string; optimizerRuns: number };
  deployer: string;
  owner: string;
  config: Record<string, unknown>;
  contracts: Record<string, ContractRecord>;
  dynamicInstances: { kind: string; address: string; transactionHash?: string }[];
  upgrades: Record<string, unknown>[];
  verification: Record<string, string>;
};

export async function context() {
  const connection = await hre.network.create();
  const { ethers } = connection;
  const upgrades = await createUpgradesApi(hre, connection);
  const [deployer] = await ethers.getSigners();
  const network = await ethers.provider.getNetwork();
  return {
    connection,
    ethers,
    upgrades,
    deployer,
    networkName: hre.globalOptions.network ?? "local",
    chainId: Number(network.chainId),
  };
}

export function requireEnv(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`Missing required environment variable ${name}`);
  return value;
}

export function numericEnv(name: string, fallback?: number): number {
  const raw = process.env[name];
  if (raw === undefined && fallback !== undefined) return fallback;
  if (raw === undefined || !/^\d+$/.test(raw)) throw new Error(`${name} must be a non-negative integer`);
  const value = Number(raw);
  if (!Number.isSafeInteger(value)) throw new Error(`${name} exceeds JavaScript's safe integer range`);
  return value;
}

const deploymentsDir = path.resolve("deployments");

export async function loadManifest(networkName: string, chainId: number, deployer: string): Promise<DeploymentManifest> {
  await mkdir(deploymentsDir, { recursive: true });
  const file = manifestPath(chainId);
  try {
    const manifest = JSON.parse(await readFile(file, "utf8")) as DeploymentManifest;
    if (manifest.chainId !== chainId) throw new Error(`Manifest ${file} has an unexpected chain ID`);
    if (manifest.network !== networkName) throw new Error(`Manifest ${file} belongs to ${manifest.network}`);
    return manifest;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    return {
      schemaVersion: 1,
      network: networkName,
      chainId,
      timestamp: new Date().toISOString(),
      gitCommit: execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim(),
      compiler: { solc: "0.8.28", evmVersion: "cancun", optimizerRuns: 200 },
      deployer,
      owner: process.env.PROTOCOL_OWNER_ADDRESS ?? deployer,
      config: {},
      contracts: {},
      dynamicInstances: [],
      upgrades: [],
      verification: {},
    };
  }
}

function manifestPath(chainId: number): string {
  return path.join(deploymentsDir, `${chainId}.json`);
}

export async function writeManifest(manifest: DeploymentManifest): Promise<void> {
  manifest.timestamp = new Date().toISOString();
  const target = manifestPath(manifest.chainId);
  const temp = `${target}.${process.pid}.tmp`;
  await writeFile(temp, `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600 });
  await rename(temp, target);
}

export async function deployedCode(provider: { getCode(address: string): Promise<string> }, address?: string): Promise<boolean> {
  if (!address) return false;
  return (await provider.getCode(address)) !== "0x";
}

export async function deploymentTx(contract: { deploymentTransaction(): { hash: string; wait(): Promise<unknown> } | null }) {
  const tx = contract.deploymentTransaction();
  if (!tx) throw new Error("Deployment transaction is unavailable");
  const receipt = await tx.wait();
  if (!receipt) throw new Error("Deployment transaction was not confirmed");
  return tx.hash;
}

export async function recordCodeHash(provider: { getCode(address: string): Promise<string> }, address: string) {
  const code = await provider.getCode(address);
  if (code === "0x") throw new Error(`No code at ${address}`);
  const { keccak256 } = await import("ethers");
  return keccak256(code);
}

export async function existingCodeOrThrow(provider: { getCode(address: string): Promise<string> }, record: ContractRecord | undefined) {
  if (!record?.proxy) return false;
  if (!(await deployedCode(provider, record.proxy))) {
    throw new Error(`Manifest proxy ${record.proxy} has no on-chain code; refusing to reuse it`);
  }
  return true;
}
