// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.28;

import {IIRM} from "euler-vault-kit/InterestRateModels/IIRM.sol";
import {SECONDS_PER_YEAR} from "euler-vault-kit/EVault/shared/Constants.sol";

/// @title IRMTwyneCurveGamma32
/// @notice To contact the team regarding security matters, visit https://twyne.xyz/security
/// @notice Implementation of a curved interest rate model with gamma of 32
/// @notice interest rate grows linearly with utilization and increases faster after reaching a kink
contract IRMTwyneCurveGamma32 is IIRM {
    /// @notice Approx interest rate at linearKinkUtilizationRate
    uint public immutable idealKinkInterestRate; // 0.6e4 = 60%
    /// @notice Utilization rate value used in calculating IRM parameters
    /// @notice beyond this utilization rate, the polynomial term dominates (this value must be greater than nonlinearPoint)
    /// @notice while this is a utilization rate that would have 1e18 decimals, it is ONLY used to derive curve params so use 1e4
    uint public immutable linearKinkUtilizationRate; // 0.8e4 = 80%
    /// @notice Max interest rate applied at 100% utilization
    uint public immutable maxInterestRate; // 5e4 = 500%

    /// @notice When utilization rate is less than nonlinearPoint, assume linear model (polynomial term is not significant)
    uint public immutable nonlinearPoint; // 5e17 = 50%

    /// @notice Curve parameters
    uint public immutable linearParameter;
    uint public immutable polynomialParameter;

    /// @notice LTV values have 1e4 decimals
    uint internal constant MAXFACTOR = 1e4;

    constructor(uint16 idealKinkInterestRate_, uint16 linearKinkUtilizationRate_, uint16 maxInterestRate_, uint nonlinearPoint_) {
        if (
            idealKinkInterestRate_ > maxInterestRate_
            || linearKinkUtilizationRate_ > MAXFACTOR
            // || idealKinkInterestRate_ == 0
            || linearKinkUtilizationRate_ == 0
            || maxInterestRate_ == 0
            || nonlinearPoint_ == 0
            || nonlinearPoint_ >= 1e14 * uint(linearKinkUtilizationRate_) // 1e14 is to align decimals
        ) revert E_IRMUpdateUnauthorized();

        idealKinkInterestRate = idealKinkInterestRate_;
        linearKinkUtilizationRate = linearKinkUtilizationRate_;
        maxInterestRate = maxInterestRate_;
        nonlinearPoint = nonlinearPoint_;
        linearParameter = idealKinkInterestRate * MAXFACTOR / linearKinkUtilizationRate_;
        polynomialParameter = maxInterestRate_ - linearParameter;
    }

    /// @inheritdoc IIRM
    function computeInterestRate(address vault, uint cash, uint borrows)
        external
        view
        override
        returns (uint)
    {
        if (msg.sender != vault) revert E_IRMUpdateUnauthorized();

        return computeInterestRateInternal(vault, cash, borrows);
    }

    /// @inheritdoc IIRM
    function computeInterestRateView(address vault, uint cash, uint borrows)
        external
        view
        override
        returns (uint)
    {
        return computeInterestRateInternal(vault, cash, borrows);
    }

    function computeInterestRateInternal(address, uint cash, uint borrows) internal view returns (uint ir) {
        uint totalAssets = cash + borrows;

        // utilization has decimals of 1e18, where 1e18 = 100%
        uint utilization = totalAssets == 0
            ? 0 // prevent divide by zero case by returning zero
            : borrows * 1e18 / totalAssets;

        ir = linearParameter * utilization;

        if (utilization > nonlinearPoint) {
            // Use gamma of 32
            // utilization^2
            uint utilpow = (utilization * utilization) / 1e18;
            // utilization^4
            utilpow = (utilpow * utilpow) / 1e18;
            // utilization^8
            utilpow = (utilpow * utilpow) / 1e18;
            // utilization^16
            utilpow = (utilpow * utilpow) / 1e18;
            // utilization^32
            utilpow = (utilpow * utilpow) / 1e18;

            ir += polynomialParameter * utilpow;
        }

        ir = (ir * (1e9 / MAXFACTOR)) / SECONDS_PER_YEAR; // has 1e27 decimals
    }
}
