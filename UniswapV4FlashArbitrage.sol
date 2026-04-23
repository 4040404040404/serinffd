// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Known PoolManager deployments — pass the appropriate address to the constructor.
//
//   Ethereum Mainnet : 0x000000000004444c5dc75cB358380D2e3dE08A90
//   Sepolia testnet  : 0x8C4BcBE6b9eF47855f97E675296FA3F6fafa5F1A
//
// See deploy.js for a ready-to-use deployment script.

// ── Types & libraries ─────────────────────────────────────────────────────────

// Currency wraps an address; address(0) represents native ETH.
type Currency is address;

library CurrencyLibrary {
    function unwrap(Currency currency) internal pure returns (address) {
        return Currency.unwrap(currency);
    }
}

using CurrencyLibrary for Currency;

// PoolKey uniquely identifies a V4 pool.
struct PoolKey {
    Currency currency0;  // lower address token (canonical ordering)
    Currency currency1;  // higher address token
    uint24 fee;          // pool swap fee in hundredths of a bip
    int24 tickSpacing;   // minimum tick spacing for the pool
    address hooks;       // hook contract (address(0) if none)
}

// BalanceDelta encodes two int128 amounts packed into one int256.
// Negative = caller owes the pool.  Positive = pool owes the caller.
type BalanceDelta is int256;

library BalanceDeltaLibrary {
    function amount0(BalanceDelta delta) internal pure returns (int128) {
        return int128(int256(BalanceDelta.unwrap(delta) >> 128));
    }

    function amount1(BalanceDelta delta) internal pure returns (int128) {
        return int128(int256(BalanceDelta.unwrap(delta)));
    }
}

using BalanceDeltaLibrary for BalanceDelta;

// ── Interfaces ────────────────────────────────────────────────────────────────

