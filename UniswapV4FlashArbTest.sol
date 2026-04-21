// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {
    UniswapV4FlashArb,
    IPoolManager,
    IUnlockCallback,
    IERC20,
    PoolKey,
    BalanceDelta,
    BalanceDeltaLibrary,
    Currency,
    CurrencyLibrary,
    MIN_SQRT_PRICE,
    MAX_SQRT_PRICE,
    POOL_MANAGER
} from "./UniswapV4FlashArb.sol";

// ── Well-known mainnet addresses ────────────────────────────────────────────
address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant DAI  = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

// WETH(0xC02..) > DAI(0x6B1..) → DAI = currency0, WETH = currency1
// V4 DAI/WETH pool @ 0.3 % fee, tick-spacing 60  (imbalanced in setUp)
uint24  constant FEE_3000 = 3000;
int24   constant TICK_60  = 60;
// V4 DAI/WETH pool @ 0.05 % fee, tick-spacing 10  (reference price)
uint24  constant FEE_500  = 500;
int24   constant TICK_10  = 10;

interface IWETH is IERC20 {
    function deposit() external payable;
}

// ─────────────────────────────────────────────────────────────────────────────
/// @notice Foundry fork test for UniswapV4FlashArb.
///
/// Prerequisites
/// ─────────────
/// 1. Install forge-std:   forge install foundry-rs/forge-std --no-commit
/// 2. Set env variable:    export MAINNET_RPC_URL="https://<your-node>/..."
/// 3. Run:                 forge test --match-contract UniswapV4FlashArbTest -vvv
///
/// What the test does
/// ──────────────────
/// setUp():
///   • Forks Ethereum mainnet.
///   • Deploys UniswapV4FlashArb.
///   • Wraps 500 ETH → WETH, then dumps all of it into the DAI/WETH 0.3 %
///     V4 pool via a direct PoolManager swap. This depresses the WETH price
///     on that pool (lots of WETH, few DAI), while the 0.05 % pool price is
///     unchanged, creating a cross-pool arbitrage opportunity.
///
/// test_flashArb():
///   • Calls arb.flashArb() with the two pool keys, borrowToken=DAI,
///     outputToken=WETH, and amountIn = 100 DAI.
///   • Asserts that this address (the caller) received more DAI than it
///     started with (profit > 0).
// ─────────────────────────────────────────────────────────────────────────────
contract UniswapV4FlashArbTest is Test, IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;

    UniswapV4FlashArb private arb;
    IPoolManager      private poolManager;

    // DAI amount used for the arb (100 DAI)
    uint256 private constant ARB_AMOUNT = 100e18;
    // WETH amount used to imbalance pool0 (500 WETH)
    uint256 private constant IMBALANCE_WETH = 500e18;

    // Flag distinguishing the setup-imbalance callback from unexpected calls
    bytes32 private constant IMBALANCE_MAGIC = keccak256("imbalance");
    bool private _inImbalanceCallback;

    PoolKey private pool0; // DAI/WETH 0.3 % (will be imbalanced)
    PoolKey private pool1; // DAI/WETH 0.05 % (reference price)

    // ── Setup ─────────────────────────────────────────────────────────────
    function setUp() public {
        // Fork mainnet at the latest block; set MAINNET_RPC_URL in environment.
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        poolManager = IPoolManager(POOL_MANAGER);
        arb = new UniswapV4FlashArb();

        // Build pool keys (currency0 < currency1 required by V4)
        pool0 = PoolKey({
            currency0:   Currency.wrap(DAI),
            currency1:   Currency.wrap(WETH),
            fee:         FEE_3000,
            tickSpacing: TICK_60,
            hooks:       address(0)
        });
        pool1 = PoolKey({
            currency0:   Currency.wrap(DAI),
            currency1:   Currency.wrap(WETH),
            fee:         FEE_500,
            tickSpacing: TICK_10,
            hooks:       address(0)
        });

        // Fund this test contract with WETH for the imbalancing swap
        deal(WETH, address(this), IMBALANCE_WETH);
        IERC20(WETH).approve(POOL_MANAGER, type(uint256).max);

        // Imbalance pool0: sell 500 WETH on DAI/WETH 0.3 % → WETH becomes
        // cheap on pool0, DAI/WETH 0.05 % retains normal price → arb gap opens.
        _inImbalanceCallback = true;
        poolManager.unlock(abi.encode(IMBALANCE_MAGIC));
        _inImbalanceCallback = false;
    }

    // ── IUnlockCallback implementation (setup step only) ──────────────────
    /// @dev This callback is invoked by the PoolManager during setUp() to
    ///      execute the large imbalancing WETH→DAI swap on pool0.
    function unlockCallback(bytes calldata data)
        external
        override
        returns (bytes memory)
    {
        require(msg.sender == POOL_MANAGER,    "not poolManager");
        require(_inImbalanceCallback,           "unexpected callback");
        bytes32 magic = abi.decode(data, (bytes32));
        require(magic == IMBALANCE_MAGIC,      "wrong magic");

        // Sell WETH (currency1) for DAI (currency0) on pool0.
        // zeroForOne = false → selling currency1 (WETH).
        BalanceDelta delta = poolManager.swap(
            pool0,
            IPoolManager.SwapParams({
                zeroForOne:        false,
                amountSpecified:   -int256(IMBALANCE_WETH), // exact WETH input
                sqrtPriceLimitX96: MAX_SQRT_PRICE - 1       // no price ceiling
            }),
            bytes("")
        );

        // delta.amount1() < 0 → we owe WETH to pool0: settle
        int128 wethOwed = delta.amount1();
        require(wethOwed < 0, "unexpected weth delta");
        uint256 wethIn = uint256(uint128(-wethOwed));
        IERC20(WETH).transfer(POOL_MANAGER, wethIn);
        poolManager.settle(Currency.wrap(WETH));

        // delta.amount0() > 0 → pool0 owes us DAI: take (discard; we don't need it)
        int128 daiOwed = delta.amount0();
        require(daiOwed > 0, "unexpected dai delta");
        uint256 daiOut = uint256(uint128(daiOwed));
        poolManager.take(Currency.wrap(DAI), address(this), daiOut);

        return bytes("");
    }

    // ── Test ──────────────────────────────────────────────────────────────
    function test_flashArb() public {
        // Fund this address with enough DAI so the profit measurement is clean.
        // (The arb contract uses flash accounting — no initial capital required.)
        uint256 daiBefore = IERC20(DAI).balanceOf(address(this));

        console2.log("DAI balance before arb:", daiBefore);

        arb.flashArb({
            pool0:       pool0,
            pool1:       pool1,
            borrowToken: Currency.wrap(DAI),
            outputToken: Currency.wrap(WETH),
            amountIn:    ARB_AMOUNT
        });

        uint256 daiAfter = IERC20(DAI).balanceOf(address(this));
        console2.log("DAI balance after  arb:", daiAfter);
        uint256 profit = daiAfter - daiBefore;
        console2.log("Profit (DAI)          :", profit);

        assertGt(profit, 0, "expected positive DAI profit");
    }

    // ── Helper: ensure this contract can receive ETH ───────────────────────
    receive() external payable {}
}
