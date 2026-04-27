/**
 * keeper.js — Off-chain arbitrage bot for FlashArbitrageBot
 *
 * Fires FlashArbitrageBot.executeArbitrage every ~1 second (one attempt per block)
 * for each configured token pair without any on-chain opportunity detection.
 *
 * Strategy:
 *   1. For every candidate pair, quote expected output via Uniswap V3 QuoterV2.
 *   2. Simulate the full tx with eth_call — if it reverts, skip (no gas cost).
 *   3. If simulation passes, broadcast the tx with a competitive priority fee.
 *
 * Usage:
 *   npm install ethers
 *   ETH_RPC_URL=https://... BOT_PRIVATE_KEY=0x... BOT_CONTRACT=0x... node keeper.js
 *
 * Environment variables:
 *   ETH_RPC_URL      — Sepolia testnet JSON-RPC URL (e.g. Infura / Alchemy)
 *   BOT_PRIVATE_KEY  — Private key of the wallet that deploys / calls the bot
 *   BOT_CONTRACT     — Deployed FlashArbitrageBot contract address
 *   MAX_GAS_GWEI     — (optional) Maximum gas price in Gwei to accept (default: 50)
 *   LOG_FILE         — (optional) Path to JSON-L profit log (default: profit.log)
 */

"use strict";

const { ethers } = require("ethers");
const fs         = require("fs");
const path       = require("path");

// ─── Configuration ────────────────────────────────────────────────────────────

const RPC_URL      = process.env.ETH_RPC_URL;
const PRIVATE_KEY  = process.env.BOT_PRIVATE_KEY;
const BOT_ADDRESS  = process.env.BOT_CONTRACT;
const MAX_GAS_GWEI = Number(process.env.MAX_GAS_GWEI  || "50");
const LOG_FILE     = process.env.LOG_FILE || path.join(__dirname, "profit.log");

if (!RPC_URL || !PRIVATE_KEY || !BOT_ADDRESS) {
  console.error("Missing required env vars: ETH_RPC_URL, BOT_PRIVATE_KEY, BOT_CONTRACT");
  process.exit(1);
}

// ─── Addresses ───────────────────────────────────────────────────────────────

const WETH = "0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c"; // Sepolia WETH (Aave-wrapped)
const DAI  = "0xFF34B3d4Aee8ddCd6F9AFFFB6Fe49bD371b8a357"; // Sepolia DAI
const USDC = "0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8"; // Sepolia USDC

const QUOTER_V2     = "0xEd1f6473345F45b75833fd55D191EF35014f8154"; // Uniswap V3 QuoterV2 Sepolia
const DAI_WETH_3000 = "0xBBF6c012b8AC4f749a5ED809833e866F152F513f"; // DAI/WETH 0.3 % Sepolia
const DAI_WETH_500  = "0x3861aB2609010f2275646f52Ed88C7ED91377890"; // DAI/WETH 0.05% Sepolia
const USDC_WETH_500 = "0xd37AC323adF2B42ACde752e765feb586Fa9B450F"; // USDC/WETH 0.05% Sepolia
const USDC_WETH_3000= "0x949C25aBE36588EddD6DFA964667c2Db266C43D5"; // USDC/WETH 0.3 % Sepolia

// ─── ABI fragments ───────────────────────────────────────────────────────────

const BOT_ABI = [
  `function executeArbitrage(
    (
      address flashCurrency,
      uint256 flashAmount,
      address pool0,
      uint24  fee1,
      address tokenIn,
      address tokenOut,
      uint256 expectedAmountOut
    ) p
  ) external`,
];

const QUOTER_ABI = [
  `function quoteExactInputSingle(
    (
      address tokenIn,
      address tokenOut,
      uint256 amountIn,
      uint24  fee,
      uint160 sqrtPriceLimitX96
    ) params
  ) external returns (
    uint256 amountOut,
    uint160 sqrtPriceX96After,
    uint32  initializedTicksCrossed,
    uint256 gasEstimate
  )`,
];

// ─── Candidate pairs ─────────────────────────────────────────────────────────
// Each entry defines one arbitrage route: flash-borrow tokenIn, swap on pool0
// (tokenIn → tokenOut), buy back via pool1 at fee1 (tokenOut → tokenIn).

const PAIRS = [
  {
    name:        "DAI/WETH 0.3%→0.05%",
    tokenIn:     DAI,
    tokenOut:    WETH,
    pool0:       DAI_WETH_3000,
    fee1:        500,
    flashAmount: ethers.parseUnits("100000", 18), // 100k DAI
  },
  {
    name:        "DAI/WETH 0.05%→0.3%",
    tokenIn:     DAI,
    tokenOut:    WETH,
    pool0:       DAI_WETH_500,
    fee1:        3000,
    flashAmount: ethers.parseUnits("100000", 18),
  },
  {
    name:        "USDC/WETH 0.05%→0.3%",
    tokenIn:     USDC,
    tokenOut:    WETH,
    pool0:       USDC_WETH_500,
    fee1:        3000,
    flashAmount: ethers.parseUnits("100000", 6),  // 100k USDC
  },
  {
    name:        "USDC/WETH 0.3%→0.05%",
    tokenIn:     USDC,
    tokenOut:    WETH,
    pool0:       USDC_WETH_3000,
    fee1:        500,
    flashAmount: ethers.parseUnits("100000", 6),
  },
];

// ─── Setup ────────────────────────────────────────────────────────────────────

const provider = new ethers.JsonRpcProvider(RPC_URL);
const wallet   = new ethers.Wallet(PRIVATE_KEY, provider);
const bot      = new ethers.Contract(BOT_ADDRESS, BOT_ABI, wallet);
const quoter   = new ethers.Contract(QUOTER_V2, QUOTER_ABI, provider);

