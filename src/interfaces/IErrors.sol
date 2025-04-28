// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.28;

interface IErrors {
    error AssetMismatch(); // 0x83c1010a
    error CallerNotOwnerOrCollateralVaultFactory(); // 0xda57fd09
    error CannotRebalance(); // 0x302a624a
    error ExternallyLiquidated(); // 0x111c379d
    error HealthyNotLiquidatable(); // 0x8e9797c5
    error IncorrectIndex(); // 0x07cc4d8f
    error IntermediateVaultAlreadySet(); // 0x00e658da
    error IntermediateVaultNotSet(); // 0x83cc6e74
    error NotCollateralVault(); // 0x4b344c2d
    error NotExternallyLiquidated(); // 0xdbd904f5
    error NotIntermediateVault(); // 0x8a6a3c99
    error ReceiverNotBorrower(); // 0x4a1d1a97
    error ReceiverNotCollateralVault(); // 0x9b6e6f6b
    error Reentrancy(); // 0xab143c06
    error RepayingMoreThanMax(); // 0x4fc5c4ba
    error SelfLiquidation(); // 0x44511af1
    error SnapshotNotTaken(); // 0xcb85efac
    error T_CV_OperationDisabled(); // 0x335c5fec
    error T_OperationDisabled(); // 0x4f6309cb
    error ValueOutOfRange(); // 0x4eb4f9fb
    error VaultStatusLiquidatable(); // 0x9c166fd0
    error ViolatorNotCollateralVault(); // 0x6af6f6bb
}