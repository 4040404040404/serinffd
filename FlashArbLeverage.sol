// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ── Deployed addresses (Ethereum mainnet) ────────────────────────────────────
address constant POOL_MANAGER       = 0x000000000004444c5dc75cB358380D2e3dE08A90; // Uniswap V4
address constant SWAP_ROUTER_02     = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45; // Uniswap V3 SwapRouter02
address constant AAVE_POOL          = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2; // Aave V3 Pool
address constant AAVE_ADDR_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e; // Aave V3 AddressesProvider

// ── Constants ─────────────────────────────────────────────────────────────────
uint256 constant MAX_LEVERAGE_LOOPS = 10;
uint256 constant LTV_SAFETY_BPS     = 9000;  // borrow 90 % of available per iteration
uint256 constant MIN_HF             = 12e17; // stop leveraging at health-factor 1.2
uint256 constant BPS                = 10_000;

/**
 * @title  FlashArbLeverage
 * @notice Combines Uniswap V4 fee-free flash loans, Uniswap V3 cross-pool
 *         arbitrage, and an Aave V3 leveraged lending position.
 *
 * ── Per-call execution flow (executeArb) ─────────────────────────────────────
 *
 *  1. Borrow `flashAmount` of `tokenIn` from the Uniswap V4 PoolManager (0 fee).
 *
 *  2. Two-leg arbitrage:
 *       tokenIn ──[pool fee0]──► tokenOut ──[pool fee1]──► tokenIn
 *     A large flash amount is used deliberately so that even a tiny price
 *     discrepancy between the two pools generates a meaningful absolute profit.
 *
 *  3. Slippage gate:
 *       POSITIVE slippage  (received ≥ flashAmount + minProfit):
 *         a. profit = received − flashAmount
 *         b. Deposit profit into Aave V3 as collateral.
 *         c. Leverage loop: supply → borrow (90 % of available) → supply …
 *            repeated up to MAX_LEVERAGE_LOOPS times (or until health factor
 *            approaches MIN_HF).  This maximises capital efficiency on the
 *            compounding profit position.
 *         d. Repay the Uniswap flash loan with flashAmount (retained from
 *            the arb output after profit is sent to Aave).
 *
 *       NEGATIVE slippage  (received < flashAmount + minProfit):
 *         • Aave deposit is skipped entirely (safety protocol – prevents
 *           reversion of the flash loan due to over-commitment).
 *         • Flash loan is repaid directly; reverts only if output < flashAmount.
 *
 *  4. Lending yield accumulates in the Aave position across repeated calls.
 *     The owner calls collectYield() or unwindPosition() to realise those gains.
 *
 * ── Off-chain keeper note ────────────────────────────────────────────────────
 *  executeArb() is intended to be triggered every block (≈ every second on
 *  L2s) by an off-chain keeper without requiring a prior opportunity scan.
 *  The arb legs capture any momentary price divergence present in that block.
 *  If no divergence exists the call costs only gas (no loss of principal).
 */
