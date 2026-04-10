// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.28;

import {IRMTwyneCurve} from "./IRMTwyneCurve.sol";

/// @title IRMTwyneCurveGamma32
/// @notice To contact the team regarding security matters, visit https://twyne.xyz/security
/// @notice Implementation of a curved interest rate model
/// @notice Interest rate = minInterest + linearParameter * u + polynomialParameter * u^32
/// @notice This variant uses polynomial gamma of 32
contract IRMTwyneCurveGamma32 is IRMTwyneCurve {

    /// @param minInterest_ 1e4 precision
    /// @param linearParameter_ 1e4 precision
    /// @param polynomialParameter_ 1e4 precision
    /// @param nonlinearPoint_ 1e18 precision
    constructor(uint minInterest_, uint linearParameter_, uint polynomialParameter_, uint nonlinearPoint_)
        IRMTwyneCurve(minInterest_, linearParameter_, polynomialParameter_, nonlinearPoint_)
    {}

    /// @notice Computes utilization^gamma (gamma = 32 for this contract)
    function _computeUtilPow(uint utilization) internal pure override returns (uint utilpow) {
        // utilization^2
        utilpow = (utilization * utilization) / 1e18;
        // utilization^4
        utilpow = (utilpow * utilpow) / 1e18;
        // utilization^8
        utilpow = (utilpow * utilpow) / 1e18;
        // utilization^16
        utilpow = (utilpow * utilpow) / 1e18;
        // utilization^32
        utilpow = (utilpow * utilpow) / 1e18;
    }
}
