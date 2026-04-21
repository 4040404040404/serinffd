/**
 * bot.js — Off-chain arbitrage runner for UniswapV4FlashArbitrage.sol
 *
 * Polls two Uniswap V4 pools every second, estimates the profit of a flash-arb
 * between them, and fires a transaction when the opportunity is net-profitable
 * after gas costs.
 *
 * Requirements:
 *   npm install ethers
 *
 * Usage:
 *   ARB_CONTRACT=0x...  \
 *   PRIVATE_KEY=0x...   \
 *   RPC_URL=https://...  \
 *   node bot.js
 */

"use strict";

const { ethers } = require("ethers");

// ── Configuration ─────────────────────────────────────────────────────────────

const RPC_URL      = process.env.RPC_URL      || "https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY";
const PRIVATE_KEY  = process.env.PRIVATE_KEY  || "0xYOUR_PRIVATE_KEY";
const ARB_CONTRACT = process.env.ARB_CONTRACT || "0xYOUR_DEPLOYED_CONTRACT";

const POOL_MANAGER = "0x000000000004444c5dc75cB358380D2e3dE08A90";

// Decimals of the token being borrowed and profited in (TOKEN_IN).
// Adjust to match the actual token — WETH is 18, USDC is 6, etc.
const TOKEN_IN_DECIMALS = 18;

// Flash-borrow size expressed in TOKEN_IN units.
// Tune this based on available pool liquidity to maximise profit.
const BORROW_AMOUNT = ethers.parseUnits("1", TOKEN_IN_DECIMALS); // e.g. 1 WETH

// Minimum profit in TOKEN_IN units after estimated gas before firing a tx.
const MIN_PROFIT_WEI = ethers.parseUnits("0.001", TOKEN_IN_DECIMALS); // e.g. 0.001 WETH

// Polling interval in milliseconds.
const POLL_INTERVAL_MS = 1000; // 1 second

// ── Pool configuration ────────────────────────────────────────────────────────
//
// Fill in the two pools you want to arb between.
// currency0 MUST be the lexicographically smaller address (V4 invariant).
// Both pools must share the same tokenIn / tokenOut pair.
//
// Example: WETH/USDC 0.05% vs WETH/USDC 0.3%

const WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";

// currency0 < currency1 by address value
const [CURRENCY0, CURRENCY1] = [WETH, USDC].sort((a, b) =>
  a.toLowerCase() < b.toLowerCase() ? -1 : 1
);

const pool0Key = {
  currency0: CURRENCY0,
  currency1: CURRENCY1,
  fee: 500,          // 0.05%
  tickSpacing: 10,
  hooks: ethers.ZeroAddress,
};

const pool1Key = {
  currency0: CURRENCY0,
  currency1: CURRENCY1,
  fee: 3000,         // 0.30%
  tickSpacing: 60,
  hooks: ethers.ZeroAddress,
};

// tokenIn: the token we borrow and profit in
// tokenOut: the intermediate token
const TOKEN_IN  = WETH;
const TOKEN_OUT = USDC;

// ── ABIs ──────────────────────────────────────────────────────────────────────

const POOL_MANAGER_ABI = [
  // getSlot0 returns the current sqrt price and tick for a pool.
  // The poolId is keccak256(abi.encode(PoolKey)).
  "function getSlot0(bytes32 id) external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)",
];

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

/**
 * Convert a sqrtPriceX96 value to a human-readable price ratio.
 * price = (sqrtPriceX96 / 2^96)^2
 */
function sqrtPriceToPrice(sqrtPriceX96) {
  const Q96 = 2n ** 96n;
  const ratio = (sqrtPriceX96 * sqrtPriceX96) / (Q96 * Q96);
  return ratio;
}

/**
 * Estimate the output of an exact-input swap using the constant-product
 * approximation: amountOut ≈ amountIn * price / (1 + fee/1e6).
 *
 * This is a rough estimate for opportunity detection only — the actual on-chain
 * swap result will differ due to price impact.
 */
