// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {EulerCollateralVault, CollateralVaultBase, VaultManager, EulerRouter} from "src/twyne/EulerCollateralVault.sol";
import {IPool as IAaveV3Pool} from "aave-v3/interfaces/IPool.sol";

/// @title HealthStatViewer
/// @notice To contact the team regarding security matters, visit https://twyne.xyz/security
/// @dev functions to view liquidation health related stats of collateral vaults. Useful for frontend.
contract HealthStatViewer {
    uint internal constant MAXFACTOR = 1e4;
    address public immutable aavePool;

    constructor(address _aavePool) {
        aavePool = _aavePool;
    }

    /// @notice Check health factor from from Intermediate vault's perspective.
    /// @dev The Aave version of 1 / LTV is used in this implementation.
    function internalHF(address collateralVault)
        external
        view
        returns (uint healthFactor, uint collateralValue, uint liabilityValue)
    {
        (collateralValue, liabilityValue) = IEVault(EulerCollateralVault(collateralVault).intermediateVault()).accountLiquidity(collateralVault, true);

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
        address targetVault = CollateralVaultBase(collateralVault).targetVault();
        if(targetVault == aavePool) {
            // For Aave, fetch health factor directly from the pool
            (collateralValue, liabilityValue,,,, healthFactor) = IAaveV3Pool(aavePool).getUserAccountData(collateralVault);
            // Aave returns asset values in 1e8 precision, multiply by 1e10 to match Euler precision (1e18)
            return (healthFactor, collateralValue * 1e10, liabilityValue * 1e10);
        }
        // Euler
        (collateralValue, liabilityValue) = IEVault(targetVault).accountLiquidity(collateralVault, true);

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

        if (address(targetVault) == aavePool) {
            // For Aave, fetch health factor directly from the pool
            (, uint liabilityValue,,,, uint healthFactor) = IAaveV3Pool(aavePool).getUserAccountData(collateralVault);

            // extHF tracks liquidation condition 1, where the external protocol's liquidation limit is nearly hit
            if (liabilityValue == 0) extHF = type(uint).max;
            else {
                if (healthFactor > type(uint).max / MAXFACTOR) extHF = type(uint).max;
                extHF = uint(twyneVaultManager.externalLiqBuffers(asset)) * healthFactor / MAXFACTOR;
            }

            externalBorrowDebtValue = liabilityValue * 1e10; // multiply by 1e10 to match Euler precision (1e18)
        } else {
            // Euler
            uint externalCollateralValueScaledByLiqLTV;
            (externalCollateralValueScaledByLiqLTV, externalBorrowDebtValue) = targetVault.accountLiquidity(collateralVault, true);

            // extHF tracks liquidation condition 1, where the external protocol's liquidation limit is nearly hit
            if (externalBorrowDebtValue == 0) extHF = type(uint).max;
            else {
                extHF = uint(twyneVaultManager.externalLiqBuffers(asset)) * 1e18 * externalCollateralValueScaledByLiqLTV / (MAXFACTOR * externalBorrowDebtValue);
            }
        }

        uint userCollateralValue;
        (userCollateralValue, internalBorrowDebtValue) = CollateralVaultBase(collateralVault).intermediateVault().accountLiquidity(collateralVault, true);

        // inHF tracks liquidation condition 2, where the external protocol's liquidation limit is nearly hit
        if (externalBorrowDebtValue == 0) inHF = type(uint).max;
        else {
            inHF = EulerCollateralVault(collateralVault).twyneLiqLTV() * userCollateralValue * 1e18 / (externalBorrowDebtValue * MAXFACTOR);
        }
    }
}
