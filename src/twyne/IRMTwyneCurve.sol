// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;

import {IIRM} from "euler-vault-kit/InterestRateModels/IIRM.sol";
import {SECONDS_PER_YEAR} from "euler-vault-kit/EVault/shared/Constants.sol";

/// @title IRMLinearKink
/// @custom:security-contact security@euler.xyz
/// @author Euler Labs (https://www.eulerlabs.com/)
/// @notice Implementation of a curved interest rate model
/// @notice interest rate grows linearly with utilization and increases faster after reaching a kink
contract IRMTwyneCurve is IIRM {
    /// @notice Interest rate applied at ideal kink
    uint public immutable idealKinkInterestRate; // 0.1e4 = 10%
    /// @notice Interest rate applied at linear kink
    uint public immutable linearKinkUtilizationRate; // 0.8e4 = 80%
    /// @notice Max interest rate applied at 100% utilization
    uint public immutable maxInterestRate; // 1.2e4 = 120%

    /// @notice Utilization ratio at linear kink point
    uint public immutable nonlinearPoint; // 0.6e4 = 60%

    /// @notice Curve parameters
    uint public immutable linearParameter;
    uint public immutable polynomialParameter;

    /// @notice Base interest rate applied when utilization is equal zero
    uint public immutable baseRate;
    /// @notice Slope of the function before the kink
    uint public immutable slope1;
    /// @notice Slope of the function after the kink
    uint public immutable slope2;
    /// @notice LTV values have 1e4 decimals
    uint internal constant MAXFACTOR = 1e4;

    constructor(uint16 idealKinkInterestRate_, uint16 linearKinkUtilizationRate_, uint16 maxInterestRate_, uint16 nonlinearPoint_) {
        if (
            idealKinkInterestRate_ > maxInterestRate_
            || linearKinkUtilizationRate_ > MAXFACTOR
            || idealKinkInterestRate_ == 0
            || linearKinkUtilizationRate_ == 0
            || maxInterestRate_ == 0
            || nonlinearPoint_ == 0
            || nonlinearPoint_ >= linearKinkUtilizationRate_
        ) revert E_IRMUpdateUnauthorized();

        idealKinkInterestRate = idealKinkInterestRate_;
        linearKinkUtilizationRate = linearKinkUtilizationRate_;
        maxInterestRate = maxInterestRate_;
        nonlinearPoint = nonlinearPoint_;
        linearParameter = idealKinkInterestRate * MAXFACTOR / linearKinkUtilizationRate;
        polynomialParameter = maxInterestRate - linearParameter;
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

        // Use gamma of 10
        uint util10;
        if (utilization > nonlinearPoint) {
            // utilization^2
            uint utilTemp2 = (utilization * utilization) / 1e18;
            // utilization^4
            util10 = (utilTemp2 * utilTemp2) / 1e18;
            // utilization^8
            util10 = (util10 * util10) / 1e18;
            // utilization^10
            util10 = (util10 * utilTemp2) / 1e18;
        }
        ir = ((linearParameter * utilization) + (polynomialParameter * util10)) * (1e9 / MAXFACTOR); // has 1e18 decimals
        ir /= SECONDS_PER_YEAR;

        return ir;
    }
}