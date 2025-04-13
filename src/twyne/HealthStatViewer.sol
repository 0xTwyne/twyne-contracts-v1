// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.19;

import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {EulerCollateralVault, VaultManager, EulerRouter} from "src/twyne/EulerCollateralVault.sol";

/// @dev functions to view liquidation health related stats of collateral vaults. Useful for frontend.
contract HealthStatViewer {
    uint internal constant MAXFACTOR = 1e4;

    /// @notice Check health factor from Twyne's perspective (including internal borrow).
    /// @notice HealthFactor's interpretation depends on the underlying protocol.
    /// On Aave = 1 / LTV, On Compound = debt_value - (liq_cf * collateral_value).
    /// @dev The Aave version of 1 / LTV is used in this implementation.
    function internalHF(address collateralVault)
        external
        view
        returns (uint healthFactor, uint collateralValue, uint liabilityValue)
    {
        (collateralValue, liabilityValue) = IEVault(EulerCollateralVault(collateralVault).twyneVaultManager().getIntermediateVault(EulerCollateralVault(collateralVault).asset())).accountLiquidity(collateralVault, true);

        if (liabilityValue == 0) {
            healthFactor = type(uint).max;
        } else {
            healthFactor = collateralValue * 1e18 / liabilityValue;
        }
    }

    /// @notice Check health factor from external protocol's perspective (excluding internal borrow).
    /// @notice HealthFactor's interpretation depends on the underlying protocol.
    /// On Aave = 1 / LTV, On Compound = debt_value - (liq_cf * collateral_value).
    /// @dev The Aave version of 1 / LTV is used in this implementation.
    function externalHF(address collateralVault) external view returns (uint healthFactor, uint collateralValue, uint liabilityValue) {
        (collateralValue, liabilityValue) = IEVault(EulerCollateralVault(collateralVault).targetVault()).accountLiquidity(collateralVault, true);

        if (liabilityValue == 0) {
            healthFactor = type(uint).max;
        } else {
            healthFactor = collateralValue * 1e18 / liabilityValue;
        }
    }

    /// @notice Return health factors and debt values.
    /// @param collateralVault collateral vault address.
    /// @return extHF health factor from external protocol's perspective (1 / LTV).
    /// @return inHF health factor of from Twyne's perspective (1 / LTV).
    /// @return externalBorrowDebtValue external borrow value in targetVault unitOfAccount (usually USD).
    /// @return internalBorrowDebtValue internal borrow value in targetVault unitOfAccount (usually USD).
    function health(address collateralVault) external view returns (uint extHF, uint inHF, uint externalBorrowDebtValue, uint internalBorrowDebtValue) {
        VaultManager twyneVaultManager = EulerCollateralVault(collateralVault).twyneVaultManager();
        IEVault targetVault = IEVault(EulerCollateralVault(collateralVault).targetVault());
        address asset = EulerCollateralVault(collateralVault).asset();

        uint externalCollateralValueScaledByLiqLTV;
        (externalCollateralValueScaledByLiqLTV, externalBorrowDebtValue) = targetVault.accountLiquidity(collateralVault, true);

        // extHF tracks liquidation condition 1, where the external protocol's liquidation limit is nearly hit
        if (externalBorrowDebtValue == 0) extHF = type(uint).max;
        else {
            extHF = uint(twyneVaultManager.externalLiqBuffer()) * 1e18 * externalCollateralValueScaledByLiqLTV / (MAXFACTOR * externalBorrowDebtValue);
        }

        uint vaultOwnedCollateralAmount = EulerCollateralVault(collateralVault).totalAssetsDepositedOrReserved();
        uint vaultOwnedCollateralValue = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(vaultOwnedCollateralAmount, asset, targetVault.unitOfAccount());

        uint internalBorrowDebtAmount = IEVault(twyneVaultManager.getIntermediateVault(asset)).debtOf(collateralVault);
        internalBorrowDebtValue =
            EulerRouter(twyneVaultManager.oracleRouter()).getQuote(internalBorrowDebtAmount, asset, targetVault.unitOfAccount());

        // inHF tracks liquidation condition 2, where the external protocol's liquidation limit is nearly hit
        if (externalBorrowDebtValue == 0) inHF = type(uint).max;
        else {
            inHF = EulerCollateralVault(collateralVault).twyneLiqLTV() * (vaultOwnedCollateralValue - internalBorrowDebtValue) * 1e18 / (externalBorrowDebtValue * MAXFACTOR);
        }
    }
}
