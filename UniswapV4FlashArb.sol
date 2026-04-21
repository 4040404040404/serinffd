// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ═══════════════════════════════════════════════════════════════════════════
//  UniswapV4FlashArb
// ───────────────────────────────────────────────────────────────────────────
//  Flash-loan arbitrage on Uniswap V4 using fee-free flash accounting.
//
//  Architecture
//  ────────────
//  1. flashArb() encodes parameters and calls poolManager.unlock().
//  2. unlockCallback() is invoked atomically by the PoolManager:
//       a. Leg 1 — swap borrowToken → outputToken on pool0 (cheap source).
//       b. Leg 2 — swap outputToken → borrowToken on pool1 (expensive sink).
//       c. V4 flash accounting nets all deltas across both swaps automatically.
//          Net delta[borrowToken] = repayAmount − amountIn  (> 0 if profitable)
//          Net delta[outputToken] = outputAmount − outputAmount = 0
//       d. Profit is extracted via poolManager.take(); remaining delta = 0,
//          so unlock() succeeds.
//  3. If repayAmount ≤ amountIn the callback reverts — caller loses only gas.
//
//  Blind execution
//  ───────────────
//  flashArb() can be called every second without an oracle.  The on-chain
//  profit check is the sole gate: if no spread exists the transaction reverts
//  and the caller pays only gas.
//
//  Positive slippage capture
//  ─────────────────────────
//  Both swap legs use the absolute sqrtPrice limits (MIN/MAX), so the contract
//  accepts any price and keeps all surplus above amountIn as profit.
//
//  Deployment
//  ──────────
//  Ethereum mainnet — PoolManager: 0x000000000004444c5dc75cB358380D2e3dE08A90
//
//  Usage
//  ──────────
//  Deploy once, then call flashArb() from an off-chain keeper (see keeper.js).
// ═══════════════════════════════════════════════════════════════════════════

// ── Uniswap V4 PoolManager (Ethereum mainnet) ──────────────────────────────
address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

// ── Sqrt-price limits: allow full price range (capture all positive slippage)
uint160 constant MIN_SQRT_PRICE = 4295128739;
uint160 constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

// ── Currency type (address(0) = native ETH) ────────────────────────────────
type Currency is address;

library CurrencyLibrary {
    function unwrap(Currency currency) internal pure returns (address) {
        return Currency.unwrap(currency);
    }
}

using CurrencyLibrary for Currency;

// ── BalanceDelta: packed int256 (upper 128 bits = amount0, lower = amount1) ─
type BalanceDelta is int256;

library BalanceDeltaLibrary {
    // Positive value  → pool owes the locker (call take())
    // Negative value  → locker owes the pool  (call settle())
    function amount0(BalanceDelta delta) internal pure returns (int128) {
        return int128(int256(BalanceDelta.unwrap(delta) >> 128));
    }

    function amount1(BalanceDelta delta) internal pure returns (int128) {
        return int128(int256(BalanceDelta.unwrap(delta)));
    }
}

using BalanceDeltaLibrary for BalanceDelta;

// ── Pool identification ─────────────────────────────────────────────────────
struct PoolKey {
    Currency currency0;  // lower address token
    Currency currency1;  // higher address token
    uint24   fee;        // LP fee in hundredths of a bip (e.g. 3000 = 0.3 %)
    int24    tickSpacing;
    address  hooks;      // address(0) for unhook-ed pools
}

// ── Interfaces ──────────────────────────────────────────────────────────────
interface IPoolManager {
    struct SwapParams {
        bool    zeroForOne;        // true  = sell currency0, false = sell currency1
        int256  amountSpecified;   // negative = exact input, positive = exact output
        uint160 sqrtPriceLimitX96;
    }

    function unlock(bytes calldata data) external returns (bytes memory);

    function swap(
        PoolKey memory key,
        SwapParams memory params,
        bytes calldata hookData
    ) external returns (BalanceDelta);

