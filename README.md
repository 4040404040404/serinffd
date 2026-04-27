# Flash Loan Arbitrage Bot — Tutorial

> **Atomic flash-loan arbitrage with Uniswap V4 + Aave V3 leveraged lending**

---

## Table of Contents

1. [Overview](#1-overview)
2. [How It Works](#2-how-it-works)
   - [Atomic Execution Sequence](#atomic-execution-sequence)
   - [Slippage Classification](#slippage-classification)
   - [Aave Leverage Loop](#aave-leverage-loop)
3. [Repository Structure](#3-repository-structure)
4. [Prerequisites](#4-prerequisites)
5. [Installation & Setup](#5-installation--setup)
6. [Configuration](#6-configuration)
7. [Deploying the Contract](#7-deploying-the-contract)
8. [Running the Keeper Bot](#8-running-the-keeper-bot)
9. [Running the Foundry Fork Tests](#9-running-the-foundry-fork-tests)
10. [Key Addresses (Ethereum Mainnet)](#10-key-addresses-ethereum-mainnet)
11. [Security Notes](#11-security-notes)
12. [Glossary](#12-glossary)

---

## 1. Overview

This project implements a fully atomic, zero-fee flash-loan arbitrage strategy:

- **Borrows** a large amount of a token using a **Uniswap V4 flash loan** (no fee — V4 uses delta-accounting instead of the 0.09 % Aave/Balancer fee).
- **Arbitrages** the loan across two Uniswap V3 pools at different fee tiers (e.g. 0.05 % vs 0.3 %) in a single atomic transaction.
- **Extracts profit immediately** — profit is sent to the owner's wallet *before* the optional Aave loop runs, so it can never be lost.
- Optionally **compounds the profit** by depositing the remaining principal into Aave V3, borrowing against it, and running another arbitrage swap — repeated up to `maxLoops` times.
- **Unwinds all Aave positions** and **repays the flash loan** within the same atomic call.
- If any step would result in no profit, the transaction **reverts** — the off-chain bot pre-screens with `eth_call` so no gas is wasted.

```
Bot fires every second
        │
        ▼
executeArbitrage(params)
        │
        ▼
V4 unlock → take(flashAmount)
        │
        ▼
Swap A→B on pool1, B→A on pool2  ← arbitrage
        │
        ├─ profit → owner (immediate)
        │
        ▼
slippage check
  positive ──► Aave supply → borrow → swap → profit → supply → borrow → ... (N loops)
  negative ──► skip (safety)
        │
        ▼
Aave unwind loop (repay → withdraw) × N
        │
        ▼
transfer flashAmount to PoolManager + settle  ← flash loan repaid
        │
        ▼
unlock succeeds, tx confirmed
```

---

## 2. How It Works

### Atomic Execution Sequence

All seven steps happen inside a single Ethereum transaction — they either all succeed or all revert.

| Step | Action |
|------|--------|
| **1** | `poolManager.take(currency, address(this), flashAmount)` — borrow from V4, opening a negative delta |
| **2** | Two-leg cross-pool V3 swap: `tokenIn → tokenOut` on pool A, `tokenOut → tokenIn` on pool B |
| **3** | `profit = amountOut − flashAmount`; if ≤ 0 → revert (bot sees this via `eth_call`) |
| **4** | `transfer(profit, owner)` — profit is safe regardless of later steps |
| **5** | Slippage check → if positive, enter Aave leverage loop |
| **6** | Aave unwind (reverse of loop, recovering all collateral) |
| **7** | `transfer(flashAmount, poolManager)` + `settle()` — zero-fee V4 flash repayment |

### Slippage Classification

The off-chain bot calls **Uniswap V3 QuoterV2** before every transaction to get the expected output (`expectedAmountOut`). This value is passed into the contract as a parameter:

| Condition | Classification | Action |
|-----------|---------------|--------|
| `amountOut > expectedAmountOut` | Positive slippage | Enter Aave leverage loop |
| `amountOut < expectedAmountOut` | Negative slippage | Skip loop (safety) |

**Positive slippage** means someone else's large swap moved the price in your favour between your quote and your execution. You received *more* than expected — the collateral cushion is larger, so it is safe to leverage.

**Negative slippage** means the price moved against you. The Aave loop is skipped entirely so `flashAmount` tokens are guaranteed to be on hand for repayment — no health-factor risk.

### Aave Leverage Loop

When positive slippage is detected, each iteration:

1. Deposits `currentBalance` into Aave as collateral.
2. Borrows `currentBalance × ltvBps / 10000` (e.g. 71.25 % — 95 % of Aave's 75 % cap).
3. Runs another arbitrage swap on the borrowed amount, sending loop profit to owner.
4. Uses the borrowed amount as the new `currentBalance` for the next iteration.

After `maxLoops` iterations (or when `borrowAmount < minProfitableAmount`), the loop unwinds in reverse order: `repay → withdraw` at each level, until the contract holds exactly `flashAmount` again.

Total capital deployed ≈ `flashAmount × 1 / (1 − LTV)`.

---

## 3. Repository Structure

```
.
├── FlashArbitrageBot.sol       # Main on-chain contract
├── AaveLeverageLib.sol         # Supply/borrow/repay loop library
├── interfaces/
│   ├── IAavePool.sol           # Aave V3 IPool subset
│   └── IQuoterV2.sol           # Uniswap V3 QuoterV2 interface
├── keeper.js                   # Off-chain Node.js bot (ethers.js v6)
├── test/
│   └── FlashArbitrageBot.t.sol # Foundry fork test
├── flashloanV4.sol             # Reference: V4 flash loan skeleton
├── ref.sol                     # Reference: V3 cross-pool flash-swap
├── swapuniswapV4.sol           # Reference: V4 direct swap skeleton
└── ref(part2)                  # Reference: Foundry test pattern
```

---

## 4. Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| [Foundry](https://book.getfoundry.sh/getting-started/installation) | latest | Compile & test Solidity |
| [Node.js](https://nodejs.org) | ≥ 18 | Run keeper.js |
| [npm](https://www.npmjs.com/) | ≥ 9 | Install JS dependencies |
| Ethereum mainnet RPC | — | Alchemy / Infura / local Anvil fork |

---

## 5. Installation & Setup

### Solidity (Foundry)

```bash
# Install Foundry (if not already installed)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Clone the repository
git clone https://github.com/4040404040404/serinffd.git
cd serinffd

# Install Foundry dependencies (OpenZeppelin, etc. if added to foundry.toml)
forge install
```

### JavaScript (keeper)

```bash
# Install ethers.js
npm install ethers
```

---

## 6. Configuration

### Contract parameters (set at deploy time)

| Parameter | Type | Description | Recommended |
|-----------|------|-------------|-------------|
| `maxLoops` | `uint8` | Max Aave leverage iterations | 5 – 8 |
| `ltvBps` | `uint256` | LTV in basis points (100 bps = 1 %) | 7125 (= 95 % of Aave's 75 %) |
| `minProfitableAmount` | `uint256` | Minimum borrow size per loop | `1e15` (0.001 tokens) |

**Why 7125 bps?** Aave's DAI/USDC/WETH max LTV is 75 % (7500 bps). Using 95 % of that (7125 bps) keeps the health factor comfortably above 1.0 even if prices move slightly during execution.

### Environment variables (keeper.js)

Copy and fill in the values before running the bot:

```bash
export ETH_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"
export BOT_PRIVATE_KEY="0xYOUR_PRIVATE_KEY"
export BOT_CONTRACT="0xYOUR_DEPLOYED_CONTRACT_ADDRESS"
export MAX_GAS_GWEI="50"      # optional — default 50
export LOG_FILE="profit.log"  # optional — default profit.log
```

> ⚠️ Never commit your private key to version control.

---

## 7. Deploying the Contract

### Using Foundry (forge create)

```bash
forge create FlashArbitrageBot \
  --rpc-url "$ETH_RPC_URL" \
  --private-key "$BOT_PRIVATE_KEY" \
  --constructor-args 6 7125 1000000000000000
  # args: maxLoops=6, ltvBps=7125, minProfitableAmount=1e15
```

The deployer wallet automatically becomes `owner` (receives all profits).

### Optional: transfer ownership

```solidity
// Call from the deploying wallet:
bot.transferOwnership(0xYOurColdWallet);
```

### Rescue tokens

If tokens are accidentally left in the contract (e.g. a partial revert in testing):

```solidity
bot.rescueERC20(tokenAddress, amount);
```

---

## 8. Running the Keeper Bot

```bash
# Set environment variables (see §6)
node keeper.js
```

Expected output:

```
FlashArbitrageBot keeper starting...
  Bot contract : 0xABCD...
  Wallet       : 0x1234...
  Pairs        : DAI/WETH 0.3%→0.05%, DAI/WETH 0.05%→0.3%, ...
  Max gas      : 50 Gwei
  Log file     : profit.log

[Block 20000001] Processing 4 pairs...
[+] DAI/WETH 0.3%→0.05% | profit: 12.340000 | tx: 0xabcd...
[Block 20000001] Done. Total txs: 1 | Cumulative profit: 12.340000
```

### How the bot decides to send a transaction

```
For each candidate pair (every block / every second):
  1. Call QuoterV2.quoteExactInputSingle  →  get expectedAmountOut
  2. bot.executeArbitrage.staticCall(...)  →  simulate on-chain
       ✗ reverts → skip (no gas spent)
       ✓ succeeds → broadcast with maxFeePerGas = baseFee × 1.1 + 1.5 Gwei tip
```

All pairs within the same block are processed with `Promise.all` (parallel). Profit entries are appended to `profit.log` in JSON-Lines format.

### profit.log format

```json
{"ts":"2026-01-01T00:00:00.000Z","pair":"DAI/WETH 0.3%→0.05%","profit":"12340000000000000000","txHash":"0x...","blockNumber":20000001}
```

---

## 9. Running the Foundry Fork Tests

The test manufactures an arbitrage opportunity by dumping 500 WETH into the DAI/WETH 0.3 % pool (imbalancing it relative to the 0.05 % pool), then calls `executeArbitrage` and asserts profit > 0.

```bash
# Run all tests against mainnet fork
forge test \
  --fork-url "$ETH_RPC_URL" \
  --match-path "test/FlashArbitrageBot.t.sol" \
  -vv
```

### Test cases

| Test | What it checks |
|------|---------------|
| `test_executeArbitrage_profitGreaterThanZero` | Happy path — owner balance increases |
| `test_executeArbitrage_negativeSlippage_noRevert` | Safety path — Aave loop skipped, flash loan repaid |
| `test_executeArbitrage_revertsWhenNoProfit` | No-profit gate — transaction reverts cleanly |

---

## 10. Key Addresses (Ethereum Mainnet)

| Contract | Address |
|----------|---------|
| Uniswap V4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Uniswap V3 SwapRouter02 | `0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45` |
| Uniswap V3 QuoterV2 | `0x61fFE014bA17989E743c5F6cB21bF9697530B21e` |
| Aave V3 Pool | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| DAI | `0x6B175474E89094C44Da98b954EedeAC495271d0F` |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| DAI/WETH 0.3 % pool | `0xC2e9F25Be6257c210d7Adf0D4Cd6E3E881ba25f8` |
| DAI/WETH 0.05 % pool | `0x60594a405d53811d3BC4766596EFD80fd545A270` |
| USDC/WETH 0.05 % pool | `0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640` |
| USDC/WETH 0.3 % pool | `0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D5` |

---

## 11. Security Notes

- **Atomic safety** — every step is inside a single `unlockCallback`. If any step reverts (no profit, Aave health factor breach, etc.), the entire transaction reverts and no state changes persist.
- **Access control** — `executeArbitrage` is intentionally open so the bot wallet does not need `owner` privileges. However, only `owner` can call `rescueERC20`, `setMaxLoops`, `setLtvBps`, and `transferOwnership`.
- **No on-chain price dependency** — the contract reverts when `amountOut ≤ flashAmount`. It does not rely on an oracle, so there is no oracle manipulation attack surface.
- **Aave health factor** — using `ltvBps = 7125` (95 % of 7500) leaves a safety margin. Raising `ltvBps` above Aave's true max LTV will cause the borrow call to revert.
- **Private key management** — the bot wallet only needs ETH for gas. Keep profits in a separate cold wallet (use `transferOwnership` to set `owner` to a hardware wallet address).
- **MEV / front-running** — all work happens in a single tx so there is no multi-tx sandwich risk. For extra protection, submit transactions through a private mempool (Flashbots, MEV Blocker).

---

## 12. Glossary

| Term | Meaning |
|------|---------|
| **Flash loan** | A loan that must be repaid within the same transaction. Zero collateral required. |
| **Flash accounting (V4)** | Uniswap V4's mechanism: tokens are debited/credited as deltas and must net to zero by the end of `unlock`. No fee is charged for the borrow itself. |
| **LTV (Loan-to-Value)** | Ratio of the borrowed amount to the collateral value. Aave enforces a per-asset maximum LTV. |
| **Health factor** | Aave's metric: collateral value / debt value (adjusted for liquidation thresholds). Below 1.0 = liquidatable. |
| **Positive slippage** | `amountOut > expectedAmountOut` — market moved in your favour. |
| **Negative slippage** | `amountOut < expectedAmountOut` — market moved against you. |
| **Basis points (bps)** | 1 bps = 0.01 %. 7500 bps = 75 %. |
| **eth_call simulation** | A read-only RPC call that executes a transaction without broadcasting it. Used to check for reverts before spending gas. |
| **Keeper** | An off-chain process that watches conditions and triggers on-chain transactions. |
