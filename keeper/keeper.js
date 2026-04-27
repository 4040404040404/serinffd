/**
 * FlashArbLeverage Keeper
 * ───────────────────────
 * Calls FlashArbLeverage.executeArb() on every new Ethereum block
 * (≈ every 12 seconds on mainnet, ≈ every second on L2s).
 *
 * The contract itself handles the slippage gate — if the arb is
 * unprofitable in a given block the call still succeeds (no principal
 * loss); only gas is spent.
 *
 * Prerequisites:
 *   cd keeper && npm install
 *
 * Configure via ../.env (copy from ../.env.example).
 *
 * Run:
 *   node keeper.js
 */

"use strict";

const { ethers } = require("ethers");
const path       = require("path");
require("dotenv").config({ path: path.resolve(__dirname, "../.env") });

// ── ABI — only the function we need ─────────────────────────────────────────
const ABI = [
  {
    name: "executeArb",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "params",
        type: "tuple",
        components: [
          { name: "tokenIn",     type: "address" },
          { name: "tokenOut",    type: "address" },
          { name: "flashAmount", type: "uint256" },
          { name: "fee0",        type: "uint24"  },
          { name: "fee1",        type: "uint24"  },
          { name: "minProfit",   type: "uint256" },
        ],
      },
    ],
    outputs: [],
  },
];

// ── Env validation ────────────────────────────────────────────────────────────
const required = [
  "ETH_RPC_URL",
  "PRIVATE_KEY",
  "CONTRACT_ADDRESS",
  "TOKEN_IN",
  "TOKEN_OUT",
  "FLASH_AMOUNT",
  "MIN_PROFIT",
  "FEE0",
  "FEE1",
];
for (const k of required) {
  if (!process.env[k]) {
    console.error(`Missing env var: ${k} — copy .env.example to .env and fill it in.`);
    process.exit(1);
  }
}

// ── Setup ─────────────────────────────────────────────────────────────────────
const provider = new ethers.JsonRpcProvider(process.env.ETH_RPC_URL);
const wallet   = new ethers.Wallet(process.env.PRIVATE_KEY, provider);
const contract = new ethers.Contract(process.env.CONTRACT_ADDRESS, ABI, wallet);

const arbParams = {
  tokenIn:     process.env.TOKEN_IN,
  tokenOut:    process.env.TOKEN_OUT,
  flashAmount: BigInt(process.env.FLASH_AMOUNT),
  fee0:        Number(process.env.FEE0),
  fee1:        Number(process.env.FEE1),
  minProfit:   BigInt(process.env.MIN_PROFIT),
};

// ── State ─────────────────────────────────────────────────────────────────────
let busy         = false;  // prevent overlapping calls
let blocksTotal  = 0;
let callsTotal   = 0;
let callsFailed  = 0;

// ── Per-block handler ─────────────────────────────────────────────────────────
async function onBlock(blockNumber) {
  blocksTotal++;

  if (busy) {
    console.log(`[#${blockNumber}] previous tx still pending — skipping`);
    return;
  }

  busy = true;
  callsTotal++;

  console.log(`[#${blockNumber}] sending executeArb …`);
  const t0 = Date.now();

  try {
    const tx = await contract.executeArb(arbParams);
    const receipt = await tx.wait();

    const ms      = Date.now() - t0;
    const gasUsed = receipt.gasUsed.toString();
    console.log(
      `[#${blockNumber}] ✓ mined in block ${receipt.blockNumber} ` +
      `| gasUsed ${gasUsed} | ${ms} ms`
    );
  } catch (err) {
    callsFailed++;
    // Decode revert reason if available
    const reason = err?.reason ?? err?.shortMessage ?? err?.message ?? String(err);
    console.error(`[#${blockNumber}] ✗ tx failed: ${reason}`);
  } finally {
    busy = false;
  }
}

// ── Healthcheck every 100 blocks ─────────────────────────────────────────────
function printStats(blockNumber) {
  if (blocksTotal % 100 === 0) {
    const successRate =
      callsTotal === 0 ? "—" : `${(((callsTotal - callsFailed) / callsTotal) * 100).toFixed(1)}%`;
    console.log(
      `── Stats at block ${blockNumber}: ` +
      `blocks=${blocksTotal} calls=${callsTotal} ` +
      `failed=${callsFailed} successRate=${successRate}`
    );
  }
}

// ── Entry point ───────────────────────────────────────────────────────────────
(async () => {
  console.log("FlashArbLeverage Keeper starting …");
  console.log(`  Contract : ${process.env.CONTRACT_ADDRESS}`);
  console.log(`  Wallet   : ${wallet.address}`);
  console.log(`  tokenIn  : ${arbParams.tokenIn}`);
  console.log(`  tokenOut : ${arbParams.tokenOut}`);
  console.log(`  flash    : ${arbParams.flashAmount.toString()}`);
  console.log(`  fee0/fee1: ${arbParams.fee0} / ${arbParams.fee1}`);

  // Confirm keeper wallet owns the contract before starting
  const contractWithView = new ethers.Contract(
    process.env.CONTRACT_ADDRESS,
    ["function owner() view returns (address)"],
    provider
  );
  const contractOwner = await contractWithView.owner();
  if (contractOwner.toLowerCase() !== wallet.address.toLowerCase()) {
    console.error(
      `Keeper wallet (${wallet.address}) is NOT the contract owner (${contractOwner}). ` +
      `Only the owner can call executeArb.`
    );
    process.exit(1);
  }
  console.log(`  Owner check passed ✓`);

  provider.on("block", (blockNumber) => {
    onBlock(blockNumber).catch(console.error);
    printStats(blockNumber);
  });

  console.log("Listening for new blocks …\n");
})();
