/**
 * bot.js — Unconditional flash-arb executor for UniswapV4FlashArbitrage.sol
 *
 * Fires flashArb every second without any off-chain profit estimation.
 * The on-chain contract reverts with NoProfit() when there is nothing to earn,
 * so no money is ever lost on unprofitable rounds — only gas.
 *
 * Supported networks (set via NETWORK env var):
 *   mainnet  — Ethereum mainnet  (default)
 *   sepolia  — Sepolia testnet   (for testing)
 *
 * Requirements:
 *   npm install ethers
 *
 * Usage:
 *   NETWORK=sepolia          \
 *   ARB_CONTRACT=0x...       \
 *   PRIVATE_KEY=0x...        \
 *   RPC_URL=https://...      \
 *   node bot.js
 */

"use strict";

const { ethers } = require("ethers");

// ── Network presets ───────────────────────────────────────────────────────────
//
// Each preset provides:
//   poolManager  – V4 PoolManager address on that network
//   weth         – Wrapped-ether token address
//   usdc         – USD-denominated stablecoin address
//   pool0Fee     – Fee tier (in pips) for pool0
//   pool0Tick    – tickSpacing matching pool0Fee
//   pool1Fee     – Fee tier (in pips) for pool1
//   pool1Tick    – tickSpacing matching pool1Fee
//   defaultRpc   – Fallback RPC when RPC_URL is not set
//
// WETH/USDC 0.05 % vs 0.30 % is used as the example arb pair on both networks.
// Replace with whichever pair has sufficient liquidity on Sepolia.

const NETWORK_PRESETS = {
  mainnet: {
    poolManager: "0x000000000004444c5dc75cB358380D2e3dE08A90",
    weth:        "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
    usdc:        "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    pool0Fee:    500,   pool0Tick: 10,
    pool1Fee:    3000,  pool1Tick: 60,
    defaultRpc:  "https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY",
  },
  sepolia: {
    // V4 PoolManager on Sepolia (Uniswap official deployment)
    poolManager: "0x8C4BcBE6b9eF47855f97E675296FA3F6fafa5F1A",
    // Uniswap-wrapped WETH on Sepolia
    weth:        "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14",
    // Circle USDC on Sepolia
    usdc:        "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
    pool0Fee:    500,   pool0Tick: 10,
    pool1Fee:    3000,  pool1Tick: 60,
    defaultRpc:  "https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY",
  },
};

// ── Configuration ─────────────────────────────────────────────────────────────

const NETWORK     = process.env.NETWORK      || "sepolia";
const preset      = NETWORK_PRESETS[NETWORK];
if (!preset) {
  console.error(`Unknown NETWORK="${NETWORK}". Valid options: ${Object.keys(NETWORK_PRESETS).join(", ")}`);
  process.exit(1);
}

const RPC_URL      = process.env.RPC_URL      || preset.defaultRpc;
const PRIVATE_KEY  = process.env.PRIVATE_KEY  || "0xYOUR_PRIVATE_KEY";
const ARB_CONTRACT = process.env.ARB_CONTRACT || "0xYOUR_DEPLOYED_CONTRACT";

// Flash-borrow size expressed in TOKEN_IN units (WETH, 18 decimals).
// Tune this based on available pool liquidity.
// Use a small amount on testnet (0.01 WETH) to reduce faucet pressure.
const BORROW_AMOUNT = NETWORK === "mainnet"
  ? ethers.parseUnits("1",    18)   // 1 WETH on mainnet
  : ethers.parseUnits("0.01", 18);  // 0.01 WETH on testnet

// Execution interval in milliseconds.
const POLL_INTERVAL_MS = 1000; // 1 second

// ── Pool configuration ────────────────────────────────────────────────────────
//
// currency0 MUST be the lexicographically smaller address (V4 invariant).
// Both pools must share the same tokenIn / tokenOut pair.

const WETH = preset.weth;
const USDC = preset.usdc;

// Sort to satisfy V4's canonical currency0 < currency1 ordering.
const [CURRENCY0, CURRENCY1] = [WETH, USDC].sort((a, b) =>
  a.toLowerCase() < b.toLowerCase() ? -1 : 1
);

const pool0Key = {
  currency0:   CURRENCY0,
  currency1:   CURRENCY1,
  fee:         preset.pool0Fee,
  tickSpacing: preset.pool0Tick,
  hooks:       ethers.ZeroAddress,
};

const pool1Key = {
  currency0:   CURRENCY0,
  currency1:   CURRENCY1,
  fee:         preset.pool1Fee,
  tickSpacing: preset.pool1Tick,
  hooks:       ethers.ZeroAddress,
};

// tokenIn: the token we borrow and profit in
// tokenOut: the intermediate token
const TOKEN_IN  = WETH;
const TOKEN_OUT = USDC;

// ── ABIs ──────────────────────────────────────────────────────────────────────

// PoolKey tuple type used throughout the ABI.
const POOL_KEY_TYPE = "(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)";

const ARB_ABI = [
  `function flashArb(${POOL_KEY_TYPE} pool0Key, ${POOL_KEY_TYPE} pool1Key, address tokenIn, address tokenOut, uint256 amount) external`,
];

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * Compute the V4 poolId (bytes32) for a given PoolKey.
 * Matches keccak256(abi.encode(currency0, currency1, fee, tickSpacing, hooks)).
 */
function poolId(key) {
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "address", "uint24", "int24", "address"],
      [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks]
    )
  );
}

// ── Main loop ─────────────────────────────────────────────────────────────────

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet   = new ethers.Wallet(PRIVATE_KEY, provider);

  const arbContract = new ethers.Contract(ARB_CONTRACT, ARB_ABI, wallet);

  const id0 = poolId(pool0Key);
  const id1 = poolId(pool1Key);

  console.log(`Arb bot started. Firing flashArb every ${POLL_INTERVAL_MS} ms (no detection).`);
  console.log(`pool0 id: ${id0}`);
  console.log(`pool1 id: ${id1}`);

  let lastNonce = await provider.getTransactionCount(wallet.address, "latest");

  async function tick() {
    try {
      const feeData = await provider.getFeeData();
      const gasLimit = 350000n;

      console.log(`[${new Date().toISOString()}] Firing flashArb…`);

      const tx = await arbContract.flashArb(
        pool0Key,
        pool1Key,
        TOKEN_IN,
        TOKEN_OUT,
        BORROW_AMOUNT,
        {
          gasLimit,
          maxFeePerGas:         feeData.maxFeePerGas,
          maxPriorityFeePerGas: feeData.maxPriorityFeePerGas,
          nonce: lastNonce,
        }
      );

      lastNonce += 1;
      console.log(`  ↳ tx sent: ${tx.hash}`);

      // Wait for confirmation in the background so the next tick is not blocked.
      tx.wait(1).then((receipt) => {
        console.log(
          `  ↳ confirmed in block ${receipt.blockNumber} ` +
          `(status=${receipt.status === 1 ? "success" : "reverted"})`
        );
      }).catch((err) => {
        console.error(`  ↳ tx wait error: ${err.message}`);
        // Resync nonce if the tx was rejected/dropped.
        provider.getTransactionCount(wallet.address, "latest").then((n) => {
          lastNonce = n;
        });
      });
    } catch (err) {
      console.error(`tick error: ${err.message}`);
      // Resync nonce on send failure (e.g. nonce too low).
      provider.getTransactionCount(wallet.address, "latest").then((n) => {
        lastNonce = n;
      }).catch(() => {});
    }
  }

  // Run immediately, then on every POLL_INTERVAL_MS.
  tick();
  setInterval(tick, POLL_INTERVAL_MS);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
