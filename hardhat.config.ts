import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import { INFURA_KEY, PRIVATE_KEY } from "./env";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  gasReporter: {
    currency: "USD",
    enabled: false,
  },
  defaultNetwork: "sepolia",
  networks: {
    mainnet: {
      url: `https://sepolia.infura.io/v3/${INFURA_KEY}`,
      chainId: 1,
      accounts: [PRIVATE_KEY],
    },
    sepolia: {
      url: 'https://rpc.sepolia.org',
      chainId: 11155111,
      accounts: [PRIVATE_KEY],
    },
    coverage: {
      url: "http://localhost:8555",
    },
    localhost: {
      url: `http://127.0.0.1:8545`,
    },
  },
  etherscan: {
    apiKey: "2RQ4SD2VG3QWFZXXWHKYBZVQJ6PZ2MIY28",
  }
};

export default config;
