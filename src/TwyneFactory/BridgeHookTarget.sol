// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.28;

import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {CollateralVaultBase} from "src/twyne/CollateralVaultBase.sol";
import {IErrors} from "src/interfaces/IErrors.sol";

/// @title BridgeHookTarget
/// @notice To contact the team regarding security matters, visit https://twyne.xyz/security
contract BridgeHookTarget is IErrors {
    CollateralVaultFactory immutable collateralVaultFactory;

    constructor(address _collateralVaultFactory) {
        collateralVaultFactory = CollateralVaultFactory(_collateralVaultFactory);
    }

    function isHookTarget() external pure returns (bytes4) {
        return this.isHookTarget.selector;
    }

    function borrow(uint /*amount*/, address receiver) external view {
        require(collateralVaultFactory.isCollateralVault(receiver), ReceiverNotCollateralVault());
    }

    function liquidate(address violator, address /*collateral*/, uint /*repayAssets*/, uint /*minYieldBalance*/) external view {
        require(collateralVaultFactory.isCollateralVault(violator), ViolatorNotCollateralVault());
        require(CollateralVaultBase(violator).borrower() == address(0), NotExternallyLiquidated());
    }

    fallback() external {
        revert T_OperationDisabled();
    }
}
