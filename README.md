# FlashArbLeverage

> **Sepolia testnet** · Uniswap V4 flash loans · Uniswap V3 cross-pool arbitrage · Aave V3 leveraged yield

A single atomic Solidity contract that:

1. **Borrows** a large amount from the **Uniswap V4 PoolManager** (fee = 0).
2. **Arbitrages** a two-leg Uniswap V3 swap path (`tokenIn → tokenOut → tokenIn`) to capture cross-pool price discrepancies.
3. **Deposits** the profit into **Aave V3** and **loops** the supply/borrow cycle up to 10× to maximise capital efficiency.
4. **Repays** the flash loan unconditionally from the arb output.
5. An off-chain **keeper** calls `executeArb()` on every Ethereum block — no opportunity-detection required.

---

## Repository layout

```
FlashArbLeverage.sol        ← main contract
script/
  Deploy.s.sol              ← Foundry broadcast deployment script
test/
  FlashArbLeverageTest.t.sol← Foundry Sepolia-fork integration tests
keeper/
  keeper.js                 ← Node.js block-by-block keeper
  package.json
foundry.toml                ← Foundry project config
remappings.txt
.env.example                ← environment variable template
```

---

## How it works

### Execution flow per block

```
owner / keeper
    │
    ▼ executeArb(ArbParams)
FlashArbLeverage
    │
    ├─[1]─► Uniswap V4 PoolManager.unlock()
    │           │
    │           ▼ unlockCallback()
    │        PoolManager.take()  ← borrow flashAmount (0 fee)
    │           │
    │        [2] Two-leg arbitrage via Uniswap V3
    │           tokenIn ──[fee0]──► tokenOut ──[fee1]──► tokenIn
    │           │
    │        [3] Slippage gate
    │           ├─ POSITIVE (received ≥ flashAmount + minProfit)
    │           │       profit = received − flashAmount
    │           │       Aave V3: supply(profit) → leverage loop
    │           │         repeat: borrow(90% available) → supply
    │           │         until 10 iterations or HF ≤ 1.2
    │           │
    │           └─ NEGATIVE  (safety)
    │                   skip Aave entirely
    │                   revert only if received < flashAmount
    │           │
    │        [4] Repay flash loan (transfer flashAmount → PoolManager)
    │
    └─────────── returns
```

### Why a large flash amount?

Even a 0.01% price difference between two pools generates a **10 000 USDC profit** on a **100 000 000 USDC** flash loan.  
A large amount also naturally accounts for **positive slippage** — when the arb moves the pool price in your favour, you receive *more* than expected.

### Slippage safety protocol

| Slippage | Aave step | Flash loan repayment |
|---|---|---|
| Positive (`received ≥ flashAmount + minProfit`) | ✅ profit deposited & leveraged | ✅ always repaid |
| Negative (`received < flashAmount + minProfit`) | ❌ skipped | ✅ always repaid |
| Critical (`received < flashAmount`) | ❌ skipped | 🚫 **reverts** |

### Aave leverage loop

```
seed = profit from arb
supply(seed)
loop (up to 10×):
    availBorrow = getUserAccountData().availableBorrowsBase → token units
    borrow(availBorrow × 90%)
    supply(borrowed amount)
    stop if healthFactor ≤ 1.2
```

The loop geometrically amplifies the collateral stack, earning **compounded supply APY** on the full leveraged position. Each successive call adds more to the same Aave position.

---

## Prerequisites

