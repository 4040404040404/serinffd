// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAavePool} from "./interfaces/IAavePool.sol";

/// @notice Internal library that encapsulates the Aave V3 leveraged supply/borrow loop
///         and its mirror unwind loop.
///
/// Flow (per loop iteration):
///   supply(balance) → borrow(balance * ltv) → caller performs arbitrage swap on borrowed amount
///   → profit forwarded to owner → next iteration uses borrowed amount as new balance
///
/// Unwind (reverse order):
///   repay(borrowAmount[i]) → withdraw(supplyAmount[i])
///
/// All amounts are tracked in the LoopState struct and returned to the caller so the
/// unwind can be executed without additional storage.
library AaveLeverageLib {
    uint256 private constant VARIABLE_RATE = 2;
    uint16  private constant REFERRAL_CODE = 0;

    struct LoopState {
        uint256[10] supplyAmounts; // collateral deposited at each level
        uint256[10] borrowAmounts; // debt taken at each level
        uint8 loops;               // number of completed iterations
    }

    /// @notice Execute the leverage loop: supply → borrow → (caller swaps) → repeat.
    ///
    /// @param aavePool    Aave V3 IPool
    /// @param asset       The ERC-20 token being cycled
    /// @param startAmount Starting balance (= flash loan principal minus profit already extracted)
    /// @param ltvBps      Loan-to-value in basis points (e.g. 7500 = 75 %).
    ///                    Should be set conservatively below Aave's actual LTV to avoid HF = 1.
    /// @param maxLoops    Maximum number of supply/borrow iterations (capped at 10)
    /// @param minAmount   Minimum borrowAmount that is worth looping for (gas threshold)
    /// @param swapFn      A function pointer that executes an arbitrage swap on `borrowAmount`
    ///                    and returns (amountOut).  The library approves `asset` for the caller
    ///                    before calling swapFn; the caller must transfer any profit to owner.
    ///
    /// @return state      Filled LoopState used by unwindLoop to reverse positions
    function leverageLoop(
        IAavePool aavePool,
        address asset,
        uint256 startAmount,
        uint256 ltvBps,
        uint8 maxLoops,
        uint256 minAmount,
        function(address, uint256) internal returns (uint256) swapFn
    ) internal returns (LoopState memory state) {
        uint8 cap = maxLoops > 10 ? 10 : maxLoops;
        uint256 balance = startAmount;

        for (uint8 i = 0; i < cap; i++) {
            uint256 borrowAmount = (balance * ltvBps) / 10_000;
            if (borrowAmount < minAmount) break;

            // Supply current balance as collateral
            IERC20(asset).approve(address(aavePool), balance);
            aavePool.supply(asset, balance, address(this), REFERRAL_CODE);
            state.supplyAmounts[i] = balance;

            // Borrow against collateral
            aavePool.borrow(asset, borrowAmount, VARIABLE_RATE, REFERRAL_CODE, address(this));
            state.borrowAmounts[i] = borrowAmount;
            state.loops = i + 1;

            // Execute an arbitrage swap on the borrowed amount
            // swapFn is responsible for transferring profit to owner and returning amountOut
            uint256 amountOut = swapFn(asset, borrowAmount);

            // Use the actual received amount as the next loop's balance so the
            // unwind can repay the exact borrowed amount from the swap proceeds
            balance = amountOut;
        }
    }

    /// @notice Unwind all Aave positions created by leverageLoop, innermost first.
    ///
    /// @param aavePool  Aave V3 IPool
    /// @param asset     The ERC-20 token
    /// @param state     The LoopState returned by leverageLoop
    function unwindLoop(IAavePool aavePool, address asset, LoopState memory state) internal {
        for (int8 i = int8(state.loops) - 1; i >= 0; i--) {
            uint8 idx = uint8(uint8(i));
            uint256 borrow  = state.borrowAmounts[idx];
            uint256 supply  = state.supplyAmounts[idx];

            // Approve repayment
            IERC20(asset).approve(address(aavePool), borrow);
            aavePool.repay(asset, borrow, VARIABLE_RATE, address(this));

            // Recover collateral
            aavePool.withdraw(asset, supply, address(this));
        }
    }
}

/// @dev Minimal ERC-20 interface used inside the library
interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
}