function estimateAmountOut(sqrtPriceX96, amountIn, zeroForOne, feePips) {
  const Q96 = 2n ** 96n;
  // price = token1 per token0
  const numerator   = sqrtPriceX96 * sqrtPriceX96;
  const denominator = Q96 * Q96;

  let amountOut;
  if (zeroForOne) {
    // selling token0 for token1: amountOut = amountIn * price
    amountOut = (BigInt(amountIn) * numerator) / denominator;
  } else {
    // selling token1 for token0: amountOut = amountIn / price
    amountOut = (BigInt(amountIn) * denominator) / numerator;
  }

  // Deduct the pool fee
  amountOut = (amountOut * BigInt(1e6 - feePips)) / BigInt(1e6);
  return amountOut;
}

// ── Main loop ─────────────────────────────────────────────────────────────────

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet   = new ethers.Wallet(PRIVATE_KEY, provider);

  const pmContract  = new ethers.Contract(POOL_MANAGER, POOL_MANAGER_ABI, provider);
  const arbContract = new ethers.Contract(ARB_CONTRACT, ARB_ABI, wallet);

  const id0 = poolId(pool0Key);
  const id1 = poolId(pool1Key);

  const zeroForOne0 = TOKEN_IN.toLowerCase() === CURRENCY0.toLowerCase();
  // On pool1 we INPUT tokenOut and OUTPUT tokenIn.
  // zeroForOne means "are we selling currency0?", so we check the INPUT side (TOKEN_OUT).
  const zeroForOne1 = TOKEN_OUT.toLowerCase() === CURRENCY0.toLowerCase();

  console.log(`Arb bot started. Polling every ${POLL_INTERVAL_MS} ms.`);
  console.log(`pool0 id: ${id0}`);
  console.log(`pool1 id: ${id1}`);

  let lastNonce = await provider.getTransactionCount(wallet.address, "latest");

  async function tick() {
    try {
      // Fetch current sqrt prices from both pools in parallel.
      const [slot0_0, slot0_1] = await Promise.all([
        pmContract.getSlot0(id0),
        pmContract.getSlot0(id1),
      ]);

      const sqrtPrice0 = slot0_0.sqrtPriceX96;
      const sqrtPrice1 = slot0_1.sqrtPriceX96;

      // Estimate: borrow BORROW_AMOUNT of tokenIn, swap to tokenOut on pool0,
      // swap back to tokenIn on pool1.
      const amountOut0 = estimateAmountOut(
        sqrtPrice0, BORROW_AMOUNT, zeroForOne0, pool0Key.fee
      );
      const amountBack = estimateAmountOut(
        sqrtPrice1, amountOut0, zeroForOne1, pool1Key.fee
      );

      const estimatedProfit = amountBack - BigInt(BORROW_AMOUNT);

      console.log(
        `[${new Date().toISOString()}] ` +
        `sqrtP0=${sqrtPrice0} sqrtP1=${sqrtPrice1} ` +
        `est. profit=${ethers.formatUnits(estimatedProfit, TOKEN_IN_DECIMALS)} tokenIn`
      );

      if (estimatedProfit <= 0n) return; // not profitable, skip

      // Rough gas estimate: flash arb typically uses ~300k gas.
      const feeData     = await provider.getFeeData();
      const gasPrice    = feeData.maxFeePerGas ?? feeData.gasPrice ?? 0n;
      const gasLimit    = 350000n;
      const gasCostWei  = gasPrice * gasLimit;

      if (estimatedProfit < gasCostWei + MIN_PROFIT_WEI) {
        console.log("  ↳ opportunity below min-profit threshold after gas, skipping.");
        return;
      }

      console.log(`  ↳ FIRING TRANSACTION (est. profit ${ethers.formatUnits(estimatedProfit, TOKEN_IN_DECIMALS)})`);

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
