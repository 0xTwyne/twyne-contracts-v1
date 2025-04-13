// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.19;

abstract contract Errors {
    error AccountStatusLiquidatable(); // 0x89db07ae
    error AssetMismatch(); // 0x83c1010a
    error BorrowExists(); // 0x7818852c
    error CallerNotCollateralVaultFactory(); // 0x5f2ba196
    error CallerNotGenericFactory(); // 0x5529a1a2
    error CallerNotOwnerOrCollateralVaultFactory(); // 0xda57fd09
    error CannotRebalance(); // 0x302a624a
    error CannotRescueToken(); // 0xe54515ea
    error ExternallyLiquidated(); // 0x111c379d
    error HealthyNotLiquidatable(); // 0x8e9797c5
    error IncorrectIndex(); // 0x07cc4d8f
    error IntermediateVaultAlreadySet(); // 0x00e658da
    error IntermediateVaultNotSet(); // 0x83cc6e74
    error MismatchedAssets(); // 0x11e07b07
    error NotCollateralVault(); // 0x4b344c2d
    error NotExternallyLiquidated(); // 0xdbd904f5
    error NotIntermediateVault(); // 0x8a6a3c99
    error OnlyVaultManager(); // 0x612bde3d
    error ReceiverNotBorrower(); // 0x4a1d1a97
    error ReceiverNotCollateralVault(); // 0x9b6e6f6b
    error Reentrancy(); // 0xab143c06
    error RepayAssetsInsufficient(); // 0x4e177cde
    error RepayingMoreThanMax(); // 0x4fc5c4ba
    error SelfLiquidation(); // 0x44511af1
    error SnapshotNotTaken(); // 0xcb85efac
    error T_CV_OperationDisabled(); // 0x335c5fec
    error T_OperationDisabled(); // 0x4f6309cb
    error TransferDisabled(); // 0xa24e573d
    error TransferFromNotAllowed(); // 0x3a67746c
    error ValueOutOfRange(); // 0x4eb4f9fb
    error VaultHasNegativeExcessCredit(); // 0xfaf95be7
    error VaultStatusLiquidatable(); // 0x9c166fd0
    error ViolatorNotCollateralVault(); // 0x6af6f6bb
}