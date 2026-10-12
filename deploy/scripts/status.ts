import { context, deployedCode, loadManifest } from "../lib/runtime.js";

const ctx = await context();
const manifest = await loadManifest(ctx.networkName, ctx.chainId, await ctx.deployer.getAddress());
const contracts: Record<string, unknown> = {};
for (const [name, record] of Object.entries(manifest.contracts)) {
  const address = record.proxy ?? record.beacon;
  const onChain = await deployedCode(ctx.ethers.provider, address);
  let implementation: string | undefined;
  if (onChain && record.proxy) implementation = await ctx.upgrades.erc1967.getImplementationAddress(record.proxy);
  if (onChain && record.beacon) implementation = await (await ctx.ethers.getContractAt("UpgradeableBeacon", record.beacon)).implementation();
  const implementationCodeHash = implementation ? await (async () => {
    const code = await ctx.ethers.provider.getCode(implementation);
    return code === "0x" ? undefined : ctx.ethers.keccak256(code);
  })() : undefined;
  contracts[name] = {
    address,
    implementation,
    codePresent: onChain,
    implementationMatchesManifest: !record.implementation || implementation === record.implementation,
    implementationCodeHashMatchesManifest: !record.implementationCodeHash
      || implementationCodeHash === record.implementationCodeHash,
  };
}
console.log(JSON.stringify({
  network: ctx.networkName,
  chainId: ctx.chainId,
  owner: manifest.owner,
  rewardToken: manifest.config.rewardToken,
  contracts,
  crossReferences: manifest.config.crossReferences,
  dynamicInstances: manifest.dynamicInstances,
}, null, 2));
if (Object.values(contracts).some((entry) => {
  const status = entry as {
    codePresent: boolean;
    implementationMatchesManifest: boolean;
    implementationCodeHashMatchesManifest: boolean;
  };
  return !status.codePresent || !status.implementationMatchesManifest || !status.implementationCodeHashMatchesManifest;
})) {
  process.exitCode = 1;
}
