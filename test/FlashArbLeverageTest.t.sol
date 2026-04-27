// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../FlashArbLeverage.sol";

// ── Mainnet token addresses ───────────────────────────────────────────────────
address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

// Uniswap V3 USDC/WETH pools
uint24  constant FEE_05  = 500;
uint24  constant FEE_30  = 3000;

// Aave V3 aToken for USDC (to check supply position)
address constant A_USDC  = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;

interface IAToken {
    function balanceOf(address) external view returns (uint256);
}

interface IWeth {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
}

interface ISwapRouterV3 {
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

/**
 * @title  FlashArbLeverageTest
 * @notice Mainnet-fork integration tests for FlashArbLeverage.
 *
 * Run:
 *   forge test --fork-url $ETH_RPC_URL -vvvv
 */
contract FlashArbLeverageTest is Test {

    // ── state ─────────────────────────────────────────────────────────────────
    FlashArbLeverage public arb;
    address          public owner;

    // Uniswap V3 router (same as SWAP_ROUTER_02 in the contract)
    ISwapRouterV3 constant router =
        ISwapRouterV3(0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45);

    // Flash loan amount: 500 000 USDC (6 decimals)
    uint256 constant FLASH_AMT = 500_000e6;

    // ── setup ─────────────────────────────────────────────────────────────────
    function setUp() public {
        owner = address(this);
        arb   = new FlashArbLeverage();

        // Seed the test contract with WETH so we can create an arb opportunity
        IWeth(WETH).deposit{value: 500 ether}();
        IERC20(WETH).approve(address(router), 500 ether);

        // Push WETH into the 0.05% pool to skew the price relative to 0.3% pool,
        // creating a cross-pool price discrepancy that the arb can exploit.
        router.exactInputSingle(
            ISwapRouterV3.ExactInputSingleParams({
                tokenIn:           WETH,
                tokenOut:          USDC,
                fee:               FEE_05,
                recipient:         address(this),
                amountIn:          300 ether,
                amountOutMinimum:  0,
                sqrtPriceLimitX96: 0
            })
        );
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _buildParams(uint256 minProfit)
        internal pure returns (FlashArbLeverage.ArbParams memory)
    {
        return FlashArbLeverage.ArbParams({
            tokenIn:     USDC,
            tokenOut:    WETH,
            flashAmount: FLASH_AMT,
            fee0:        FEE_30,   // buy WETH cheaply here
            fee1:        FEE_05,   // sell WETH at premium here
            minProfit:   minProfit
        });
    }

    // ── tests ─────────────────────────────────────────────────────────────────

    /**
     * @notice Basic arb executes and contract remains solvent (no revert).
     * @dev minProfit = 0 so the Aave step triggers on any positive output.
     */
    function test_ArbExecutesSuccessfully() public {
        arb.executeArb(_buildParams(0));
    }

    /**
     * @notice With a price skew in place, an arb with minProfit=0 should
     *         deposit profit into Aave and leave an aUSDC balance in the contract.
     */
    function test_ProfitDepositedToAave() public {
        uint256 aBalBefore = IAToken(A_USDC).balanceOf(address(arb));
        arb.executeArb(_buildParams(0));
        uint256 aBalAfter  = IAToken(A_USDC).balanceOf(address(arb));
        assertGt(aBalAfter, aBalBefore, "no aUSDC balance after profitable arb");
    }

    /**
     * @notice When minProfit is set very high the Aave step is skipped but the
     *         call should still succeed (no revert).
     */
    function test_HighMinProfitSkipsAave() public {
        uint256 aBalBefore = IAToken(A_USDC).balanceOf(address(arb));
        // minProfit = 1 billion USDC — impossible to meet
        arb.executeArb(_buildParams(1_000_000_000e6));
        uint256 aBalAfter  = IAToken(A_USDC).balanceOf(address(arb));
        // Aave balance should be unchanged (no deposit)
        assertEq(aBalAfter, aBalBefore, "Aave deposit should be skipped");
    }

    /**
     * @notice collectYield withdraws the aUSDC balance to the owner.
     */
    function test_CollectYield() public {
        arb.executeArb(_buildParams(0));

        uint256 ownerBalBefore = IERC20(USDC).balanceOf(owner);
        arb.collectYield(USDC, type(uint256).max);
        uint256 ownerBalAfter  = IERC20(USDC).balanceOf(owner);

        assertGt(ownerBalAfter, ownerBalBefore, "collectYield: owner balance unchanged");
    }

    /**
     * @notice unwindPosition fully exits the Aave position, leaving no debt.
     */
    function test_UnwindPosition() public {
        arb.executeArb(_buildParams(0));

        arb.unwindPosition(USDC);

        (, uint256 totalDebt,,,,) =
            IAavePool(AAVE_POOL).getUserAccountData(address(arb));
        assertEq(totalDebt, 0, "debt remaining after unwind");
    }

    /**
     * @notice Only the owner can call executeArb.
     */
    function test_OnlyOwner() public {
        vm.prank(address(0xdead));
        vm.expectRevert(FlashArbLeverage.NotOwner.selector);
        arb.executeArb(_buildParams(0));
    }

    /**
     * @notice rescueTokens sends the contract balance to the owner.
     */
    function test_RescueTokens() public {
        // Donate some USDC directly to the contract
        deal(USDC, address(arb), 1_000e6);

        uint256 before = IERC20(USDC).balanceOf(owner);
        arb.rescueTokens(USDC);
        assertEq(IERC20(USDC).balanceOf(owner), before + 1_000e6);
    }
}
