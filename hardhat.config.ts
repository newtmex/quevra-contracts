import { defineConfig } from "hardhat/config";
import { loadEnvFile } from "node:process";
import { fileURLToPath } from "node:url";
import hardhatEthers from "@nomicfoundation/hardhat-ethers";
import hardhatMocha from "@nomicfoundation/hardhat-mocha";
import hardhatVerify from "@nomicfoundation/hardhat-verify";
import hardhatUpgrades from "@openzeppelin/hardhat-upgrades";

try {
  loadEnvFile(fileURLToPath(new URL("./.env", import.meta.url)));
} catch (error) {
  if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
}

const privateKey = process.env.DEPLOYER_PRIVATE_KEY;
const accounts = privateKey ? [privateKey] : [];

export default defineConfig({
  plugins: [hardhatEthers, hardhatMocha, hardhatVerify, hardhatUpgrades],
  solidity: {
    version: "0.8.28",
    settings: {
      evmVersion: "cancun",
      optimizer: { enabled: true, runs: 200 },
      viaIR: true,
      metadata: { bytecodeHash: "none", useLiteralContent: true },
    },
  },
  paths: {
    sources: ["./src", "./test/upgrade/contracts"],
    tests: { mocha: "./test/hardhat", solidity: "./test/upgrade/solidity" },
    cache: "./cache/hardhat",
    artifacts: "./artifacts/hardhat",
  },
  networks: {
    local: { type: "edr-simulated", chainId: 31337, chainType: "generic" },
    monadTestnet: {
      type: "http",
      chainType: "generic",
      chainId: 10143,
      url: process.env.MONAD_TESTNET_RPC_URL ?? "http://127.0.0.1:8545",
      accounts,
    },
    solonet: {
      type: "http",
      chainType: "generic",
      chainId: 20143,
      url: process.env.SOLONET_RPC ?? "http://127.0.0.1:48080",
      accounts,
    },
    monadMainnet: {
      type: "http",
      chainType: "generic",
      chainId: 143,
      url: process.env.MONAD_MAINNET_RPC_URL ?? "http://127.0.0.1:8545",
      accounts,
    },
  },
  // Sourcify (MonadVision) is the default no-key path. Monadscan/Etherscan V2 is
  // optional when MONAD_EXPLORER_API_KEY or ETHERSCAN_API_KEY is set.
  // See https://docs.monad.xyz/guides/verify-smart-contract/hardhat and
  // https://github.com/monad-developers/scaffold-monad-hardhat
  verify: {
    etherscan: process.env.MONAD_EXPLORER_API_KEY || process.env.ETHERSCAN_API_KEY
      ? { enabled: true, apiKey: process.env.MONAD_EXPLORER_API_KEY || process.env.ETHERSCAN_API_KEY || "" }
      : { enabled: false },
    sourcify: {
      enabled: true,
      apiUrl: "https://sourcify-api-monad.blockvision.org",
    },
    blockscout: { enabled: false },
  },
  chainDescriptors: {
    10143: {
      name: "MonadTestnet",
      blockExplorers: {
        etherscan: {
          name: "Monadscan",
          url: "https://testnet.monadscan.com",
          apiUrl: "https://api.etherscan.io/v2/api",
        },
      },
    },
    143: {
      name: "MonadMainnet",
      blockExplorers: {
        etherscan: {
          name: "Monadscan",
          url: "https://monadscan.com",
          apiUrl: "https://api.etherscan.io/v2/api",
        },
      },
    },
  },
});
