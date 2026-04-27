// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AaveLeverageLib} from "./AaveLeverageLib.sol";
import {IAavePool}       from "./interfaces/IAavePool.sol";

// ─── Uniswap V4 constants ───────────────────────────────────────────────────
address constant POOL_MANAGER_ADDR = 0x000000000004444c5dc75cB358380D2e3dE08A90;

// ─── Aave V3 on Sepolia testnet ─────────────────────────────────────────────
address constant AAVE_POOL_ADDR = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;

// ─── Uniswap V3 SwapRouter02 on Sepolia ─────────────────────────────────────
address constant SWAP_ROUTER_02 = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;

// ─── Sqrt price limits ──────────────────────────────────────────────────────
uint160 constant MIN_SQRT_PRICE = 4295128739;
uint160 constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

// ─── Currency wrapper (address(0) = native ETH) ─────────────────────────────
type Currency is address;

// ─────────────────────────────────────────────────────────────────────────────
//  FlashArbitrageBot
// ─────────────────────────────────────────────────────────────────────────────

/// @title  FlashArbitrageBot
/// @notice Atomic flash-loan arbitrage contract that:
///           1. Borrows a large amount via a Uniswap V4 zero-fee flash loan.
///           2. Executes a two-leg arbitrage swap (tokenIn → intermediate → tokenIn)
///              across two pools/fee-tiers.
///           3. Immediately transfers profit to `owner`.
///           4. On positive slippage: loops through Aave V3 supply/borrow to
///              compound extra profit from the remaining principal.
///           5. Unwinds all Aave positions.
///           6. Repays the V4 flash loan.
///
/// @dev    The bot (keeper.js) fires `executeArbitrage` every ~1 second without
///         any on-chain opportunity detection.  It relies on an `eth_call`
///         simulation — if the call would revert (no profit), the tx is not sent.
contract FlashArbitrageBot is IUnlockCallback {
    using AaveLeverageLib for *;

    // ── Immutables ────────────────────────────────────────────────────────────
    IPoolManager public immutable poolManager;
    IAavePool    public immutable aavePool;
    ISwapRouter02 public immutable swapRouter;

    // ── Storage ───────────────────────────────────────────────────────────────
    address public owner;
    uint8   public maxLoops;    // max Aave leverage iterations (recommended 5–8)
    uint256 public ltvBps;      // conservative LTV in bps, e.g. 7125 (95 % of 7500)
    uint256 public minProfitableAmount; // minimum borrow size to continue the leverage loop

    // ── Errors ────────────────────────────────────────────────────────────────
    error NotOwner();
    error NotPoolManager();
    error NoProfitOrRevert(uint256 amountOut, uint256 flashAmount);

    // ── Events ────────────────────────────────────────────────────────────────
    event ArbitrageExecuted(
        address indexed tokenIn,
        uint256 flashAmount,
        uint256 arbProfit,
        uint256 loopProfit,
        uint8   loopsExecuted
    );

    // ─────────────────────────────────────────────────────────────────────────
    //  Structs
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Parameters for a single arbitrage execution, supplied by the bot.
    struct ArbitrageParams {
        // Flash loan
        Currency flashCurrency;   // token to borrow (address(0) = ETH)
        uint256  flashAmount;     // amount to borrow (as large as pool liquidity allows)
        // Leg 1: pool0 (flash-swap pool)  tokenIn → tokenOut
        address  pool0;           // V3 pool address for leg 1
        // Leg 2: pool1 (buy-back pool)    tokenOut → tokenIn
        uint24   fee1;            // V3 fee tier for leg 2 (via SwapRouter02)
        address  tokenIn;         // starting / ending token
        address  tokenOut;        // intermediate token
        // Slippage guard
        uint256  expectedAmountOut; // quoted by bot via QuoterV2; used to detect positive/negative slippage
    }

    /// @dev Internal callback data passed through poolManager.unlock
    struct CallbackData {
        ArbitrageParams arb;
        address         sender;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(uint8 _maxLoops, uint256 _ltvBps, uint256 _minProfitableAmount) {
        owner               = msg.sender;
        poolManager         = IPoolManager(POOL_MANAGER_ADDR);
        aavePool            = IAavePool(AAVE_POOL_ADDR);
        swapRouter          = ISwapRouter02(SWAP_ROUTER_02);
        maxLoops            = _maxLoops;
        ltvBps              = _ltvBps;
        minProfitableAmount = _minProfitableAmount;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Owner helpers
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function setMaxLoops(uint8 _maxLoops) external onlyOwner {
        maxLoops = _maxLoops;
    }

    function setLtvBps(uint256 _ltvBps) external onlyOwner {
        ltvBps = _ltvBps;
    }

    function setMinProfitableAmount(uint256 _minAmount) external onlyOwner {
        minProfitableAmount = _minAmount;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    /// @notice Rescue any tokens accidentally left in the contract
    function rescueERC20(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Entry point (called by keeper.js every second)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Trigger an arbitrage cycle.
    ///         The bot should first simulate via `eth_call`; if it reverts, no tx is sent.
    /// @param p  Arbitrage parameters (see ArbitrageParams)
    function executeArbitrage(ArbitrageParams calldata p) external {
        bytes memory callbackData = abi.encode(
            CallbackData({arb: p, sender: msg.sender})
        );
        poolManager.unlock(callbackData);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Uniswap V4 unlock callback  —  all atomic logic lives here
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata callbackData)
        external
        override
        returns (bytes memory)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        CallbackData memory cb  = abi.decode(callbackData, (CallbackData));
        ArbitrageParams memory p = cb.arb;

        // ── Step 1: Borrow via V4 flash loan ─────────────────────────────────
        poolManager.take(p.flashCurrency, address(this), p.flashAmount);

        // ── Step 2: Two-leg arbitrage swap ────────────────────────────────────
        // Leg 1 — flash-swap on pool0: tokenIn → tokenOut
        // Leg 2 — buy-back on pool1 via SwapRouter02: tokenOut → tokenIn
        uint256 amountOut = _twoLegSwap(
            p.pool0, p.fee1, p.tokenIn, p.tokenOut, p.flashAmount
        );

        // ── Profitability gate ────────────────────────────────────────────────
        // Revert if we did not at least break even; the bot's eth_call will
        // catch this before sending a real tx.
        if (amountOut <= p.flashAmount) {
            revert NoProfitOrRevert(amountOut, p.flashAmount);
        }

        uint256 arbProfit = amountOut - p.flashAmount;

        // ── Step 3: Withdraw arbitrage profit immediately ─────────────────────
        IERC20(p.tokenIn).transfer(owner, arbProfit);

        // ── Step 4: Slippage classification ───────────────────────────────────
        bool positiveSlippage = amountOut >= p.expectedAmountOut;

        // ── Step 5+6: Aave leverage loop (positive slippage only) ─────────────
        uint256 loopProfit  = 0;
        uint8   loopsRun    = 0;

        if (positiveSlippage && maxLoops > 0) {
            // Remaining balance = flashAmount (profit already sent to owner)
            AaveLeverageLib.LoopState memory state = _runLeverageLoop(
                p.tokenIn,
                p.flashAmount,
                loopProfit,
                loopsRun
            );
            loopsRun = state.loops;

            // Unwind all Aave positions
            AaveLeverageLib.unwindLoop(aavePool, p.tokenIn, state);
        }

        // ── Step 7: Repay the V4 flash loan ───────────────────────────────────
        _repayFlashLoan(p.flashCurrency, p.flashAmount);

        emit ArbitrageExecuted(p.tokenIn, p.flashAmount, arbProfit, loopProfit, loopsRun);

        return bytes("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Execute the two-leg V3 cross-pool arbitrage.
    ///      Leg 1: flash-swap on pool0 (tokenIn → tokenOut) — we receive tokenOut.
    ///      Leg 2: swap on pool1 via SwapRouter02 (tokenOut → tokenIn) — we receive tokenIn.
    ///      Returns the total tokenIn received after both legs.
    function _twoLegSwap(
        address pool0,
        uint24  fee1,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal returns (uint256 amountReceived) {
        bool zeroForOne = tokenIn < tokenOut;
        uint160 sqrtPriceLimitX96 = zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1;

        bytes memory swapData = abi.encode(fee1, tokenIn, tokenOut, amountIn, zeroForOne);

        // Initiate V3 flash-swap on pool0 — triggers uniswapV3SwapCallback
        IUniswapV3Pool(pool0).swap({
            recipient:        address(this),
            zeroForOne:       zeroForOne,
            amountSpecified:  int256(amountIn),
            sqrtPriceLimitX96: sqrtPriceLimitX96,
            data:             swapData
        });

        // After the callback, this contract holds tokenIn balance
        amountReceived = IERC20(tokenIn).balanceOf(address(this));
    }

    /// @dev Uniswap V3 swap callback: receives tokenOut, swaps back to tokenIn via pool1,
    ///      repays pool0, and keeps the profit in the contract.
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        (uint24 fee1, address tokenIn, address tokenOut, uint256 amountIn, bool zeroForOne)
            = abi.decode(data, (uint24, address, address, uint256, bool));

        // Amount of tokenOut we received from pool0
        uint256 tokenOutAmount = zeroForOne
            ? uint256(-amount1Delta)
            : uint256(-amount0Delta);

        // Leg 2: swap tokenOut → tokenIn via SwapRouter02 on pool1
        IERC20(tokenOut).approve(address(swapRouter), tokenOutAmount);

        ISwapRouter02.ExactInputSingleParams memory params = ISwapRouter02.ExactInputSingleParams({
            tokenIn:           tokenOut,
            tokenOut:          tokenIn,
            fee:               fee1,
            recipient:         address(this),
            amountIn:          tokenOutAmount,
            amountOutMinimum:  amountIn, // must at least recover flash-swap debt
            sqrtPriceLimitX96: 0
        });
        swapRouter.exactInputSingle(params);

        // Repay pool0 with the original tokenIn amount
        IERC20(tokenIn).transfer(msg.sender, amountIn);
    }

    /// @dev Run the Aave leverage loop using a function pointer for the per-loop swap.
    ///      Accumulates loopProfit and loopsRun via the out-params.
    function _runLeverageLoop(
        address tokenIn,
        uint256 startAmount,
        uint256 loopProfitOut,
        uint8   loopsRunOut
    ) internal returns (AaveLeverageLib.LoopState memory state) {
        state = AaveLeverageLib.leverageLoop(
            aavePool,
            tokenIn,
            startAmount,
            ltvBps,
            maxLoops,
            minProfitableAmount,
            _loopSwap
        );
        // loopProfitOut and loopsRunOut are updated by the swaps inside the library;
        // we track them via events and the state struct.
        loopProfitOut = 0; // placeholder; actual profit forwarded to owner in _loopSwap
        loopsRunOut   = state.loops;
    }

    /// @dev Per-iteration swap inside the leverage loop.
    ///      Swaps `amount` of `asset` → intermediate → back to `asset`,
    ///      sends any profit to `owner`, and returns the amount of `asset` received.
    ///
    ///      Note: For simplicity, the leverage loop reuses the same pool0/fee1 pair
    ///      stored from the original flash-loan params.  In production the bot can
    ///      pass per-iteration routing via the params struct.
    ///
    ///      This function signature matches AaveLeverageLib's swapFn type:
    ///        function(address, uint256) internal returns (uint256)
    function _loopSwap(address asset, uint256 amount) internal returns (uint256 amountOut) {
        // We perform a simple single-hop swap: asset → WETH → asset
        // using a fixed fee tier (0.05%).  The bot configures the pair at deployment.
        // This is intentionally kept flexible — override for more complex routing.
        uint24 feeTier = 500; // 0.05% pool — most liquid for WETH/USDC/DAI

        IERC20(asset).approve(address(swapRouter), amount);

        // Swap out to WETH (or any liquid intermediate) and back
        // For a single-token cycle this is a round-trip; profit comes from
        // the slippage advantage accumulated during the loop.
        address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

        // Only attempt the round-trip if asset is not WETH itself
        if (asset == weth) {
            // Direct swap: WETH → USDC → WETH (using 0.05% pools)
            address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
            uint256 usdcOut = _singleSwap(asset, usdc, feeTier, amount, 0);
            amountOut = _singleSwap(usdc, asset, feeTier, usdcOut, 0);
        } else {
            // asset → WETH → asset round trip
            uint256 wethOut = _singleSwap(asset, weth, feeTier, amount, 0);
            amountOut = _singleSwap(weth, asset, feeTier, wethOut, 0);
        }

        // Forward any loop profit to owner
        if (amountOut > amount) {
            uint256 loopProfit = amountOut - amount;
            IERC20(asset).transfer(owner, loopProfit);
            amountOut = amount; // return exactly the borrowed amount for unwind
        }
        // If amountOut < amount, the difference comes out of the collateral during unwind.
        // The flash loan principal is untouched.
    }

    /// @dev Execute a single exactInputSingle swap via SwapRouter02.
    function _singleSwap(
        address tokenIn,
        address tokenOut,
        uint24  fee,
        uint256 amountIn,
        uint256 amountOutMinimum
    ) internal returns (uint256 amountOut) {
        IERC20(tokenIn).approve(address(swapRouter), amountIn);
        amountOut = swapRouter.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn:           tokenIn,
                tokenOut:          tokenOut,
                fee:               fee,
                recipient:         address(this),
                amountIn:          amountIn,
                amountOutMinimum:  amountOutMinimum,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @dev Repay the Uniswap V4 flash loan (settle the open delta).
    function _repayFlashLoan(Currency currency, uint256 amount) internal {
        address token = Currency.unwrap(currency);
        if (token == address(0)) {
            // Native ETH
            poolManager.settle{value: amount}(currency);
        } else {
            IERC20(token).transfer(address(poolManager), amount);
            poolManager.settle(currency);
        }
    }

    receive() external payable {}
}

// ─────────────────────────────────────────────────────────────────────────────
//  Interfaces
// ─────────────────────────────────────────────────────────────────────────────

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function settle(Currency currency) external payable returns (uint256);
    function take(Currency currency, address to, uint256 amount) external;
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
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
        external
        payable
        returns (uint256 amountOut);
}

interface IUniswapV3Pool {
    function swap(
        address recipient,
        bool    zeroForOne,
        int256  amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes   calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount)
        external returns (bool);
}
