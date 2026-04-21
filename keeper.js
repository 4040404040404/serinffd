#!/usr/bin/env node
/**
 * keeper.js — Off-chain keeper bot for UniswapV4FlashArb
 *
 * What it does
 * ─────────────
 * Calls flashArb() on the deployed UniswapV4FlashArb contract every
 * POLL_INTERVAL_MS milliseconds (default: 1 000 ms = 1 second).
 *
 * Two operating modes (set BLIND_MODE env var):
 *   BLIND_MODE=true   Call flashArb() unconditionally every tick.
 *                     The contract reverts (NoProfit) when no spread exists,
 *                     so the only downside is gas cost per failed attempt.
 *
 *   BLIND_MODE=false  (default) Estimate gas first; skip the call if the
 *                     simulation reverts.  Saves gas on unprofitable ticks.
 *
 * Positive-slippage capture
 * ─────────────────────────
 * The contract uses MIN/MAX sqrt-price limits, so any favourable price
 * movement that occurs between transaction submission and on-chain inclusion
 * is fully captured as additional profit.
 *
 * Prerequisites
 * ─────────────
 *   npm install ethers
 *
 * Environment variables
 * ─────────────────────
 *   RPC_URL          Ethereum JSON-RPC endpoint (required)
 *   PRIVATE_KEY      Keeper wallet private key (required)
 *   ARB_CONTRACT     Deployed UniswapV4FlashArb address (required)
 *   BORROW_TOKEN     Address of the token to borrow (default: DAI)
 *   OUTPUT_TOKEN     Address of the intermediate token (default: WETH)
 *   AMOUNT_IN        Amount of borrowToken in wei (default: 100 DAI = 100e18)
 *   POOL0_FEE        Fee for pool0 in bips (default: 3000)
 *   POOL0_TICK       Tick spacing for pool0 (default: 60)
 *   POOL1_FEE        Fee for pool1 in bips (default: 500)
 *   POOL1_TICK       Tick spacing for pool1 (default: 10)
 *   HOOKS            Hooks address (default: 0x0000...0000)
 *   POLL_INTERVAL_MS Poll interval in ms (default: 1000)
 *   BLIND_MODE       "true" | "false" (default: false)
 *   MAX_GAS_GWEI     Max gas price in gwei to accept (default: 50)
 *
 * Usage
 * ─────
 *   export RPC_URL="https://mainnet.infura.io/v3/<key>"
 *   export PRIVATE_KEY="0x..."
 *   export ARB_CONTRACT="0x..."
 *   node keeper.js
 */

const { ethers } = require("ethers");

// ── Configuration ───────────────────────────────────────────────────────────
const config = {
  rpcUrl:         process.env.RPC_URL          || (() => { throw new Error("RPC_URL required"); })(),
  privateKey:     process.env.PRIVATE_KEY       || (() => { throw new Error("PRIVATE_KEY required"); })(),
  arbContract:    process.env.ARB_CONTRACT      || (() => { throw new Error("ARB_CONTRACT required"); })(),

  // DAI / WETH mainnet defaults
  borrowToken:    process.env.BORROW_TOKEN      || "0x6B175474E89094C44Da98b954EedeAC495271d0F", // DAI
  outputToken:    process.env.OUTPUT_TOKEN      || "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", // WETH
  amountIn:       BigInt(process.env.AMOUNT_IN  || "100000000000000000000"), // 100 DAI

  pool0Fee:       Number(process.env.POOL0_FEE  || 3000),
  pool0Tick:      Number(process.env.POOL0_TICK || 60),
  pool1Fee:       Number(process.env.POOL1_FEE  || 500),
  pool1Tick:      Number(process.env.POOL1_TICK || 10),
  hooks:          process.env.HOOKS             || ethers.ZeroAddress,

  pollIntervalMs: Number(process.env.POLL_INTERVAL_MS || 1000),
  blindMode:     (process.env.BLIND_MODE        || "false") === "true",
  maxGasGwei:     Number(process.env.MAX_GAS_GWEI || 50),
};

// ── ABI (only the functions we need) ────────────────────────────────────────
const ARB_ABI = [
  {
    name: "flashArb",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "pool0",
        type: "tuple",
        components: [
          { name: "currency0",   type: "address" },
          { name: "currency1",   type: "address" },
          { name: "fee",         type: "uint24"  },
          { name: "tickSpacing", type: "int24"   },
          { name: "hooks",       type: "address" },
        ],
      },
      {
        name: "pool1",
        type: "tuple",
        components: [
          { name: "currency0",   type: "address" },
          { name: "currency1",   type: "address" },
          { name: "fee",         type: "uint24"  },
          { name: "tickSpacing", type: "int24"   },
          { name: "hooks",       type: "address" },
        ],
      },
      { name: "borrowToken", type: "address" },
      { name: "outputToken", type: "address" },
      { name: "amountIn",    type: "uint256" },
    ],
    outputs: [],
  },
];