| Tool | Version |
|---|---|
| [Foundry](https://book.getfoundry.sh/getting-started/installation) | latest |
| Node.js | ≥ 18 |
| npm | ≥ 9 |

---

## Setup

### 1 — Clone and install Foundry dependencies

```bash
git clone https://github.com/4040404040404/serinffd
cd serinffd

# Install forge-std (needed for tests and deploy script)
forge install foundry-rs/forge-std --no-commit
```

### 2 — Configure environment

```bash
cp .env.example .env
```

Open `.env` and fill in:

| Variable | Description |
|---|---|
| `ETH_RPC_URL` | Sepolia JSON-RPC endpoint (Alchemy, Infura, etc.) |
| `PRIVATE_KEY` | Deployer/owner private key (hex, with `0x` prefix) |
| `ETHERSCAN_API_KEY` | For automatic contract verification |
| `CONTRACT_ADDRESS` | Fill in after deployment |
| `TOKEN_IN` | Base token to arb (default: USDC) |
| `TOKEN_OUT` | Intermediate token (default: WETH) |
| `FLASH_AMOUNT` | Size of the flash loan in `TOKEN_IN` units |
| `MIN_PROFIT` | Minimum profit to trigger Aave deposit (0 = always) |
| `FEE0` | Uniswap V3 fee tier for the first swap leg |
| `FEE1` | Uniswap V3 fee tier for the second swap leg |

---

## Compile

```bash
forge build
```

---

## Test (Sepolia fork)

The tests fork Sepolia and create an artificial price discrepancy to verify the full arbitrage + Aave leverage flow.

```bash
source .env
forge test --fork-url $ETH_RPC_URL -vvvv
```

Expected output (numbers vary by fork block):

```
[PASS] test_ArbExecutesSuccessfully()
[PASS] test_ProfitDepositedToAave()
[PASS] test_HighMinProfitSkipsAave()
[PASS] test_CollectYield()
[PASS] test_UnwindPosition()
[PASS] test_OnlyOwner()
[PASS] test_RescueTokens()
```

---

## Deploy

```bash
source .env

forge script script/Deploy.s.sol \
  --rpc-url $ETH_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  -vvvv
```

Copy the printed contract address into `CONTRACT_ADDRESS` in your `.env`.

---

## Run the keeper

The keeper calls `executeArb()` on every new block. No opportunity detection is needed — the contract's slippage gate handles unprofitable blocks gracefully.

```bash
cd keeper
npm install
cd ..

source .env
node keeper/keeper.js
```

Sample output:

```
FlashArbLeverage Keeper starting …
  Contract : 0xabc…
  Wallet   : 0xdef…
  tokenIn  : 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8
  tokenOut : 0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c
  flash    : 1000000000000
  fee0/fee1: 500 / 3000
  Owner check passed ✓
Listening for new blocks …

[#21950412] sending executeArb …
[#21950412] ✓ mined in block 21950412 | gasUsed 312450 | 4201 ms
[#21950413] sending executeArb …
[#21950413] ✓ mined in block 21950413 | gasUsed 289100 | 3980 ms
```

### Running as a background service (systemd)

```ini
# /etc/systemd/system/flash-arb-keeper.service
[Unit]
Description=FlashArbLeverage Keeper
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/serinffd
EnvironmentFile=/home/ubuntu/serinffd/.env
ExecStart=/usr/bin/node /home/ubuntu/serinffd/keeper/keeper.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable flash-arb-keeper
sudo systemctl start  flash-arb-keeper
sudo journalctl -u flash-arb-keeper -f
```

---

## Managing the Aave position

### Harvest supply interest (partial)

```solidity
// Withdraw 500 USDC of accumulated yield to owner
arb.collectYield(USDC, 500e6);

// Withdraw everything
arb.collectYield(USDC, type(uint256).max);
```

Or via cast:

```bash
cast send $CONTRACT_ADDRESS \
  "collectYield(address,uint256)" \
  0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8 \
  $(cast --to-uint256 $(cast --max-uint 256)) \
  --rpc-url $ETH_RPC_URL \
  --private-key $PRIVATE_KEY
```

### Full exit (unwind all leverage)

```bash
cast send $CONTRACT_ADDRESS \
  "unwindPosition(address)" \
  0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8 \
  --rpc-url $ETH_RPC_URL \
  --private-key $PRIVATE_KEY
```

This iteratively repays all Aave debt and withdraws all collateral to the owner address.

### Emergency token rescue

```bash
cast send $CONTRACT_ADDRESS \
  "rescueTokens(address)" \
  0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8 \
  --rpc-url $ETH_RPC_URL \
  --private-key $PRIVATE_KEY
```

---

## Contract addresses (Sepolia testnet)

| Contract | Address |
|---|---|
| Uniswap V4 PoolManager | `0x8C4BcBE6b9eF47855f97E675296FA3F6fafa5F1A` |
| Uniswap V3 SwapRouter02 | `0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E` |
| Aave V3 Pool | `0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951` |
| Aave V3 PoolAddressesProvider | `0x012bAC54348C0E635dCAc9D5FB99f06F24136C9A` |
| WETH | `0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c` |
| USDC | `0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8` |

---

## Security considerations

- The contract uses `onlyOwner` for all sensitive operations (`executeArb`, `collectYield`, `unwindPosition`, `rescueTokens`).
- The Aave leverage step is **skipped** on negative slippage to prevent flash-loan reversal.
- The health-factor guard (`MIN_HF = 1.2`) prevents the Aave position from approaching liquidation during the leverage loop.
- The flash-loan repayment transfer return value is checked; a non-compliant token that returns `false` will revert with a clear message.
- `try/catch` blocks around Aave `borrow` and `withdraw` calls ensure the outer transaction degrades gracefully rather than bricking.

---

## License

MIT — see [LICENSE](LICENSE).
