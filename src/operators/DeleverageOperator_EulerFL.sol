// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {EulerCollateralVault, IEVault} from "src/twyne/EulerCollateralVault.sol";
import {IBorrowing, IRiskManager} from "euler-vault-kit/EVault/IEVault.sol";
import {CollateralVaultBase} from "src/twyne/CollateralVaultBase.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {IErrors} from "src/interfaces/IErrors.sol";
import {IEvents} from "src/interfaces/IEvents.sol";
import {ReentrancyGuardTransient} from "openzeppelin-contracts/utils/ReentrancyGuardTransient.sol";
import {EVCUtil} from "ethereum-vault-connector/utils/EVCUtil.sol";

interface ISwapper {
    function multicall(bytes[] memory calls) external;
}

/// @title DeleverageOperator_EulerFL
/// @notice Operator contract for executing 1-click deleverage operations on collateral vaults
/// @dev Uses Euler flashloans to enable unwinding operations
contract DeleverageOperator_EulerFL is ReentrancyGuardTransient, EVCUtil, IErrors, IEvents {
    using SafeERC20 for IERC20;

    address public immutable SWAPPER;
    CollateralVaultFactory public immutable COLLATERAL_VAULT_FACTORY;
    IEVC public immutable EULER_EVC;

    constructor(
        address _eulerEVC,
        address _twyneEVC,
        address _swapper,
        address _collateralVaultFactory
    ) EVCUtil(_twyneEVC) {
        EULER_EVC = IEVC(_eulerEVC);
        SWAPPER = _swapper;
        COLLATERAL_VAULT_FACTORY = CollateralVaultFactory(_collateralVaultFactory);
    }

    // Copied from EVCUtil to make it work for Euler's EVC
    function _msgSenderEulerEVC() internal view returns (address) {
        address sender = msg.sender;
        if (sender == address(EULER_EVC)) {
            (sender,) = EULER_EVC.getCurrentOnBehalfOfAccount(address(0));
        }
        return sender;
    }

    /// @notice Execute a deleverage operation on a collateral vault
    /// @dev This function executes the following steps:
    /// 1. Takes underlying collateral (like WSTETH) flashloan from collateralVault.asset(): asset received in this contract.
    /// 2. Transfer flashloaned amount to swapper.
    /// 3. Swapper.multicall is called which swaps flashloaned amount to target asset. Swap should transfer target asset to this contract.
    ///    optional: multicall also sweeps underlying collateral asset to this contract.
    /// 4. Repays collateral vault debt, and ensures the final debt is at most `maxDebt`.
    /// 5. Withdraws `withdrawCollateralAmount` of collateral from collateral vault.
    ///    Collateral vault redeems it to underlying collateral, and transfers it to this contract.
    /// 6. Transfers underlying collateral to collateralVault.asset() to repay flashloan.
    /// 7. This contract transfers any remaining balance of underlying collateral and target asset to caller.
    /// @param collateralVault Address of the user's collateral vault
    /// @param flashloanAmount Amount of underlying collateral asset to flashloan
    /// @param maxDebt Maximum amount of debt expected after deleveraging
    /// @param withdrawCollateralAmount collateral to withdraw from collateral vault
    /// @param swapData Encoded swap instructions for the swapper
    function executeDeleverage(
        address collateralVault,
        uint flashloanAmount,
        uint maxDebt,
        uint withdrawCollateralAmount,
        bytes[] calldata swapData
    ) external nonReentrant {
        address msgSender = _msgSender();

        require(COLLATERAL_VAULT_FACTORY.isCollateralVault(collateralVault), T_InvalidCollateralVault());

        require(EulerCollateralVault(collateralVault).borrower() == msgSender, T_CallerNotBorrower());

        address targetAsset = EulerCollateralVault(collateralVault).targetAsset();
        address collateralAsset = EulerCollateralVault(collateralVault).asset();
        address underlyingCollateral = IEVault(collateralAsset).asset();
        IERC20(underlyingCollateral).forceApprove(collateralAsset, flashloanAmount);
        bytes memory flashloanData = abi.encodeCall(this.onFlashLoan, (
                flashloanAmount,
                msgSender,
                collateralVault,
                targetAsset,
                underlyingCollateral,
                maxDebt,
                withdrawCollateralAmount,
                swapData
        ));

        IEVC.BatchItem[] memory eulerFL_items = new IEVC.BatchItem[](5);

        eulerFL_items[0] = IEVC.BatchItem({
            targetContract: address(EULER_EVC),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeCall(IEVC.enableController, (address(this), address(collateralAsset)))
        });
        // 2) borrow to THIS contract
        eulerFL_items[1] = IEVC.BatchItem({
            targetContract: address(collateralAsset),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeCall(IBorrowing.borrow, (flashloanAmount, address(this)))
        });
        // 3) TwyneLiquidator logic
        eulerFL_items[2] = IEVC.BatchItem({
            targetContract: address(this),
            onBehalfOfAccount: address(this),
            value: 0,
            data: flashloanData
        });
        // 4) repay from the contract's address(this)
        eulerFL_items[3] = IEVC.BatchItem({
            targetContract: address(collateralAsset),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeCall(IBorrowing.repay, (flashloanAmount, address(this)))
        });
        // 5) Disable controller
        eulerFL_items[4] = IEVC.BatchItem({
            targetContract: address(collateralAsset),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeCall(IRiskManager.disableController, ())
        });

        EULER_EVC.batch(eulerFL_items);

        IERC20(targetAsset).safeTransfer(msgSender, IERC20(targetAsset).balanceOf(address(this)));
        IERC20(underlyingCollateral).safeTransfer(msgSender, IERC20(underlyingCollateral).balanceOf(address(this)));

        emit T_LeverageDownExecuted(collateralVault);
    }

    /// @notice Callback function for deleverage logic
    function onFlashLoan(
        uint amount,
        address user,
        address collateralVault,
        address targetAsset,
        address underlyingCollateral,
        uint maxDebt,
        uint withdrawCollateralAmount,
        bytes[] calldata swapData
    ) external {
        require(_msgSenderEulerEVC() == address(this), T_CallerNotSelf());

        // Step 1: Transfer borrowed underlying collateral asset to swapper
        IERC20(underlyingCollateral).safeTransfer(SWAPPER, amount);

        // Step 2: Execute swap underlying collateral -> target asset through multicall.
        // This contract receives the target asset.
        ISwapper(SWAPPER).multicall(swapData);

        address targetVault = EulerCollateralVault(collateralVault).targetVault();
        uint debtToRepay = Math.min(IERC20(targetAsset).balanceOf(address(this)), IEVault(targetVault).debtOf(collateralVault));

        // Step 3: Repay debt
        IERC20(targetAsset).forceApprove(targetVault, debtToRepay);
        IEVault(targetVault).repay(debtToRepay, collateralVault);

        require(IEVault(targetVault).debtOf(collateralVault) <= maxDebt, T_DebtMoreThanMax());

        // Step 4: Withdraw collateral
        evc.call({
            targetContract: collateralVault,
            onBehalfOfAccount: user,
            value: 0,
            data: abi.encodeCall(CollateralVaultBase.redeemUnderlying, (withdrawCollateralAmount, address(this)))
        });
    }
}