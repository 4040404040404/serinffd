# Uniswap V4 Flash-Loan Arbitrage

A complete, zero-capital arbitrage system built on **Uniswap V4**.  
Borrow any token for free inside a single transaction, exploit price differences between two V4 pools, and pocket the profit — all atomically, with automatic revert if no profit is found.

---

## Table of Contents

1. [How it works](#1-how-it-works)
2. [Repository overview](#2-repository-overview)
3. [Network addresses](#3-network-addresses)
4. [Prerequisites](#4-prerequisites)
5. [Quick-start on Sepolia testnet](#5-quick-start-on-sepolia-testnet)
6. [Deploy to mainnet](#6-deploy-to-mainnet)
7. [Run the arb bot](#7-run-the-arb-bot)
8. [Contract reference](#8-contract-reference)
9. [V3 → V4 differences](#9-v3--v4-differences)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. How it works

The bot fires `flashArb` unconditionally every second. The contract handles the no-profit case:

```
bot (every 1 s)  ──►  flashArb()
                           │
                           ▼ (on-chain, atomic)
                   unlockCallback()
                       ├─ borrow tokenIn
                       ├─ swap pool0: tokenIn → tokenOut
                       ├─ swap pool1: tokenOut → tokenIn
                       ├─ amountBack > amount?  ✓ transfer profit
                       └─ amountBack ≤ amount?  ✗ revert NoProfit()
```

**Key insight — V4 flash loans are free.**  
Uniswap V4 uses *flash accounting*: the PoolManager tracks token deltas per callback session. As long as all deltas reach zero before `unlockCallback` returns, no fee is charged for the borrow itself. You only pay the normal swap fees on the two trades.

---

## 2. Repository overview

| File | Purpose |
|---|---|
| `UniswapV4FlashArbitrage.sol` | Main arbitrage contract — deploy this |
| `flashloanV4.sol` | Minimal standalone V4 flash-loan example |
| `swapuniswapV4.sol` | Standalone V4 exact-input swap example |
| `ref.sol` | Reference: equivalent Uniswap **V3** flash-swap (for comparison) |
| `ref(part2)` | Forge test for the V3 reference contract |
| `deploy.js` | Compile + deploy `UniswapV4FlashArbitrage` (mainnet or testnet) |
| `bot.js` | Off-chain executor — fires `flashArb` unconditionally every second |

---

## 3. Network addresses

### Ethereum Mainnet (chainId 1)

| Contract | Address |
|---|---|
| V4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |

### Sepolia Testnet (chainId 11155111)

| Contract | Address |
|---|---|
| V4 PoolManager | `0x8C4BcBE6b9eF47855f97E675296FA3F6fafa5F1A` |
| WETH | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` |
| USDC | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` |

---

## 4. Prerequisites

| Tool | Version | Install |
|---|---|---|
| Node.js | ≥ 18 | https://nodejs.org |
| npm | ≥ 9 | bundled with Node |

Install JavaScript dependencies:

```bash
npm install ethers solc
```

> **Note:** `solc` is only needed for `deploy.js` (it compiles the contract at runtime).  
> For `bot.js` alone, only `ethers` is required.

---

## 5. Quick-start on Sepolia testnet

This is the recommended path to understand the system before spending real money.

### Step 1 — Get a wallet and testnet ETH

1. Create a new wallet (MetaMask, `cast wallet new`, etc.) and **save the private key**.
2. Get Sepolia ETH from a faucet:
   - https://sepoliafaucet.com
   - https://faucet.quicknode.com/ethereum/sepolia
   - https://faucets.chain.link (requires Chainlink login)
3. You need at least ~0.05 ETH for gas on Sepolia.

### Step 2 — Get an RPC URL

Sign up for a free key at [Alchemy](https://alchemy.com) or [Infura](https://infura.io) and grab your **Sepolia** endpoint:

```
https://eth-sepolia.g.alchemy.com/v2/<YOUR_KEY>
```

### Step 3 — Deploy the contract

```bash
NETWORK=sepolia \
PRIVATE_KEY=0xYOUR_PRIVATE_KEY \
RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY \
node deploy.js
```

Expected output:

```
Compiling UniswapV4FlashArbitrage.sol…
Network  : sepolia (chainId 11155111)
Deployer : 0xYourAddress
PoolMgr  : 0x8C4BcBE6b9eF47855f97E675296FA3F6fafa5F1A
Balance  : 0.1 ETH

Deploying…
Tx hash  : 0xabc...

✅  Contract deployed at: 0xDeployedContractAddress
    Block: 7654321

Next step — start the bot:
  NETWORK=sepolia ARB_CONTRACT=0xDeployedContractAddress PRIVATE_KEY=0x... RPC_URL=... node bot.js
```

Copy the deployed address.

### Step 4 — Start the arb bot

```bash
NETWORK=sepolia \
ARB_CONTRACT=0xDeployedContractAddress \
PRIVATE_KEY=0xYOUR_PRIVATE_KEY \
RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY \
node bot.js
```

The bot fires `flashArb` every second without any off-chain price checks. The contract reverts atomically with `NoProfit()` when there is nothing to earn, so no principal is ever at risk — only the gas cost of the reverted transaction.

```
[2026-04-21T12:00:00.000Z] Firing flashArb…
  ↳ tx sent: 0x123...
  ↳ confirmed in block 7654322 (status=reverted)
[2026-04-21T12:00:01.000Z] Firing flashArb…
  ↳ tx sent: 0x456...
  ↳ confirmed in block 7654323 (status=success)
```

---

## 6. Deploy to mainnet

Identical to the Sepolia flow — just change `NETWORK=mainnet` and use a mainnet RPC:

```bash
NETWORK=mainnet \
PRIVATE_KEY=0xYOUR_PRIVATE_KEY \
RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY \
node deploy.js
```

`deploy.js` verifies the chain ID before submitting, so it will **error out** if your RPC URL points to the wrong network.

> ⚠️ **Mainnet uses real money.** Test on Sepolia first.

---

## 7. Run the arb bot

### Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `NETWORK` | No | `mainnet` | `mainnet` or `sepolia` |
| `ARB_CONTRACT` | Yes | — | Address of your deployed `UniswapV4FlashArbitrage` |
| `PRIVATE_KEY` | Yes | — | Hex private key of the bot wallet |
| `RPC_URL` | No | Preset default | JSON-RPC endpoint for the chosen network |

### Tuning parameters

Open `bot.js` and adjust the borrow amount to match your strategy and token pair:

```js
// How much to borrow per arb attempt (affects price impact)
const BORROW_AMOUNT = ethers.parseUnits("1", 18);   // mainnet
const BORROW_AMOUNT = ethers.parseUnits("0.01", 18); // testnet
```

### Changing the token pair / pools

Edit the pool configuration section near the top of `bot.js`:

```js
// Replace these with your target tokens
const WETH = preset.weth;
const USDC = preset.usdc;

// Replace fee tiers and tick spacings with the pools you want to arb
const pool0Key = { ..., fee: 500,  tickSpacing: 10,  ... };
const pool1Key = { ..., fee: 3000, tickSpacing: 60,  ... };
```

> `currency0` **must** be the lexicographically smaller address — the sort at the top of the file handles this automatically for the default WETH/USDC pair.

---

## 8. Contract reference

### `UniswapV4FlashArbitrage.sol`

#### Constructor

```solidity
constructor(address _poolManager)
```

Pass the PoolManager address for your target network (see [Network addresses](#3-network-addresses)).

#### `flashArb`

```solidity
function flashArb(
    PoolKey calldata pool0Key,   // pool to borrow from & swap tokenIn→tokenOut
    PoolKey calldata pool1Key,   // pool to swap tokenOut→tokenIn
    Currency tokenIn,            // token to borrow and profit in
    Currency tokenOut,           // intermediate token
    uint256 amount               // borrow size (exact input)
) external
```

Called by the bot. Reverts with `NoProfit()` if `amountBack <= amount`.

#### `unlockCallback`

Called internally by the PoolManager. Executes the full borrow → swap → swap → repay → profit sequence atomically. Not meant to be called directly.

#### Errors

| Error | Meaning |
|---|---|
| `NotPoolManager()` | `unlockCallback` was called by someone other than the PoolManager |
| `NoProfit()` | The round-trip swaps returned ≤ the borrowed amount |

---

### `flashloanV4.sol`

Minimal V4 flash-loan skeleton. Override `_executeFlashLoanLogic` to add your own logic (liquidations, collateral swaps, etc.).

```solidity
function _executeFlashLoanLogic(
    Currency currency,
    uint256 amount,
    bytes memory data
) internal virtual { /* your code here */ }
```

Supports both ERC-20 and native ETH (`address(0)`).

---

### `swapuniswapV4.sol`

Standalone exact-input swap using the V4 PoolManager directly.

```solidity
function swapExactInput(
    PoolKey calldata key,
    uint128 amountIn,
    uint128 minAmountOut
) external returns (uint256 amountOut)
```

---

## 9. V3 → V4 differences

`ref.sol` shows the equivalent V3 flash-swap for comparison. The key differences:

| | Uniswap V3 | Uniswap V4 |
|---|---|---|
| Entry point | Individual pool contract | Singleton `PoolManager` |
| Flash fee | Yes (same as swap fee) | **None** (free flash accounting) |
| Callback | `uniswapV3SwapCallback` | `unlockCallback` |
| Pool identity | Pool address | `PoolKey` struct |
| Return type | `int256 amount0/1` | `BalanceDelta` |
| Settlement | Transfer to pool directly | `settle()` + `take()` on PoolManager |

---

## 10. Troubleshooting

**`Deployer balance is 0`**  
Fund your wallet with testnet ETH from a faucet before deploying.

**`Chain ID mismatch`**  
Your `RPC_URL` points to a different network than `NETWORK`. Double-check both env vars.

**`NoProfit()` revert**  
The on-chain swap result returned ≤ the borrowed amount. This is the normal outcome when there is no spread — the tx reverts and no principal is lost. Only the gas fee is spent. Tune `BORROW_AMOUNT` to reduce price impact.

**Bot fires every second and all txs revert**  
No price spread currently exists between the two pools. This is expected — the bot relies on the contract's `NoProfit()` guard rather than off-chain detection. You can point the bot at pools with known imbalances to verify it works.

**`solc` not found**  
Run `npm install solc` in the project directory.

**Nonce issues / dropped transactions**  
The bot resyncs the nonce automatically on `tx.wait` errors. If you restart the bot, it re-reads the nonce from the chain on startup.

---

## License

MIT
