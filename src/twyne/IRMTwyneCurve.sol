// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.28;

import {IIRM} from "euler-vault-kit/InterestRateModels/IIRM.sol";
import {SECONDS_PER_YEAR} from "euler-vault-kit/EVault/shared/Constants.sol";

/// @title IRMTwyneCurve
/// @notice To contact the team regarding security matters, visit https://twyne.xyz/security
/// @notice Implementation of a curved interest rate model
/// @notice Interest rate = minInterest + linearParameter * u + polynomialParameter * u^12
/// @notice This variant uses polynomial gamma of 12
contract IRMTwyneCurve is IIRM {
    /// @notice When utilization rate is less than nonlinearPoint, assume linear model (polynomial term is not significant)
    uint public immutable nonlinearPoint; // 5e17 = 50%

    uint public immutable minInterest; // 1e22 precision
    uint public immutable linearParameter; // 1e4 precision
    uint public immutable polynomialParameter; // 1e4 precision

    uint internal constant MAXFACTOR = 1e4;

    /// @param minInterest_ 1e4 precision
    /// @param linearParameter_ 1e4 precision
    /// @param polynomialParameter_ 1e4 precision
    /// @param nonlinearPoint_ 1e18 precision
    constructor(uint minInterest_, uint linearParameter_, uint polynomialParameter_, uint nonlinearPoint_) {
        if (
            polynomialParameter_ == 0
            || nonlinearPoint_ == 0
            || nonlinearPoint_ >= 1e18 // nonlinear point must be less than 100%
        ) revert E_IRMUpdateUnauthorized();

        minInterest = minInterest_ * 1e18;
        linearParameter = linearParameter_;
        polynomialParameter = polynomialParameter_;
        nonlinearPoint = nonlinearPoint_;
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

    function computeInterestRateInternal(address, uint cash, uint borrows) internal view virtual returns (uint ir) {
        uint totalAssets = cash + borrows;

        // utilization has decimals of 1e18, where 1e18 = 100%
        uint utilization = totalAssets == 0
            ? 0 // prevent divide by zero case by returning zero
            : borrows * 1e18 / totalAssets;

        ir = minInterest + linearParameter * utilization;

        if (utilization > nonlinearPoint) {
            ir += polynomialParameter * _computeUtilPow(utilization);
        }

        ir = (ir * (1e9 / MAXFACTOR)) / SECONDS_PER_YEAR; // has 1e27 decimals
    }

    /// @notice Computes utilization^gamma (gamma = 12 for this contract)
    function _computeUtilPow(uint utilization) internal pure virtual returns (uint utilpow) {
        // utilization^2
        uint utilTemp4 = (utilization * utilization) / 1e18;
        // utilization^4
        utilTemp4 = (utilTemp4 * utilTemp4) / 1e18;
        // utilization^8
        utilpow = (utilTemp4 * utilTemp4) / 1e18;
        // utilization^12
        utilpow = (utilpow * utilTemp4) / 1e18;
    }
}
