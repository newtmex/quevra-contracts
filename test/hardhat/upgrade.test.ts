import { strict as assert } from "node:assert";
import { describe, it } from "mocha";
import hre from "hardhat";
import { upgrades } from "@openzeppelin/hardhat-upgrades";

describe("UUPS and Beacon deployment safety", () => {
  it("keeps controller state and proxy address through an authorized UUPS upgrade", async () => {
    const connection = await hre.network.create();
    const { ethers } = connection;
    const upgradesApi = await upgrades(hre, connection);
    const [owner, stranger] = await ethers.getSigners();
    const vaultImplementation = await (await ethers.getContractFactory("StakingVault")).deploy();
    await vaultImplementation.waitForDeployment();
    const agentImplementation = await (await ethers.getContractFactory("StakingAgent")).deploy();
    await agentImplementation.waitForDeployment();
    const Beacon = await ethers.getContractFactory("UpgradeableBeaconTestArtifact");
    const vaultBeacon = await Beacon.deploy(await vaultImplementation.getAddress(), await owner.getAddress());
    const agentBeacon = await Beacon.deploy(await agentImplementation.getAddress(), await owner.getAddress());
    await Promise.all([vaultBeacon.waitForDeployment(), agentBeacon.waitForDeployment()]);

    const Controller = await ethers.getContractFactory("StakingController");
    const controller = await upgradesApi.deployProxy(
      Controller,
      [await owner.getAddress(), 0, await vaultBeacon.getAddress(), await agentBeacon.getAddress()],
      { kind: "uups", initializer: "initialize" },
    );
    const proxyAddress = await controller.getAddress();
    const mockVe = await (await ethers.getContractFactory("NotAControllerImplementation")).deploy();
    await mockVe.waitForDeployment();
    await (await controller.setVe(await mockVe.getAddress())).wait();
    const V2 = await ethers.getContractFactory("StakingControllerV2");
    const upgraded = await upgradesApi.upgradeProxy(proxyAddress, V2, { kind: "uups" });
    assert.equal(await upgraded.getAddress(), proxyAddress);
    assert.equal(await upgraded.ve(), await mockVe.getAddress());
    assert.equal(await upgraded.implementationVersion(), 2n);

    const unauthorized = controller.connect(stranger);
    const unauthorizedUpgrade = unauthorized.getFunction("upgradeToAndCall");
    const currentImplementation = await upgradesApi.erc1967.getImplementationAddress(proxyAddress);
    await assert.rejects(() => unauthorizedUpgrade(currentImplementation, "0x"));
    await assert.rejects(async () => upgradesApi.validateUpgrade(
      proxyAddress,
      await ethers.getContractFactory("NotAControllerImplementation"),
      { kind: "uups" },
    ));
  });

  it("upgrades all Beacon instances while preserving their distinct state", async () => {
    const connection = await hre.network.create();
    const { ethers } = connection;
    const upgradesApi = await upgrades(hre, connection);
    const [owner] = await ethers.getSigners();
    const Vault = await ethers.getContractFactory("StakingVault");
    const beacon = await upgradesApi.deployBeacon(Vault, { initialOwner: await owner.getAddress() });
    const beaconAddress = await beacon.getAddress();
    const BeaconProxyFactory = await ethers.getContractFactory("BeaconProxyTestArtifact");
    const proxyA = await BeaconProxyFactory.deploy(beaconAddress, "0x");
    const proxyB = await BeaconProxyFactory.deploy(beaconAddress, "0x");
    await Promise.all([proxyA.waitForDeployment(), proxyB.waitForDeployment()]);
    const aAddress = await proxyA.getAddress();
    const bAddress = await proxyB.getAddress();
    const vaultA = Vault.attach(aAddress);
    const vaultB = Vault.attach(bAddress);
    const validatorVe = await (await ethers.getContractFactory("NotAControllerImplementation")).deploy();
    await validatorVe.waitForDeployment();
    await (await vaultA.initialize(await owner.getAddress(), await validatorVe.getAddress(), 11, 0)).wait();
    await (await vaultB.initialize(await owner.getAddress(), await validatorVe.getAddress(), 22, 0)).wait();

    const V2 = await ethers.getContractFactory("StakingVaultV2");
    await upgradesApi.upgradeBeacon(beaconAddress, V2);
    const upgradedA = V2.attach(aAddress);
    const upgradedB = V2.attach(bAddress);
    assert.equal(await upgradedA.getAddress(), aAddress);
    assert.equal(await upgradedB.getAddress(), bAddress);
    assert.equal(await upgradedA.validatorTokenId(), 11n);
    assert.equal(await upgradedB.validatorTokenId(), 22n);
    assert.equal(await upgradedA.implementationVersion(), 2n);
    assert.equal(await upgradedB.implementationVersion(), 2n);
  });
});
