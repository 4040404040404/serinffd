/**
 * deploy.js — Deploy UniswapV4FlashArbitrage to any network
 *
 * Requirements:
 *   npm install ethers solc
 *
 * Usage:
 *   # Deploy to Sepolia testnet
 *   NETWORK=sepolia  \
 *   PRIVATE_KEY=0x... \
 *   RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY \
 *   node deploy.js
 *
 *   # Deploy to Ethereum mainnet
 *   NETWORK=mainnet  \
 *   PRIVATE_KEY=0x... \
 *   RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY \
 *   node deploy.js
 *
 * The deployed contract address is printed on success and can be passed directly
 * to bot.js via ARB_CONTRACT=<address>.
 *
 * Note: This script compiles the contract at runtime using solc-js.
 *       For a production setup consider Hardhat or Foundry instead.
 */

"use strict";

const fs      = require("fs");
const path    = require("path");
const { ethers } = require("ethers");
const solc    = require("solc");

// ── Network presets (mirrors bot.js) ─────────────────────────────────────────

const NETWORK_PRESETS = {
  mainnet: {
    poolManager: "0x000000000004444c5dc75cB358380D2e3dE08A90",
    defaultRpc:  "https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY",
    chainId:     1,
  },
  sepolia: {
    // V4 PoolManager on Sepolia (Uniswap official deployment)
    poolManager: "0x8C4BcBE6b9eF47855f97E675296FA3F6fafa5F1A",
    defaultRpc:  "https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY",
    chainId:     11155111,
  },
};

// ── Configuration ─────────────────────────────────────────────────────────────

const NETWORK    = process.env.NETWORK     || "sepolia";
const preset     = NETWORK_PRESETS[NETWORK];
if (!preset) {
  console.error(`Unknown NETWORK="${NETWORK}". Valid: ${Object.keys(NETWORK_PRESETS).join(", ")}`);
  process.exit(1);
}

const RPC_URL     = process.env.RPC_URL    || preset.defaultRpc;
const PRIVATE_KEY = process.env.PRIVATE_KEY;
if (!PRIVATE_KEY) {
  console.error("PRIVATE_KEY env var is required.");
  process.exit(1);
}

// ── Compile ───────────────────────────────────────────────────────────────────

const CONTRACT_FILE = "UniswapV4FlashArbitrage.sol";
const CONTRACT_NAME = "UniswapV4FlashArbitrage";

function compile() {
  const contractPath = path.resolve(__dirname, CONTRACT_FILE);
  const source       = fs.readFileSync(contractPath, "utf8");

  const input = {
    language: "Solidity",
    sources:  { [CONTRACT_FILE]: { content: source } },
    settings: {
      optimizer: { enabled: true, runs: 200 },
      outputSelection: { "*": { "*": ["abi", "evm.bytecode"] } },
    },
  };

  console.log(`Compiling ${CONTRACT_FILE}…`);
  const output = JSON.parse(solc.compile(JSON.stringify(input)));

  const errors = (output.errors || []).filter((e) => e.severity === "error");
  if (errors.length) {
    errors.forEach((e) => console.error(e.formattedMessage));
    throw new Error("Compilation failed.");
  }
  const warnings = (output.errors || []).filter((e) => e.severity === "warning");
  warnings.forEach((w) => console.warn("  WARN:", w.formattedMessage));

  const contract = output.contracts[CONTRACT_FILE][CONTRACT_NAME];
  if (!contract) throw new Error(`Contract "${CONTRACT_NAME}" not found in output.`);

  return {
    abi:      contract.abi,
    bytecode: "0x" + contract.evm.bytecode.object,
  };
}

// ── Deploy ────────────────────────────────────────────────────────────────────

async function deploy() {
  const { abi, bytecode } = compile();

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet   = new ethers.Wallet(PRIVATE_KEY, provider);

  // Verify we are on the intended chain.
  const { chainId } = await provider.getNetwork();
  if (Number(chainId) !== preset.chainId) {
    throw new Error(
      `Chain ID mismatch: RPC returned ${chainId}, expected ${preset.chainId} for "${NETWORK}".`
    );
  }

  console.log(`Network  : ${NETWORK} (chainId ${chainId})`);
  console.log(`Deployer : ${wallet.address}`);
  console.log(`PoolMgr  : ${preset.poolManager}`);

  const balance = await provider.getBalance(wallet.address);
  console.log(`Balance  : ${ethers.formatEther(balance)} ETH`);
  if (balance === 0n) {
    throw new Error("Deployer balance is 0. Fund the wallet first (use a faucet on testnet).");
  }

  const factory = new ethers.ContractFactory(abi, bytecode, wallet);

  console.log("Deploying…");
  const contract = await factory.deploy(preset.poolManager);
  console.log(`Tx hash  : ${contract.deploymentTransaction().hash}`);

  const receipt = await contract.deploymentTransaction().wait(1);
  const address = await contract.getAddress();

  console.log(`\n✅  Contract deployed at: ${address}`);
  console.log(`    Block: ${receipt.blockNumber}`);
  console.log(`\nNext step — start the bot:`);
  console.log(`  NETWORK=${NETWORK} ARB_CONTRACT=${address} PRIVATE_KEY=0x... RPC_URL=... node bot.js`);

  return address;
}

deploy().catch((err) => {
  console.error("\n❌ Deployment failed:", err.message);
  process.exit(1);
});
