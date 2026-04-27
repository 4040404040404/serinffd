// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

// ─── Addresses ───────────────────────────────────────────────────────────────
address constant WETH      = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant DAI       = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
address constant USDC      = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

// Uniswap V3 pools
address constant DAI_WETH_3000 = 0xC2e9F25Be6257c210d7Adf0D4Cd6E3E881ba25f8;
address constant DAI_WETH_500  = 0x60594a405d53811d3BC4766596EFD80fd545A270;

// Uniswap V4 PoolManager
address constant POOL_MANAGER  = 0x000000000004444c5dc75cB358380D2e3dE08A90;

// Aave V3
address constant AAVE_POOL     = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

// Swap router
address constant SWAP_ROUTER   = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

// ─── Minimal interfaces ───────────────────────────────────────────────────────
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IWETH is IERC20 {
    function deposit() external payable;
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
    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
}

// ─────────────────────────────────────────────────────────────────────────────
//  Inline stub of FlashArbitrageBot so the test can import it directly.
//  In a real Foundry project this would be: import "../FlashArbitrageBot.sol";
// ─────────────────────────────────────────────────────────────────────────────

// Re-use the Currency type from the bot
type Currency is address;

interface IFlashArbitrageBot {
    struct ArbitrageParams {
        Currency flashCurrency;
        uint256  flashAmount;
        address  pool0;
        uint24   fee1;
        address  tokenIn;
        address  tokenOut;
        uint256  expectedAmountOut;
    }
    function executeArbitrage(ArbitrageParams calldata p) external;
    function owner() external view returns (address);
}

// ─────────────────────────────────────────────────────────────────────────────
//  Test contract
// ─────────────────────────────────────────────────────────────────────────────

/// @title  FlashArbitrageBotTest
/// @notice Foundry fork test.
///         - Manufactures an arbitrage opportunity by imbalancing the DAI/WETH 0.3% pool.
///         - Calls FlashArbitrageBot.executeArbitrage and asserts profit > 0.
///
/// Run with:
///   forge test --fork-url $ETH_RPC_URL --match-path test/FlashArbitrageBot.t.sol -vv
///
/// @dev    The test deploys the bot from source.  Because the sol file lives one
///         directory up, Foundry's default remappings find it automatically.
///         Adjust the import path if your foundry.toml uses a src/ layout.
contract FlashArbitrageBotTest is Test {
    // ── Constants ─────────────────────────────────────────────────────────────
    uint24  constant FEE_3000 = 3000;
    uint24  constant FEE_500  = 500;
    uint256 constant FLASH_AMOUNT = 10_000e18; // 10 000 DAI

    // ── State ─────────────────────────────────────────────────────────────────
    IFlashArbitrageBot bot;
    IWETH  weth = IWETH(WETH);
    IERC20 dai  = IERC20(DAI);
    ISwapRouter02 router = ISwapRouter02(SWAP_ROUTER);

    // ── Setup ─────────────────────────────────────────────────────────────────
    function setUp() public {
        // Deploy the bot (constructor: maxLoops=6, ltvBps=7125, minProfitable=1e15)
        // We use vm.deployCode so the test does not need to import the full contract.
        // Adjust the path to match your project layout.
        address deployed = deployCode(
            "FlashArbitrageBot.sol:FlashArbitrageBot",
            abi.encode(uint8(6), uint256(7125), uint256(1e15))
        );
        bot = IFlashArbitrageBot(deployed);

        // ── Manufacture an arbitrage opportunity ──────────────────────────────
        // Dump 500 WETH into the 0.3% DAI/WETH pool to cheapen WETH there.
        // The 0.05% pool retains a higher WETH price, creating a spread.
        weth.deposit{value: 500 ether}();
        weth.approve(address(router), 500 ether);
        router.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn:           WETH,
                tokenOut:          DAI,
                fee:               FEE_3000,
                recipient:         address(0), // burn output — we only want price impact
                amountIn:          500 ether,
                amountOutMinimum:  0,
                sqrtPriceLimitX96: 0
            })
        );
    }

    // ── Tests ──────────────────────────────────────────────────────────────────

    /// @notice Happy path: flash loan + arbitrage should yield profit.
    function test_executeArbitrage_profitGreaterThanZero() public {
        address ownerAddr = bot.owner();
        uint256 balBefore = dai.balanceOf(ownerAddr);

        IFlashArbitrageBot.ArbitrageParams memory p = IFlashArbitrageBot.ArbitrageParams({
            flashCurrency:     Currency.wrap(DAI),
            flashAmount:       FLASH_AMOUNT,
            pool0:             DAI_WETH_3000,  // leg 1: DAI → WETH (cheaper WETH here)
            fee1:              FEE_500,         // leg 2: WETH → DAI (higher price here)
            tokenIn:           DAI,
            tokenOut:          WETH,
            expectedAmountOut: FLASH_AMOUNT    // set equal to flash amount: any extra = positive slippage
        });

        bot.executeArbitrage(p);

        uint256 balAfter  = dai.balanceOf(ownerAddr);
        uint256 profit    = balAfter - balBefore;
        assertGt(profit, 0, "Expected arbitrage profit > 0");
        console2.log("Arbitrage profit (DAI): %e", profit);
    }

    /// @notice Negative slippage path: if expectedAmountOut is set very high the
    ///         bot should skip the Aave loop and still repay the flash loan without reverting.
    function test_executeArbitrage_negativeSlippage_noRevert() public {
        // Set expectedAmountOut to an unrealistically large number to force negative-slippage path.
        // The arb still needs to be profitable (amountOut > flashAmount) to not revert on profit gate.
        IFlashArbitrageBot.ArbitrageParams memory p = IFlashArbitrageBot.ArbitrageParams({
            flashCurrency:     Currency.wrap(DAI),
            flashAmount:       FLASH_AMOUNT,
            pool0:             DAI_WETH_3000,
            fee1:              FEE_500,
            tokenIn:           DAI,
            tokenOut:          WETH,
            expectedAmountOut: type(uint256).max  // impossible to beat → negative slippage path
        });

        // Should not revert — safety protocol skips Aave loop
        bot.executeArbitrage(p);
    }

    /// @notice No-profit scenario: expect revert with NoProfitOrRevert when pools are balanced.
    function test_executeArbitrage_revertsWhenNoProfit() public {
        // Use same pool for both legs → no price difference → will revert
        IFlashArbitrageBot.ArbitrageParams memory p = IFlashArbitrageBot.ArbitrageParams({
            flashCurrency:     Currency.wrap(DAI),
            flashAmount:       FLASH_AMOUNT,
            pool0:             DAI_WETH_3000,
            fee1:              FEE_3000,         // same fee tier → negligible spread → likely no profit
            tokenIn:           DAI,
            tokenOut:          WETH,
            expectedAmountOut: FLASH_AMOUNT
        });

        // NoProfitOrRevert(uint256,uint256) selector
        vm.expectRevert();
        bot.executeArbitrage(p);
    }
}
