// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {MarketParams, Market} from "morpho/interfaces/IMorpho.sol";

/// @title MockDivergentMorphoIRM
/// @notice Morpho IRM whose view rate strictly exceeds its mutate rate.
/// @dev Twyne sizes a Morpho repay with `MorphoBalancesLib.expectedBorrowAssets`, which accrues interest
///      via `IIrm.borrowRateView`, whereas `IMorpho.repay` accrues via `IIrm.borrowRate`. Morpho's real
///      IRMs return identical values from both, so the two always agree; this mock makes the view debt
///      accrue faster than the real debt so the amount Twyne forwards exceeds what `repay` consumes.
///      That difference is refunded by the collateral vault to whoever forwarded it.
///      Rates are constants (not storage) so `vm.etch(addr, runtimeCode)` works with no constructor.
contract MockDivergentMorphoIRM {
    /// @dev per-second rate, WAD-scaled (~0.1% over 1000s).
    uint256 public constant REAL_RATE = 1e12;
    /// @dev 2x the real rate, so the view debt accrues faster than the real debt.
    uint256 public constant VIEW_RATE = 2e12;

    function borrowRate(MarketParams calldata, Market calldata) external returns (uint256) {
        return REAL_RATE;
    }

    function borrowRateView(MarketParams calldata, Market calldata) external view returns (uint256) {
        return VIEW_RATE;
    }
}
