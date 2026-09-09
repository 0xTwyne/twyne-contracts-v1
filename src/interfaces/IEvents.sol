// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

interface IEvents {
    // CollateralVaultFactory
    event T_SetVaultManager(address indexed vaultManager);
    event T_SetAdmin(address indexed admin);
    event T_SetBeacon(address indexed targetVault, address indexed beacon);
    event T_SetPauseGuardian(address indexed pauseGuardian);
    event T_SetCollateralVaultLiquidated(address indexed collateralVault, address indexed liquidator);
    event T_PauseStateChanged(uint8 newState);
    event T_CollateralVaultCreated(address indexed vault);
    event T_CategoryIdSet(address indexed targetVault, address indexed collateral, address indexed debt, uint8 categoryId);
    event T_SetAllowedMorphoMarket(
        address indexed targetVault, address indexed intermediateVault, bytes32 indexed marketId, bool set
    );
    event T_SetBorrowBuffer(address indexed intermediateVault, address indexed targetAsset, uint16 borrowBuffer);
    // CollateralVaultBase
    event T_Borrow(uint targetAmount, address indexed receiver);
    event T_Repay(uint repayAmount);
    event T_Deposit(uint amount);
    event T_Withdraw(uint amount, address indexed receiver);
    event T_RedeemUnderlying(uint amount, address indexed receiver);
    event T_Skim(uint amount);
    event T_SetTwyneLiqLTV(uint ltv);
    event T_Rebalance();
    // EulerCollateralVault
    event T_CollateralVaultInitialized();
    event T_ControllerDisabled();
    event T_HandleExternalLiquidation();
    event T_Teleport(uint toDeposit, uint toBorrow);
    // VaultManager
    event T_SetOracleRouter(address indexed newOracleRouter);
    event T_SetIntermediateVault(address indexed intermediateVault, bool value);
    event T_AddAllowedTargetVault(address indexed intermediateVault, address indexed targetVault);
    event T_AddAllowedTargetVaultAsset(address indexed intermediateVault, address indexed targetVault, address indexed targetAsset);
    event T_SetMaxLiqLTV(address indexed intermediateVault, address indexed targetAsset, uint16 ltv, uint32 rampDuration);
    event T_SetExternalLiqBuffer(address indexed intermediateVault, address indexed targetAsset, uint16 liqBuffer, uint32 rampDuration);
    event T_SetCollateralVaultFactory(address indexed factory);
    event T_SetLTV(address indexed intermediateVault, address indexed collateralVault, uint16 borrowLimit, uint16 liquidationLimit, uint32 rampDuration);
    event T_SetOracleResolvedVault(address indexed collateralAddress, bool allow);
    event T_SetOracleResolvedVault(address indexed oracleRouter, address indexed collateralAddress, bool allow);
    event T_DoCall(address indexed to, uint value, bytes data);
    // LeverageOperator
    event T_LeverageUpExecuted(address indexed collateralVault);
    event T_LeverageDownExecuted(address indexed collateralVault);
    // AssetZap
    event T_AssetZap(
        address indexed sender, address indexed destination, address tokenIn, uint amountIn, uint amountOut
    );
}