contract FlashArbLeverage is IUnlockCallback {

    // ── immutable state ───────────────────────────────────────────────────────
    IPoolManager   public immutable poolManager;
    ISwapRouter02  public immutable swapRouter;
    IAavePool      public immutable aavePool;
    address        public immutable owner;

    // ── errors ────────────────────────────────────────────────────────────────
    error NotPoolManager();
    error NotOwner();
    error InsufficientOutput();  // arb output < flashAmount → cannot repay loan

    // ── structs ───────────────────────────────────────────────────────────────

    /**
     * @param tokenIn      Token to flash-borrow and use as arb base.
     * @param tokenOut     Intermediate token for the two-leg swap path.
     * @param flashAmount  Size of the flash loan (larger = better price capture).
     * @param fee0         Uniswap V3 fee tier for the tokenIn→tokenOut leg.
     * @param fee1         Uniswap V3 fee tier for the tokenOut→tokenIn leg.
     * @param minProfit    Minimum tokenIn profit to trigger Aave deposit (0 = any).
     */
    struct ArbParams {
        address tokenIn;
        address tokenOut;
        uint256 flashAmount;
        uint24  fee0;
        uint24  fee1;
        uint256 minProfit;
    }

    struct CallbackData {
        ArbParams arb;
        address   caller;
    }

    // ── constructor ───────────────────────────────────────────────────────────
    constructor() {
        poolManager = IPoolManager(POOL_MANAGER);
        swapRouter  = ISwapRouter02(SWAP_ROUTER_02);
        aavePool    = IAavePool(AAVE_POOL);
        owner       = msg.sender;
    }

    // ── modifier ──────────────────────────────────────────────────────────────
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ── external: trigger ────────────────────────────────────────────────────

    /**
     * @notice Execute one flash-arb + Aave leverage cycle.
     * @dev Designed to be called on a tight schedule (every block / second)
     *      by an off-chain keeper without requiring opportunity detection.
     */
    function executeArb(ArbParams calldata params) external onlyOwner {
        poolManager.unlock(
            abi.encode(CallbackData({ arb: params, caller: msg.sender }))
        );
    }

    // ── external: position management ────────────────────────────────────────

    /**
     * @notice Withdraw a specific amount from the Aave collateral position
     *         directly to the owner (use to harvest accrued supply interest).
     * @param token   The supplied asset address.
     * @param amount  Amount to withdraw (use type(uint256).max for all).
     */
    function collectYield(address token, uint256 amount) external onlyOwner {
        aavePool.withdraw(token, amount, owner);
    }

    /**
     * @notice Fully unwind the leveraged Aave position and send all
     *         collateral to the owner.
     * @dev Iterates: withdraw collateral → repay debt, until debt reaches 0,
     *      then does a final full withdrawal.
     */
    function unwindPosition(address token) external onlyOwner {
        for (uint256 i; i < MAX_LEVERAGE_LOOPS + 2; ++i) {
            (, uint256 totalDebtBase,,,,) = aavePool.getUserAccountData(address(this));
            if (totalDebtBase == 0) break;

            // Convert base-currency debt to token units (+1 % buffer)
            uint256 debtTokenAmt = (_baseToToken(token, totalDebtBase) * 10_100) / BPS;

            try aavePool.withdraw(token, debtTokenAmt, address(this))
                returns (uint256 withdrawn)
            {
                IERC20(token).approve(address(aavePool), withdrawn);
                aavePool.repay(token, withdrawn, 2, address(this));
            } catch {
                break;
            }
        }
        // Final sweep – withdraw any remaining collateral
        aavePool.withdraw(token, type(uint256).max, owner);
    }

    /**
     * @notice Rescue any token balance sitting in this contract (emergency).
     */
    function rescueTokens(address token) external onlyOwner {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).transfer(owner, bal);
    }

    // ── IUnlockCallback ───────────────────────────────────────────────────────

    function unlockCallback(bytes calldata rawData)
        external
        override
        returns (bytes memory)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        CallbackData memory cd  = abi.decode(rawData, (CallbackData));
        ArbParams    memory arb = cd.arb;
        Currency currency = Currency.wrap(arb.tokenIn);

        // ── Step 1: receive flash-loan funds ─────────────────────────────────
        poolManager.take(currency, address(this), arb.flashAmount);

        // ── Step 2: two-leg arbitrage ─────────────────────────────────────────
        uint256 received = _arbitrage(arb);

        // ── Step 3: slippage gate ─────────────────────────────────────────────
        bool positiveSlippage = received >= arb.flashAmount + arb.minProfit;

        if (positiveSlippage) {
            // Profit is deposited into Aave and leveraged for compounding yield.
            // The flashAmount (= received − profit) is kept for loan repayment.
            uint256 profit = received - arb.flashAmount;
            _depositAndLeverage(arb.tokenIn, profit);
        } else {
            // Negative-slippage safety: do not touch Aave.
            // Revert only if we cannot even repay the loan principal.
            if (received < arb.flashAmount) revert InsufficientOutput();
        }

        // ── Step 4: repay Uniswap V4 flash loan (fee = 0) ────────────────────
        IERC20(arb.tokenIn).transfer(address(poolManager), arb.flashAmount);
        poolManager.settle(currency);

        return bytes("");
    }

    // ── internal: arbitrage ───────────────────────────────────────────────────

    /**
     * @dev Swap tokenIn → tokenOut on the pool with fee0, then tokenOut →
     *      tokenIn on the pool with fee1.  Returns total tokenIn received.
     */
    function _arbitrage(ArbParams memory arb) internal returns (uint256) {
        uint256 mid = _swap(arb.tokenIn,  arb.tokenOut, arb.fee0, arb.flashAmount, 0);
        return  _swap(arb.tokenOut, arb.tokenIn,  arb.fee1, mid,            0);
    }

    function _swap(
        address tokenIn,
        address tokenOut,
        uint24  fee,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal returns (uint256 amountOut) {
        IERC20(tokenIn).approve(address(swapRouter), amountIn);
        amountOut = swapRouter.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn:           tokenIn,
                tokenOut:          tokenOut,
                fee:               fee,
                recipient:         address(this),
                amountIn:          amountIn,
                amountOutMinimum:  amountOutMin,
                sqrtPriceLimitX96: 0
            })
        );
    }

    // ── internal: Aave leverage ───────────────────────────────────────────────

    /**
     * @dev Supply `amount` to Aave V3, then repeatedly:
     *        borrow (90 % of available in token units) → re-supply
     *      until MAX_LEVERAGE_LOOPS iterations or health factor reaches MIN_HF.
     *      Each loop geometrically amplifies the collateral position, earning
     *      compounded supply APY on the full leveraged stack.
     *
     *      Positive-slippage funds the seed deposit; the loop maximises its
     *      capital efficiency within Aave's LTV limits.
     */
    function _depositAndLeverage(address token, uint256 amount) internal {
        if (amount == 0) return;

        // Seed deposit
        IERC20(token).approve(address(aavePool), amount);
        aavePool.supply(token, amount, address(this), 0);

        // Leverage loop
        for (uint256 i; i < MAX_LEVERAGE_LOOPS; ++i) {
            (,, uint256 availBorrowBase,,, uint256 hf) =
                aavePool.getUserAccountData(address(this));

            if (availBorrowBase == 0 || hf < MIN_HF) break;

            // Convert available borrows from base currency (8 dec) to token units
            uint256 availToken = _baseToToken(token, availBorrowBase);
            uint256 borrowAmt  = (availToken * LTV_SAFETY_BPS) / BPS;
            if (borrowAmt == 0) break;

            // Variable rate (mode 2); gracefully degrade on any failure
            try aavePool.borrow(token, borrowAmt, 2, 0, address(this)) {
                IERC20(token).approve(address(aavePool), borrowAmt);
                aavePool.supply(token, borrowAmt, address(this), 0);
            } catch {
                break;
            }
        }
    }

    // ── internal: oracle helpers ──────────────────────────────────────────────

    /**
     * @dev Convert an amount expressed in Aave's base currency (USD, 8 decimals)
     *      to the equivalent amount in `token`'s native decimals.
     *
     *      formula: tokenAmount = baseAmount × 10^decimals / pricePerToken
     */
    function _baseToToken(address token, uint256 baseAmount)
        internal view returns (uint256)
    {
        address oracle     = IPoolAddressesProvider(AAVE_ADDR_PROVIDER).getPriceOracle();
        uint256 tokenPrice = IAaveOracle(oracle).getAssetPrice(token); // base units per token
        uint8   decimals   = IERC20Metadata(token).decimals();
        if (tokenPrice == 0) return 0;
        return (baseAmount * (10 ** uint256(decimals))) / tokenPrice;
    }

    // ── receive ETH ──────────────────────────────────────────────────────────
    receive() external payable {}
}