    function settle(Currency currency) external payable returns (uint256);
    function take(Currency currency, address to, uint256 amount) external;
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

// ═══════════════════════════════════════════════════════════════════════════
contract UniswapV4FlashArb is IUnlockCallback {
    IPoolManager public immutable poolManager;
    address public owner;

    // ── Errors ──────────────────────────────────────────────────────────────
    error NotPoolManager();
    error NotOwner();
    /// @dev Raised inside unlockCallback when the arb yields no profit.
    ///      The transaction reverts, caller loses only gas.
    error NoProfit(uint256 repayAmount, uint256 borrowed);
    error UnexpectedDelta();
    error ZeroAddress();

    // ── Events ──────────────────────────────────────────────────────────────
    event ArbExecuted(
        address indexed borrowToken,
        address indexed outputToken,
        uint256         amountIn,
        uint256         profit
    );
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ── Constructor ─────────────────────────────────────────────────────────
    constructor() {
        poolManager = IPoolManager(POOL_MANAGER);
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ── Arbitrage parameters (encoded into unlock data) ─────────────────────
    struct ArbParams {
        PoolKey  pool0;           // First swap:  borrowToken → outputToken
        PoolKey  pool1;           // Second swap: outputToken → borrowToken
        Currency borrowToken;     // Token borrowed (and repaid)
        Currency outputToken;     // Intermediate token
        uint256  amountIn;        // Exact amount of borrowToken to borrow
        address  profitRecipient; // Receives profit (= msg.sender of flashArb)
    }

    // ────────────────────────────────────────────────────────────────────────
    /// @notice Trigger flash-loan arbitrage between two V4 pools.
    ///
    /// @dev Can be called blindly every second — reverts with NoProfit if no
    ///      spread exists, costing the caller only gas.  No oracle is used;
    ///      the contract relies solely on live V4 pool spot prices.
    ///
    /// @param pool0        PoolKey whose price favours borrowToken→outputToken
    ///                     (i.e. outputToken is cheap here).
    /// @param pool1        PoolKey whose price favours outputToken→borrowToken
    ///                     (i.e. outputToken is expensive here).
    /// @param borrowToken  Token to flash-borrow and repay.
    /// @param outputToken  Intermediate token.
    /// @param amountIn     Exact amount of borrowToken to use for each arb.
    // ────────────────────────────────────────────────────────────────────────
    function flashArb(
        PoolKey  calldata pool0,
        PoolKey  calldata pool1,
        Currency          borrowToken,
        Currency          outputToken,
        uint256           amountIn
    ) external {
        poolManager.unlock(
            abi.encode(
                ArbParams({
                    pool0:           pool0,
                    pool1:           pool1,
                    borrowToken:     borrowToken,
                    outputToken:     outputToken,
                    amountIn:        amountIn,
                    profitRecipient: msg.sender
                })
            )
        );
    }

    // ────────────────────────────────────────────────────────────────────────
    /// @notice V4 PoolManager callback — executes both swap legs atomically.
    ///
    /// Flash-accounting flow (all within one unlock session):
    ///
    ///   swap pool0 (borrowToken → outputToken):
    ///       delta[borrowToken] -= amountIn        (we owe pool0)
    ///       delta[outputToken] += outputAmount    (pool0 owes us)
    ///
    ///   swap pool1 (outputToken → borrowToken):
    ///       delta[outputToken] -= outputAmount    (we owe pool1)  → net = 0
    ///       delta[borrowToken] += repayAmount     (pool1 owes us)
    ///
    ///   net delta[borrowToken] = repayAmount − amountIn  (= profit)
    ///   net delta[outputToken] = 0
    ///
    ///   take(borrowToken, profitRecipient, profit) → delta[borrowToken] = 0
    ///   unlock succeeds; no external token transfers needed for swap settlement.
    // ────────────────────────────────────────────────────────────────────────
    function unlockCallback(bytes calldata data)
        external
        override
        returns (bytes memory)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        ArbParams memory params = abi.decode(data, (ArbParams));

        address borrowAddr = Currency.unwrap(params.borrowToken);
        address outputAddr = Currency.unwrap(params.outputToken);

        // ── Leg 1: borrowToken → outputToken on pool0 ────────────────────
        // zeroForOne = true  when borrowToken is currency0 (lower address)
        // zeroForOne = false when borrowToken is currency1 (higher address)
        bool zeroForOne0 = borrowAddr < outputAddr;

        BalanceDelta delta0 = poolManager.swap(
            params.pool0,
            IPoolManager.SwapParams({
                zeroForOne:        zeroForOne0,
                amountSpecified:   -int256(params.amountIn), // exact input
                sqrtPriceLimitX96: zeroForOne0
                    ? MIN_SQRT_PRICE + 1  // allow full downward price range
                    : MAX_SQRT_PRICE - 1  // allow full upward  price range
            }),
            bytes("")
        );

        // Extract outputAmount received from pool0.
        // zeroForOne0=true:  borrowToken=currency0 → amount0<0, amount1>0 (output)
        // zeroForOne0=false: borrowToken=currency1 → amount1<0, amount0>0 (output)
        int128 rawOutput = zeroForOne0 ? delta0.amount1() : delta0.amount0();
        if (rawOutput <= 0) revert UnexpectedDelta();
        uint256 outputAmount = uint256(uint128(rawOutput));

        // ── Leg 2: outputToken → borrowToken on pool1 ────────────────────
        bool zeroForOne1 = outputAddr < borrowAddr;

        BalanceDelta delta1 = poolManager.swap(
            params.pool1,
            IPoolManager.SwapParams({
                zeroForOne:        zeroForOne1,
                amountSpecified:   -int256(outputAmount), // exact input
                sqrtPriceLimitX96: zeroForOne1
                    ? MIN_SQRT_PRICE + 1
                    : MAX_SQRT_PRICE - 1
            }),
            bytes("")
        );

        // Extract repayAmount received from pool1.
        // zeroForOne1=true:  outputToken=currency0 → amount1>0 (borrowToken)
        // zeroForOne1=false: outputToken=currency1 → amount0>0 (borrowToken)
        int128 rawRepay = zeroForOne1 ? delta1.amount1() : delta1.amount0();
        if (rawRepay <= 0) revert UnexpectedDelta();
        uint256 repayAmount = uint256(uint128(rawRepay));

        // ── Profit check ─────────────────────────────────────────────────
        // At this point, cumulative flash-accounting deltas are:
        //   delta[borrowToken] = repayAmount − amountIn
        //   delta[outputToken] = 0
        // Blind execution: revert on no profit, caller loses only gas.
        if (repayAmount <= params.amountIn) {
            revert NoProfit(repayAmount, params.amountIn);
        }
        uint256 profit = repayAmount - params.amountIn;

        // ── Extract profit ────────────────────────────────────────────────
        // take() reduces delta[borrowToken] by profit → net delta = 0
        // All currency deltas are now zero; unlock() will succeed.
        poolManager.take(params.borrowToken, params.profitRecipient, profit);

        emit ArbExecuted(borrowAddr, outputAddr, params.amountIn, profit);
        return bytes("");
    }

    // ── Admin ────────────────────────────────────────────────────────────────

    /// @notice Withdraw any tokens accidentally held by this contract.
    function sweep(address token, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0)) {
            (bool ok,) = to.call{value: address(this).balance}("");
            require(ok, "ETH sweep failed");
        } else {
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal > 0) IERC20(token).transfer(to, bal);
        }
    }

    /// @notice Transfer contract ownership.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    receive() external payable {}
}
