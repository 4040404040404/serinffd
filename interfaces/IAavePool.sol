// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Subset of the Aave V3 IPool interface used by FlashArbitrageBot
interface IAavePool {
    /// @notice Deposits an `amount` of underlying asset into the reserve, receiving in return overlying aTokens.
    /// @param asset The address of the underlying asset to deposit
    /// @param amount The amount to be deposited
    /// @param onBehalfOf The address that will receive the aTokens
    /// @param referralCode Code used to register the integrator originating the operation (0 if none)
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @notice Allows users to borrow a specific `amount` of the reserve underlying asset.
    /// @param asset The address of the underlying asset to borrow
    /// @param amount The amount to be borrowed
    /// @param interestRateMode 1 for Stable, 2 for Variable
    /// @param referralCode The code used to register the integrator (0 if none)
    /// @param onBehalfOf The address that will receive the debt tokens
    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) external;

    /// @notice Repays a borrowed `amount` on a specific reserve.
    /// @param asset The address of the underlying asset to repay
    /// @param amount The amount to repay (use type(uint256).max to repay the whole debt)
    /// @param interestRateMode 1 for Stable, 2 for Variable
    /// @param onBehalfOf The address of the user who will get their debt reduced
    /// @return The final amount repaid
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);

    /// @notice Withdraws an `amount` of underlying asset from the reserve.
    /// @param asset The address of the underlying asset to withdraw
    /// @param amount The underlying amount to be withdrawn (use type(uint256).max to withdraw the whole aToken balance)
    /// @param to The address that will receive the underlying
    /// @return The final amount withdrawn
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    /// @notice Returns the user account data across all the reserves
    /// @param user The address of the user
    /// @return totalCollateralBase Total collateral of the user in the base currency
    /// @return totalDebtBase Total debt of the user in the base currency
    /// @return availableBorrowsBase Available borrows of the user in the base currency
    /// @return currentLiquidationThreshold Current liquidation threshold of the user
    /// @return ltv Loan to Value of the user
    /// @return healthFactor Current health factor of the user
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}