interface IPoolManager {
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;    // negative = exact input, positive = exact output
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
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// Sqrt price boundary constants (same values used in swapuniswapV4.sol)
uint160 constant MIN_SQRT_PRICE = 4295128739;
uint160 constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

/// @notice UniswapV4 flash-loan arbitrage contract.
///
/// Strategy (single atomic transaction):
///   1. Flash-borrow `amount` of tokenIn from V4 PoolManager (free — no fee).
///   2. Swap tokenIn → tokenOut on pool0  (e.g. the "cheaper" pool).
///   3. Swap tokenOut → tokenIn on pool1  (e.g. the "more expensive" pool).
///   4. Repay the flash loan (exactly `amount` of tokenIn).
///   5. Transfer the surplus (profit) back to the caller.
///
/// The transaction reverts automatically if the two swaps do not return more
/// tokenIn than was borrowed, so no capital is ever at risk.
///
/// Off-chain usage: call `flashArb` from a bot whenever a price discrepancy
/// between the two pools is detected.  See bot.js / deploy.js for helpers.
contract UniswapV4FlashArbitrage is IUnlockCallback {
    IPoolManager public immutable poolManager;

    error NotPoolManager();
    error NoProfit();

    /// @param _poolManager Address of the V4 PoolManager for the target network.
    ///        Mainnet  : 0x000000000004444c5dc75cB358380D2e3dE08A90
    ///        Sepolia  : 0x8C4BcBE6b9eF47855f97E675296FA3F6fafa5F1A
    constructor(address _poolManager) {
        poolManager = IPoolManager(_poolManager);
    }

    // ── Data passed through unlock → unlockCallback ───────────────────────────

    struct ArbParams {
        PoolKey pool0Key;   // pool to flash-borrow from and swap tokenIn → tokenOut
        PoolKey pool1Key;   // pool to swap tokenOut → tokenIn (buy-back)
        Currency tokenIn;   // token being borrowed and ultimately profited in
        Currency tokenOut;  // intermediate token
        uint256 amount;     // flash-borrow size (exact input on pool0)
        address caller;     // receives the profit
    }

    // ── External entry point ──────────────────────────────────────────────────

    /// @notice Initiate a flash-loan arbitrage between two V4 pools.
    /// @param pool0Key  PoolKey of the pool to borrow from / swap tokenIn→tokenOut.
    /// @param pool1Key  PoolKey of the pool to swap tokenOut→tokenIn (buy-back).
    /// @param tokenIn   Token to borrow and profit in.
    /// @param tokenOut  Intermediate token received from pool0 and spent on pool1.
    /// @param amount    Amount of tokenIn to borrow (exact input for both swaps).
    function flashArb(
        PoolKey calldata pool0Key,
        PoolKey calldata pool1Key,
        Currency tokenIn,
        Currency tokenOut,
        uint256 amount
    ) external {
        bytes memory data = abi.encode(
            ArbParams({
                pool0Key: pool0Key,
                pool1Key: pool1Key,
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amount: amount,
                caller: msg.sender
            })
        );

        // Triggers unlockCallback below; everything runs atomically.
        poolManager.unlock(data);
    }

    // ── V4 unlock callback — all arbitrage logic runs here ────────────────────

    /// @notice Called by PoolManager immediately after `unlock`.
    ///         Executes the full borrow → swap → swap → repay → profit sequence.
    function unlockCallback(bytes calldata data)
        external
        override
        returns (bytes memory)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        ArbParams memory p = abi.decode(data, (ArbParams));

        // ── Step 1: Flash-borrow tokenIn (V4 flash loans carry zero fee) ──────
        //
        // `take` withdraws tokens from the PoolManager to this contract and
        // records a negative delta (debt) for tokenIn that must reach zero by
        // the time this callback returns.
        poolManager.take(p.tokenIn, address(this), p.amount);

        // ── Step 2: Swap tokenIn → tokenOut on pool0 ─────────────────────────
        //
        // Determine swap direction from the PoolKey's canonical token ordering.
        // currency0 < currency1 by address value (V4 invariant).
        bool zeroForOne0 =
            Currency.unwrap(p.tokenIn) == Currency.unwrap(p.pool0Key.currency0);

        // Exact-input swap: amountSpecified is negative per V4 convention.
        // delta.amount0() < 0  →  we owe tokenIn  (must settle)
        // delta.amount1() > 0  →  pool owes us tokenOut  (take after settle)
        BalanceDelta d0 = poolManager.swap(
            p.pool0Key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne0,
                amountSpecified: -int256(p.amount),
                sqrtPriceLimitX96: zeroForOne0
                    ? MIN_SQRT_PRICE + 1
                    : MAX_SQRT_PRICE - 1
            }),
            bytes("")
        );

        // Output of swap0: the positive side of the returned delta.
        uint256 amountOut0 = zeroForOne0
            ? uint256(int256(d0.amount1()))
            : uint256(int256(d0.amount0()));

        // Settle pool0's tokenIn debt using the flash-borrowed tokens.
        // The contract holds exactly `p.amount` of tokenIn from Step 1.
        IERC20(Currency.unwrap(p.tokenIn)).transfer(address(poolManager), p.amount);
        poolManager.settle(p.tokenIn);

        // Receive tokenOut that pool0 owes us.
        poolManager.take(p.tokenOut, address(this), amountOut0);

        // ── Step 3: Swap tokenOut → tokenIn on pool1 ─────────────────────────

        bool zeroForOne1 =
            Currency.unwrap(p.tokenOut) == Currency.unwrap(p.pool1Key.currency0);

        BalanceDelta d1 = poolManager.swap(
            p.pool1Key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne1,
                amountSpecified: -int256(amountOut0),
                sqrtPriceLimitX96: zeroForOne1
                    ? MIN_SQRT_PRICE + 1
                    : MAX_SQRT_PRICE - 1
            }),
            bytes("")
        );

        // tokenIn received back from pool1.
        uint256 amountBack = zeroForOne1
            ? uint256(int256(d1.amount1()))
            : uint256(int256(d1.amount0()));

        // Settle pool1's tokenOut debt using tokens received from pool0.
        IERC20(Currency.unwrap(p.tokenOut)).transfer(address(poolManager), amountOut0);
        poolManager.settle(p.tokenOut);

        // Receive tokenIn that pool1 owes us.
        poolManager.take(p.tokenIn, address(this), amountBack);

        // ── Step 4: Profit guard ──────────────────────────────────────────────
        //
        // Revert the whole transaction if the round-trip yielded no surplus.
        // This protects the caller from gas waste on unprofitable executions.
        if (amountBack <= p.amount) revert NoProfit();
        uint256 profit = amountBack - p.amount;

        // ── Step 5: Repay the flash loan ──────────────────────────────────────
        //
        // Transfer exactly `p.amount` of tokenIn back to the PoolManager and
        // settle, clearing the negative delta created in Step 1.
        IERC20(Currency.unwrap(p.tokenIn)).transfer(address(poolManager), p.amount);
        poolManager.settle(p.tokenIn);

        // ── Step 6: Send profit to the original caller ────────────────────────
        IERC20(Currency.unwrap(p.tokenIn)).transfer(p.caller, profit);

        // All deltas are now zero; unlock succeeds.
        return bytes("");
    }

    // Allow the contract to receive ETH (needed for native-currency pools).
    receive() external payable {}
}