let totalProfit = 0n;
let txCount     = 0;

// ─── Helpers ──────────────────────────────────────────────────────────────────

function logProfit(pair, profit, txHash, blockNumber) {
  const entry = {
    ts:          new Date().toISOString(),
    pair:        pair.name,
    profit:      profit.toString(),
    txHash,
    blockNumber,
  };
  fs.appendFileSync(LOG_FILE, JSON.stringify(entry) + "\n");
  console.log(`[+] ${pair.name} | profit: ${ethers.formatUnits(profit, 18)} | tx: ${txHash}`);
}

/// Quote expected output for tokenIn → tokenOut on pool's fee tier.
async function quoteExpected(pair) {
  try {
    const [amountOut] = await quoter.quoteExactInputSingle.staticCall({
      tokenIn:           pair.tokenIn,
      tokenOut:          pair.tokenOut,
      amountIn:          pair.flashAmount,
      fee:               pair.fee1,
      sqrtPriceLimitX96: 0n,
    });
    return amountOut;
  } catch {
    return 0n;
  }
}

/// Build the ArbitrageParams struct for the contract call.
function buildParams(pair, expectedAmountOut) {
  return {
    flashCurrency:     pair.tokenIn,
    flashAmount:       pair.flashAmount,
    pool0:             pair.pool0,
    fee1:              pair.fee1,
    tokenIn:           pair.tokenIn,
    tokenOut:          pair.tokenOut,
    expectedAmountOut,
  };
}

/// Simulate the tx via eth_call.  Returns true if it would succeed.
async function simulate(params) {
  try {
    await bot.executeArbitrage.staticCall(params);
    return true;
  } catch {
    return false;
  }
}

/// Send the real transaction with a competitive EIP-1559 fee.
async function sendTx(params, feeData) {
  const maxFeePerGas      = feeData.maxFeePerGas
    ? feeData.maxFeePerGas * 110n / 100n  // 10% above base fee estimate
    : ethers.parseUnits(String(MAX_GAS_GWEI), "gwei");
  const maxPriorityFeePerGas = ethers.parseUnits("1.5", "gwei");

  const tx = await bot.executeArbitrage(params, {
    maxFeePerGas,
    maxPriorityFeePerGas,
  });
  return tx;
}

// ─── Per-block processing ─────────────────────────────────────────────────────

async function processPair(pair, feeData, blockNumber) {
  // 1. Quote expected output
  const expectedAmountOut = await quoteExpected(pair);
  const params            = buildParams(pair, expectedAmountOut);

  // 2. Simulate
  const ok = await simulate(params);
  if (!ok) return; // would revert — skip, no gas cost

  // 3. Gas price sanity check
  const gasPriceGwei = Number(ethers.formatUnits(feeData.maxFeePerGas ?? 0n, "gwei"));
  if (gasPriceGwei > MAX_GAS_GWEI) {
    console.log(`[!] Gas too high (${gasPriceGwei.toFixed(1)} Gwei), skipping ${pair.name}`);
    return;
  }

  // 4. Broadcast
  try {
    const tx      = await sendTx(params, feeData);
    const receipt = await tx.wait(1);

    if (receipt && receipt.status === 1) {
      txCount++;
      // Profit is emitted in ArbitrageExecuted event — parse it
      const iface = new ethers.Interface([
        "event ArbitrageExecuted(address indexed tokenIn, uint256 flashAmount, uint256 arbProfit, uint256 loopProfit, uint8 loopsExecuted)",
      ]);
      let profit = 0n;
      for (const log of receipt.logs) {
        try {
          const parsed = iface.parseLog(log);
          if (parsed && parsed.name === "ArbitrageExecuted") {
            profit = parsed.args.arbProfit + parsed.args.loopProfit;
          }
        } catch { /* not our event */ }
      }
      totalProfit += profit;
      logProfit(pair, profit, receipt.hash, blockNumber);
    }
  } catch (err) {
    // tx reverted on-chain (race condition — price moved between simulation and mining)
    console.log(`[-] ${pair.name} | tx reverted: ${err.shortMessage ?? err.message}`);
  }
}

// ─── Main loop ────────────────────────────────────────────────────────────────

async function onBlock(blockNumber) {
  console.log(`\n[Block ${blockNumber}] Processing ${PAIRS.length} pairs...`);

  let feeData;
  try {
    feeData = await provider.getFeeData();
  } catch {
    return; // skip this block on RPC error
  }

  // Fire all pairs concurrently within the same block
  await Promise.all(PAIRS.map(pair => processPair(pair, feeData, blockNumber)));

  console.log(
    `[Block ${blockNumber}] Done. Total txs: ${txCount} | Cumulative profit: ${ethers.formatUnits(totalProfit, 18)}`
  );
}

// ─── Entry ────────────────────────────────────────────────────────────────────

(async () => {
  console.log(`FlashArbitrageBot keeper starting...`);
  console.log(`  Bot contract : ${BOT_ADDRESS}`);
  console.log(`  Wallet       : ${wallet.address}`);
  console.log(`  Pairs        : ${PAIRS.map(p => p.name).join(", ")}`);
  console.log(`  Max gas      : ${MAX_GAS_GWEI} Gwei`);
  console.log(`  Log file     : ${LOG_FILE}\n`);

  // Subscribe to new blocks (fires approx. every 12 s on Sepolia)
  provider.on("block", onBlock);

  // Also fire on a 1-second interval for faster reaction on L2 / custom chains
  setInterval(async () => {
    try {
      const blockNumber = await provider.getBlockNumber();
      await onBlock(blockNumber);
    } catch { /* ignore */ }
  }, 1_000);
})();