// ── Helpers ──────────────────────────────────────────────────────────────────

/** Build a PoolKey tuple from flat config values. */
function buildPoolKey(fee, tickSpacing) {
  // V4 requires currency0 < currency1 (by address)
  const [currency0, currency1] =
    config.borrowToken.toLowerCase() < config.outputToken.toLowerCase()
      ? [config.borrowToken, config.outputToken]
      : [config.outputToken, config.borrowToken];

  return { currency0, currency1, fee, tickSpacing, hooks: config.hooks };
}

/** Format a BigInt wei value as a human-readable decimal string. */
function fmtWei(wei, decimals = 18) {
  const s = wei.toString().padStart(decimals + 1, "0");
  const int  = s.slice(0, s.length - decimals) || "0";
  const frac = s.slice(s.length - decimals, s.length - decimals + 6);
  return `${int}.${frac}`;
}

// ── Main loop ────────────────────────────────────────────────────────────────
async function main() {
  const provider = new ethers.JsonRpcProvider(config.rpcUrl);
  const wallet   = new ethers.Wallet(config.privateKey, provider);
  const contract = new ethers.Contract(config.arbContract, ARB_ABI, wallet);

  const pool0 = buildPoolKey(config.pool0Fee, config.pool0Tick);
  const pool1 = buildPoolKey(config.pool1Fee, config.pool1Tick);

  console.log("═══════════════════════════════════════════════════════");
  console.log(" UniswapV4FlashArb Keeper");
  console.log("───────────────────────────────────────────────────────");
  console.log(` Contract   : ${config.arbContract}`);
  console.log(` Wallet     : ${wallet.address}`);
  console.log(` BorrowToken: ${config.borrowToken}`);
  console.log(` OutputToken: ${config.outputToken}`);
  console.log(` AmountIn   : ${fmtWei(config.amountIn)} (raw: ${config.amountIn})`);
  console.log(` Pool0      : fee=${pool0.fee} tickSpacing=${pool0.tickSpacing}`);
  console.log(` Pool1      : fee=${pool1.fee} tickSpacing=${pool1.tickSpacing}`);
  console.log(` Interval   : ${config.pollIntervalMs} ms`);
  console.log(` BlindMode  : ${config.blindMode}`);
  console.log(` MaxGasGwei : ${config.maxGasGwei}`);
  console.log("═══════════════════════════════════════════════════════");

  let tick = 0;

  async function attempt() {
    tick++;
    const ts = new Date().toISOString();
    try {
      // ── Gas price guard ──────────────────────────────────────────────
      const feeData = await provider.getFeeData();
      const gasPriceGwei = Number(feeData.gasPrice ?? 0n) / 1e9;
      if (gasPriceGwei > config.maxGasGwei) {
        console.log(`[${ts}] #${tick} SKIP — gas ${gasPriceGwei.toFixed(2)} gwei > max ${config.maxGasGwei}`);
        return;
      }

      const callArgs = [pool0, pool1, config.borrowToken, config.outputToken, config.amountIn];

      // ── Simulation (skip in blind mode) ─────────────────────────────
      if (!config.blindMode) {
        try {
          await contract.flashArb.staticCall(...callArgs);
        } catch (simErr) {
          console.log(`[${ts}] #${tick} SIM_REVERT — ${_shortErr(simErr)}`);
          return;
        }
      }

      // ── Submit transaction ───────────────────────────────────────────
      const tx = await contract.flashArb(...callArgs, {
        gasLimit: 800_000n,
        maxFeePerGas:         feeData.maxFeePerGas,
        maxPriorityFeePerGas: feeData.maxPriorityFeePerGas,
      });
      console.log(`[${ts}] #${tick} SENT     txHash=${tx.hash}`);

      const receipt = await tx.wait();
      if (receipt.status === 1) {
        // Parse ArbExecuted event to log profit
        const iface = new ethers.Interface([
          "event ArbExecuted(address indexed borrowToken, address indexed outputToken, uint256 amountIn, uint256 profit)",
        ]);
        let profitStr = "(unknown)";
        for (const log of receipt.logs) {
          try {
            const parsed = iface.parseLog(log);
            if (parsed && parsed.name === "ArbExecuted") {
              profitStr = `${fmtWei(parsed.args.profit)} borrowToken`;
            }
          } catch (_) { /* not our event */ }
        }
        console.log(`[${ts}] #${tick} PROFIT   ${profitStr}  gas=${receipt.gasUsed}`);
      } else {
        console.log(`[${ts}] #${tick} REVERTED gas=${receipt.gasUsed}`);
      }
    } catch (err) {
      console.error(`[${ts}] #${tick} ERROR    ${_shortErr(err)}`);
    }
  }

  // Run once immediately, then on a fixed interval
  await attempt();
  setInterval(attempt, config.pollIntervalMs);
}

function _shortErr(err) {
  const msg = err?.shortMessage || err?.message || String(err);
  return msg.slice(0, 120);
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});