// ─────────────────────────────── Types ───────────────────────────────────────

// Currency is an address wrapper used by Uniswap V4 (address(0) = native ETH)
type Currency is address;

library CurrencyLibrary {
    function unwrap(Currency currency) internal pure returns (address) {
        return Currency.unwrap(currency);
    }
}
using CurrencyLibrary for Currency;

// ─────────────────────────────── Interfaces ──────────────────────────────────

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function settle(Currency currency) external payable returns (uint256);
    function take(Currency currency, address to, uint256 amount) external;
}

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params)
        external payable returns (uint256 amountOut);
}

interface IAavePool {
    function supply(
        address asset, uint256 amount, address onBehalfOf, uint16 referralCode
    ) external;

    function borrow(
        address asset, uint256 amount, uint256 interestRateMode,
        uint16 referralCode, address onBehalfOf
    ) external;

    function repay(
        address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf
    ) external returns (uint256);

    function withdraw(
        address asset, uint256 amount, address to
    ) external returns (uint256);

    function getUserAccountData(address user) external view returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 availableBorrowsBase,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    );
}

interface IPoolAddressesProvider {
    function getPriceOracle() external view returns (address);
}

interface IAaveOracle {
    /// @return Price of `asset` in Aave's base currency (USD, 8 decimals)
    function getAssetPrice(address asset) external view returns (uint256);
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IERC20Metadata is IERC20 {
    function decimals() external view returns (uint8);
}
