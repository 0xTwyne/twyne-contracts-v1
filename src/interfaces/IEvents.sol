// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.28;

interface IEvents {
    // CollateralVaultFactory
    event T_SetVaultManager(address indexed vaultManager);
    event T_SetBeacon(address indexed targetVault, address indexed beacon);
    event T_SetCollateralVaultLiquidated(address indexed collateralVault, address indexed liquidator);
    event T_FactoryPause(bool pause);
    event T_CollateralVaultCreated(address indexed vault);
    // CollateralVaultBase
    event T_Borrow(uint targetAmount, address indexed receiver);
    event T_Repay(uint repayAmount);
    event T_Deposit(uint amount);
    event T_DepositUnderlying(uint amount);
    event T_Withdraw(uint amount, address indexed receiver);
    event T_RedeemUnderlying(uint amount, address indexed receiver);
    event T_SetTwyneLiqLTV(uint ltv);
    event T_Rebalance();
    // EulerCollateralVault
    event T_CollateralVaultInitialized();
    event T_ControllerDisabled();
    event T_HandleExternalLiquidation();
    event T_Teleport(uint toDeposit, uint toReserve, uint toBorrow);
    // VaultManager
    event T_SetOracleRouter(address indexed newOracleRouter);
    event T_SetIntermediateVault(address indexed intermediateVault);
    event T_AddAllowedTargetVault(address indexed intermediateVault, address indexed targetVault);
    event T_RemoveAllowedTargetVault(address indexed intermediateVault, address indexed targetVault, uint index);
    event T_SetMaxLiqLTV(address indexed collateralAddress, uint16 ltv);
    event T_SetExternalLiqBuffer(address indexed collateralAddress, uint16 liqBuffer);
    event T_SetCollateralVaultFactory(address indexed factory);
    event T_SetLTV(address indexed intermediateVault, address indexed collateralVault, uint16 borrowLimit, uint16 liquidationLimit, uint32 rampDuration);
    event T_SetOracleResolvedVault(address indexed collateralAddress, bool allow);
    event T_DoCall(address indexed to, uint value, bytes data);
}