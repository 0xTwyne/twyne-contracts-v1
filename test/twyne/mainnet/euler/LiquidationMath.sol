// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.28;

import {Math} from "openzeppelin-contracts/utils/math/Math.sol";

/// @notice Pure math helpers for comparing liquidation outputs against off-chain models.
library LiquidationMath {
    uint256 internal constant MAXFACTOR = 1e4;

    /// @notice Returns borrower collateral share expressed in base units (unit of account, same units as B/C inputs).
    /// @dev This mirrors CollateralVaultBase.collateralForBorrower but skips the `_convertBaseToCollateral` step.
    /// @dev Matches the exact logic including potential underflow scenarios (will revert if C < B in safe case).
    function borrowerCollateralBase(
        uint256 B,
        uint256 C,
        uint256 externalLiqBuffer,
        uint256 extLiqLTV,
        uint256 maxLTV_t
    ) internal pure returns (uint256) {
        uint256 liqLTV_e = externalLiqBuffer * extLiqLTV; // 1e8 precision

        if (MAXFACTOR * B >= maxLTV_t * C) {
            return 0;
        } else if (MAXFACTOR * MAXFACTOR * B <= liqLTV_e * C) {
            // Matches: return _convertBaseToCollateral(C - B);
            // Note: Can revert on underflow if C < B, matching actual behavior
            return C - B;
        } else {
            // Matches exact formula from collateralForBorrower:
            // (MAXFACTOR * MAXFACTOR - liqLTV_e) * (maxLTV_t * C - MAXFACTOR * B) /
            // (MAXFACTOR * (MAXFACTOR * maxLTV_t - liqLTV_e))
            // Note: Can revert on underflow if maxLTV_t * C < MAXFACTOR * B, matching actual behavior
            return (MAXFACTOR * MAXFACTOR - liqLTV_e) * (maxLTV_t * C - MAXFACTOR * B) /
                (MAXFACTOR * (MAXFACTOR * maxLTV_t - liqLTV_e));
        }
    }

    /// @notice Splits collateral after external liquidation (pure math version).
    /// @dev This mirrors EulerCollateralVault.splitCollateralAfterExtLiq for testing.
    /// @dev The function takes inputs after oracle conversions have been done externally.
    /// @param _collateralBalance Total collateral balance remaining after external liquidation (in collateral units)
    /// @param _userCollateralInitial Initial user collateral estimate from maxRepay calculation (in collateral units, can be 0 if _maxRepay == 0)
    /// @param _maxRelease Maximum amount that can be released to intermediate vault (in collateral units)
    /// @param C_new User collateral value in USD (calculated from final userCollateral via oracle, same units as B)
    /// @param B Borrow amount in USD (same units as C_new)
    /// @param externalLiqBuffer External liquidation buffer (1e4 precision)
    /// @param extLiqLTV External liquidation LTV (1e4 precision)
    /// @param maxLTV_t Maximum Twyne LTV (1e4 precision)
    /// @return liquidatorReward Amount of collateral to reward liquidator (in collateral units)
    /// @return releaseAmount Amount of collateral to release to intermediate vault (in collateral units)
    /// @return borrowerClaim Amount of collateral to return to borrower (in collateral units)
    function splitCollateralAfterExtLiq(
        uint256 _collateralBalance,
        uint256 _userCollateralInitial,
        uint256 _maxRelease,
        uint256 C_new,
        uint256 B,
        uint256 externalLiqBuffer,
        uint256 extLiqLTV,
        uint256 maxLTV_t
    ) internal pure returns (uint256 liquidatorReward, uint256 releaseAmount, uint256 borrowerClaim) {
        // Step 1: Calculate userCollateral (matches actual implementation logic)
        // In actual code: userCollateral is calculated from _maxRepay via oracle, then:
        // userCollateral = Math.min(_collateralBalance, IEVault(__asset).convertToShares(userCollateral));
        // Here we receive _userCollateralInitial as pre-calculated value
        // Extra condition to match production behavior: cap userCollateral at collateralBalance
        uint256 userCollateral = Math.min(_collateralBalance, _userCollateralInitial);
        
        // Step 2: Calculate releaseAmount = min(_collateralBalance - userCollateral, _maxRelease)
        // Matches: uint releaseAmount = Math.min(_collateralBalance - userCollateral, _maxRelease);
        // Note: After capping userCollateral above, this subtraction is safe and matches production behavior
        releaseAmount = Math.min(_collateralBalance - userCollateral, _maxRelease);
        
        // Step 3: Recalculate userCollateral = _collateralBalance - releaseAmount
        // Matches: userCollateral = _collateralBalance - releaseAmount;
        userCollateral = _collateralBalance - releaseAmount;
        
        // Step 4: Calculate borrowerClaim in base units using borrowerCollateralBase
        // Matches: uint borrowerClaim = collateralForBorrower(B, C_new);
        // Note: borrowerCollateralBase returns base units (unit of account), but collateralForBorrower returns collateral units
        // collateralForBorrower internally calls _convertBaseToCollateral which applies:
        // Math.min(totalAssetsDepositedOrReserved - maxRelease(), convertedShares)
        // In external liquidation context, we cap at userCollateral (remaining collateral after external liquidation)
        uint256 borrowerClaimBase = borrowerCollateralBase(B, C_new, externalLiqBuffer, extLiqLTV, maxLTV_t);
        
        // Step 5: Convert borrowerClaim from base units to collateral units
        // Matches: uint borrowerClaim = collateralForBorrower(B, C_new);
        // collateralForBorrower internally calls _convertBaseToCollateral which does:
        //   1. getQuote(collateralValue, unitOfAccount, asset) - converts base to collateral asset
        //   2. convertToShares(collateralAmount) - converts to shares
        //   3. Math.min(totalAssetsDepositedOrReserved - maxRelease(), convertedShares) - caps the result
        // In pure math context, we use proportional conversion and apply the cap
        // Proportional conversion: borrowerClaim (collateral) = userCollateral * (borrowerClaimBase / C_new)
        // This mimics the oracle conversion + convertToShares steps
        uint256 convertedClaim;
        if (C_new == 0) {
            // Extra condition to match production behavior: when C_new == 0, collateralForBorrower returns 0
            // (first case: MAXFACTOR * B >= maxLTV_t * C when C == 0 is always true, so returns 0 directly)
            // No division needed since borrowerClaimBase will be 0, and borrowerClaim should be 0
            // This avoids division by zero and matches production function behavior
            convertedClaim = 0;
        } else {
            convertedClaim = (userCollateral * borrowerClaimBase) / C_new;
        }
        
        // Apply cap matching _convertBaseToCollateral logic
        // Actual implementation: Math.min(totalAssetsDepositedOrReserved - maxRelease(), convertedShares)
        // In external liquidation: cap at userCollateral (remaining collateral after external liquidation)
        // In normal context: cap at totalAssetsDepositedOrReserved - maxRelease()
        // We use userCollateral as the cap since that's what's available after external liquidation
        borrowerClaim = Math.min(userCollateral, convertedClaim);
        
        // Step 6: Calculate liquidatorReward = userCollateral - borrowerClaim
        // Matches: uint liquidatorReward = userCollateral - borrowerClaim;
        // Note: Can revert on underflow if borrowerClaim > userCollateral, matching actual behavior
        liquidatorReward = userCollateral - borrowerClaim;
    }



    function splitCollateralAfterExtLiqUoA(
        uint256 _collateralBalanceUoA, //C_old
        uint256 _maxRepayUoA, //B_left
        uint256 _maxReleaseUoA, //C_LP_old
        uint256 externalLiqBuffer, //10_000
        uint256 extLiqLTV, //8_500
        uint256 maxLTV_t //9_300
    ) internal pure returns (
        uint256 liquidatorRewardUoA,
        uint256 releaseAmountUoA,
        uint256 borrowerClaimUoA
    ) {

        uint256 userCollateralValueUoA;

        // 1. Estimate user's collateral value from maxRepay and LTV
        if (_maxRepayUoA > 0) {

            // value of collateral that backs _maxRepayUoA at that LTV:
            // userCollateralValueUoA = _maxRepayUoA / LTV  (with scaling: * MAXFACTOR / maxLTV)
            userCollateralValueUoA = _maxRepayUoA * MAXFACTOR / maxLTV_t;

            // cannot exceed total collateral value
            if (userCollateralValueUoA > _collateralBalanceUoA) {
                userCollateralValueUoA = _collateralBalanceUoA;
            }
        }

        // 2. Release up to _maxReleaseUoA from the "non-user" part
        //    Remaining value to be split between borrower and liquidator:
        //    collateralBalanceUoA - userCollateralValueUoA
        {
            uint256 availableForReleaseUoA = _collateralBalanceUoA - userCollateralValueUoA;
            releaseAmountUoA = availableForReleaseUoA < _maxReleaseUoA
                ? availableForReleaseUoA
                : _maxReleaseUoA;
        }

        // 3. Final collateral value that remains to be split (borrower vs liquidator)
        uint256 finalUserCollateralValueUoA = _collateralBalanceUoA - releaseAmountUoA;

        // 4. This is C_new in your original logic, but now already in UoA
        uint256 C_new = finalUserCollateralValueUoA;

        // 5. Borrower's claim in UoA
        borrowerClaimUoA = borrowerCollateralBase(_maxRepayUoA, C_new, externalLiqBuffer, extLiqLTV, maxLTV_t); // must operate in UoA as well

        // 6. Liquidator gets the remaining value
        liquidatorRewardUoA = finalUserCollateralValueUoA - borrowerClaimUoA;
    }
}

