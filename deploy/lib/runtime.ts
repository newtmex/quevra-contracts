import { mkdir, readFile, readdir, rename, writeFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { TransactionReceipt } from "ethers";
import hre from "hardhat";
import { upgrades as createUpgradesApi } from "@openzeppelin/hardhat-upgrades";

export type ContractRecord = {
  proxy?: string;
  implementation?: string;
  beacon?: string;
  transactionHash?: string;
  receipt?: Record<string, unknown>;
  codeHash?: string;
  implementationCodeHash?: string;
  initializer?: { name: string | false; args: unknown[] };
  lastOperation?: { action: "deployed" | "upgraded" | "unchanged"; transactionHash?: string };
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

const packageRoot = path.resolve(fileURLToPath(new URL("../../", import.meta.url)));
const deploymentsDir = path.join(packageRoot, "deployments");

type AppDeploymentArtifact = {
  address: string;
  abi: readonly unknown[];
  transactionHash?: string;
  receipt?: Record<string, unknown>;
  numDeployments: number;
  linkedData: Record<string, unknown>;
};

type ReceiptProvider = { getTransactionReceipt(hash: string): Promise<TransactionReceipt | null> };

const upgradeableBeaconAbi = [
  "error BeaconInvalidImplementation(address implementation)",
  "event Upgraded(address indexed implementation)",
  "function implementation() view returns (address)",
  "function upgradeTo(address newImplementation)",
  "function owner() view returns (address)",
  "function transferOwnership(address newOwner)",
  "function renounceOwnership()",
];

function toJsonCompatible<T>(value: T): T {
  return JSON.parse(JSON.stringify(value, (_key, nestedValue) =>
    typeof nestedValue === "bigint" ? nestedValue.toString() : nestedValue)) as T;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function artifactDirectory(networkName: string): string {
  if (!/^[a-zA-Z0-9_-]+$/.test(networkName)) throw new Error(`Invalid deployment network name: ${networkName}`);
  return path.join(deploymentsDir, networkName);
}

async function readApplicationArtifact(file: string): Promise<AppDeploymentArtifact | undefined> {
  try {
    const value = JSON.parse(await readFile(file, "utf8")) as unknown;
    if (!isRecord(value) || typeof value.address !== "string" || !Array.isArray(value.abi)) return undefined;
    return value as AppDeploymentArtifact;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw error;
  }
}

async function restoreManifestFromArtifacts(
  networkName: string,
  chainId: number,
  deployer: string,
): Promise<DeploymentManifest | undefined> {
  const directory = artifactDirectory(networkName);
  let files: string[];
  try {
    files = await readdir(directory);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw error;
  }

  const contracts: DeploymentManifest["contracts"] = {};
  let protocol: Record<string, unknown> | undefined;
  for (const fileName of files.filter((name) => name.endsWith(".json"))) {
    const saved = await readApplicationArtifact(path.join(directory, fileName));
    if (!saved || !saved.address) continue;
    const linkedData = saved.linkedData;
    const proxyKind = linkedData?.proxyKind;
    if (proxyKind !== "uups" && proxyKind !== "beacon") continue;
    const name = typeof linkedData.deploymentName === "string"
      ? linkedData.deploymentName
      : fileName.slice(0, -5);
    const initializer = linkedData.initializer;
    const lastOperation = linkedData.lastOperation;
    contracts[name] = {
      ...(proxyKind === "uups" ? { proxy: saved.address } : { beacon: saved.address }),
      ...(saved.transactionHash ? { transactionHash: saved.transactionHash } : {}),
      ...(saved.receipt ? { receipt: saved.receipt } : {}),
      ...(isRecord(initializer) && (typeof initializer.name === "string" || initializer.name === false)
        ? { initializer: { name: initializer.name, args: Array.isArray(initializer.args) ? initializer.args : [] } }
        : {}),
      ...(isRecord(lastOperation) && ["deployed", "upgraded", "unchanged"].includes(String(lastOperation.action))
        ? { lastOperation: {
          action: lastOperation.action as "deployed" | "upgraded" | "unchanged",
          ...(typeof lastOperation.transactionHash === "string" ? { transactionHash: lastOperation.transactionHash } : {}),
        } }
        : {}),
    };
    if (isRecord(linkedData.protocol)) protocol = linkedData.protocol;
  }

  if (Object.keys(contracts).length === 0) return undefined;
  const savedChainId = Number(protocol?.chainId ?? chainId);
  const savedNetwork = String(protocol?.network ?? networkName);
  if (savedChainId !== chainId || savedNetwork !== networkName) {
    throw new Error(`Tracked deployments belong to ${savedNetwork} (${savedChainId}), not ${networkName} (${chainId})`);
  }
  return {
    schemaVersion: 1,
    network: networkName,
    chainId,
    timestamp: String(protocol?.timestamp ?? new Date().toISOString()),
    gitCommit: String(protocol?.gitCommit ?? "restored-from-deployment-artifacts"),
    compiler: isRecord(protocol?.compiler)
      ? protocol.compiler as DeploymentManifest["compiler"]
      : { solc: "0.8.28", evmVersion: "cancun", optimizerRuns: 200 },
    deployer: String(protocol?.deployer ?? deployer),
    owner: String(protocol?.owner ?? deployer),
    config: isRecord(protocol?.config) ? protocol.config : {},
    contracts,
    dynamicInstances: Array.isArray(protocol?.dynamicInstances)
      ? protocol.dynamicInstances as DeploymentManifest["dynamicInstances"]
      : [],
    upgrades: Array.isArray(protocol?.upgrades) ? protocol.upgrades as DeploymentManifest["upgrades"] : [],
    verification: isRecord(protocol?.verification) ? protocol.verification as Record<string, string> : {},
  };
}

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
    const restored = await restoreManifestFromArtifacts(networkName, chainId, deployer);
    if (restored) return restored;
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

function serializedReceipt(receipt: TransactionReceipt): Record<string, unknown> {
  return {
    from: receipt.from,
    to: receipt.to ?? undefined,
    transactionHash: receipt.hash,
    blockHash: receipt.blockHash,
    blockNumber: receipt.blockNumber,
    transactionIndex: receipt.index,
    cumulativeGasUsed: receipt.cumulativeGasUsed.toString(),
    gasUsed: receipt.gasUsed.toString(),
    contractAddress: receipt.contractAddress ?? undefined,
    logs: receipt.logs.map((log) => ({
      transactionHash: log.transactionHash,
      transactionIndex: log.transactionIndex,
      blockHash: log.blockHash,
      blockNumber: log.blockNumber,
      logIndex: log.index,
      removed: log.removed,
      address: log.address,
      topics: [...log.topics],
      data: log.data,
    })),
    logsBloom: receipt.logsBloom,
    status: receipt.status ?? undefined,
  };
}

export async function writeDeploymentArtifacts(
  manifest: DeploymentManifest,
  provider?: ReceiptProvider,
): Promise<void> {
  const directory = artifactDirectory(manifest.network);
  await mkdir(directory, { recursive: true });
  const protocol = toJsonCompatible({
    network: manifest.network,
    chainId: manifest.chainId,
    timestamp: manifest.timestamp,
    gitCommit: manifest.gitCommit,
    compiler: manifest.compiler,
    deployer: manifest.deployer,
    owner: manifest.owner,
    config: manifest.config,
    dynamicInstances: manifest.dynamicInstances,
    upgrades: manifest.upgrades,
    verification: manifest.verification,
  });

  for (const [name, record] of Object.entries(manifest.contracts)) {
    const address = record.proxy ?? record.beacon;
    if (!address) continue;
    const artifact = await hre.artifacts.readArtifact(name);
    if (record.proxy) {
      const file = path.join(directory, `${name}.json`);
      const previous = await readApplicationArtifact(file);
      let receipt = record.receipt ?? previous?.receipt;
      if (!receipt && record.transactionHash && provider) {
        const mined = await provider.getTransactionReceipt(record.transactionHash);
        if (mined) receipt = serializedReceipt(mined);
      }
      const previousLinkedData = previous?.linkedData ?? {};
      const previousLastOperation = isRecord(previousLinkedData.lastOperation)
        ? previousLinkedData.lastOperation
        : undefined;
      const saved: AppDeploymentArtifact = {
        address,
        abi: artifact.abi,
        ...(record.transactionHash ?? previous?.transactionHash
          ? { transactionHash: record.transactionHash ?? previous?.transactionHash }
          : {}),
        ...(receipt ? { receipt } : {}),
        numDeployments: previous?.numDeployments ?? 1,
        linkedData: toJsonCompatible({
          ...previousLinkedData,
          contractName: artifact.contractName,
          sourceName: artifact.sourceName,
          proxyKind: "uups",
          ...(record.initializer ? { initializer: record.initializer } : {}),
          protocol,
          lastOperation: record.lastOperation ?? previousLastOperation ?? {
            action: "deployed",
            ...(record.transactionHash ? { transactionHash: record.transactionHash } : {}),
          },
        }),
      };
      const temp = `${file}.${process.pid}.tmp`;
      await writeFile(temp, `${JSON.stringify(saved, null, 2)}\n`, { mode: 0o644 });
      await rename(temp, file);
      continue;
    }

    const implementationFile = path.join(directory, `${name}.json`);
    const beaconFile = path.join(directory, `${name}Beacon.json`);
    const oldNamedArtifact = await readApplicationArtifact(implementationFile);
    const previousBeacon = await readApplicationArtifact(beaconFile)
      ?? (oldNamedArtifact?.address === address ? oldNamedArtifact : undefined);
    let receipt = record.receipt ?? previousBeacon?.receipt;
    if (!receipt && record.transactionHash && provider) {
      const mined = await provider.getTransactionReceipt(record.transactionHash);
      if (mined) receipt = serializedReceipt(mined);
    }
    const previousLastOperation = isRecord(previousBeacon?.linkedData.lastOperation)
      ? previousBeacon.linkedData.lastOperation
      : undefined;
    const beaconRecord: AppDeploymentArtifact = {
      address,
      abi: upgradeableBeaconAbi,
      ...(record.transactionHash ?? previousBeacon?.transactionHash
        ? { transactionHash: record.transactionHash ?? previousBeacon?.transactionHash }
        : {}),
      ...(receipt ? { receipt } : {}),
      numDeployments: previousBeacon?.numDeployments ?? 1,
      linkedData: toJsonCompatible({
        contractName: "UpgradeableBeacon",
        sourceName: "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol",
        deploymentName: name,
        implementationContract: artifact.contractName,
        proxyKind: "beacon",
        protocol,
        lastOperation: record.lastOperation ?? previousLastOperation ?? {
          action: "deployed",
          ...(record.transactionHash ? { transactionHash: record.transactionHash } : {}),
        },
      }),
    };
    const beaconTemp = `${beaconFile}.${process.pid}.tmp`;
    await writeFile(beaconTemp, `${JSON.stringify(beaconRecord, null, 2)}\n`, { mode: 0o644 });
    await rename(beaconTemp, beaconFile);

    const implementationRecord: AppDeploymentArtifact = {
      address: "",
      abi: artifact.abi,
      numDeployments: oldNamedArtifact?.numDeployments ?? 1,
      linkedData: {
        contractName: artifact.contractName,
        sourceName: artifact.sourceName,
        proxyKind: "beacon-implementation",
      },
    };
    const implementationTemp = `${implementationFile}.${process.pid}.tmp`;
    await writeFile(implementationTemp, `${JSON.stringify(implementationRecord, null, 2)}\n`, { mode: 0o644 });
    await rename(implementationTemp, implementationFile);
  }
}

export async function writeManifest(
  manifest: DeploymentManifest,
  provider?: ReceiptProvider,
): Promise<void> {
  manifest.timestamp = new Date().toISOString();
  const target = manifestPath(manifest.chainId);
  const temp = `${target}.${process.pid}.tmp`;
  await writeFile(temp, `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600 });
  await rename(temp, target);
  await writeDeploymentArtifacts(manifest, provider);
}

export async function deployedCode(provider: { getCode(address: string): Promise<string> }, address?: string): Promise<boolean> {
  if (!address) return false;
  let lastError: unknown;
  for (let attempt = 0; attempt < 8; attempt += 1) {
    try {
      if ((await provider.getCode(address)) !== "0x") return true;
      lastError = undefined;
    } catch (error) {
      lastError = error;
    }
    if (attempt < 7) await new Promise((resolve) => setTimeout(resolve, 250 * (attempt + 1)));
  }
  if (lastError) throw new Error(`Unable to read code at ${address}: ${(lastError as Error).message}`);
  return false;
}

type DeploymentTransaction = {
  hash: string;
  wait(): Promise<TransactionReceipt | null>;
};

export async function deploymentTx(contract: {
  deploymentTransaction?: () => DeploymentTransaction | null;
  deployTransaction?: DeploymentTransaction | null;
}) {
  const tx = contract.deploymentTransaction?.() ?? contract.deployTransaction ?? null;
  if (!tx) throw new Error("Deployment transaction is unavailable");
  const receipt = await tx.wait();
  if (!receipt) throw new Error("Deployment transaction was not confirmed");
  if (receipt.status !== undefined && receipt.status !== null && receipt.status !== 1) {
    throw new Error(`Deployment transaction ${tx.hash} reverted`);
  }
  return {
    hash: tx.hash,
    receipt: serializedReceipt(receipt),
  };
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
