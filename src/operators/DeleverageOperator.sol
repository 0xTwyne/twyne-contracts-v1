// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {EulerCollateralVault, IEVault} from "src/twyne/EulerCollateralVault.sol";
import {CollateralVaultBase} from "src/twyne/CollateralVaultBase.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {IErrors} from "src/interfaces/IErrors.sol";
import {IEvents} from "src/interfaces/IEvents.sol";
import {ReentrancyGuardTransient} from "openzeppelin-contracts/utils/ReentrancyGuardTransient.sol";
import {EVCUtil} from "ethereum-vault-connector/utils/EVCUtil.sol";

interface IMorpho {
    function flashLoan(address token, uint assets, bytes calldata data) external;
}

interface ISwapper {
    function multicall(bytes[] memory calls) external;
}

/// @title DeleverageOperator
/// @notice Operator contract for executing 1-click deleverage operations on collateral vaults
/// @dev Uses Morpho flashloans to enable unwinding operations
contract DeleverageOperator is ReentrancyGuardTransient, EVCUtil, IErrors, IEvents {
    using SafeERC20 for IERC20;

    address public immutable SWAPPER;
    IMorpho public immutable MORPHO;
    CollateralVaultFactory public immutable COLLATERAL_VAULT_FACTORY;

    constructor(
        address _evc,
        address _swapper,
        address _morpho,
        address _collateralVaultFactory
    ) EVCUtil(_evc) {
        SWAPPER = _swapper;
        MORPHO = IMorpho(_morpho);
        COLLATERAL_VAULT_FACTORY = CollateralVaultFactory(_collateralVaultFactory);
    }

    /// @notice Execute a deleverage operation on a collateral vault
    /// @dev This function executes the following steps:
    /// 1. Takes underlying collateral (like WSTETH) flashloan from Morpho: asset received in this contract.
    /// 2. Transfer flashloaned amount to swapper.
    /// 3. Swapper.multicall is called which swaps flashloaned amount to target asset. Swap should transfer target asset to this contract.
    ///    optional: multicall also sweeps underlying collateral asset to this contract.
    /// 4. Repays collateral vault debt, and ensures the final debt is at most `maxDebt`.
    /// 5. Withdraws `withdrawCollateralAmount` of collateral from collateral vault.
    ///    Collateral vault redeems it to underlying collateral, and transfers it to this contract.
    /// 6. Approves Morpho to transfer target asset from this contract.
    /// 7. Morpho transferFroms the flashloaned target asset from this contract.
    /// 8. This contract transfers any remaining balance of underlying collateral and target asset to caller.
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
        address underlyingCollateral = IEVault(EulerCollateralVault(collateralVault).asset()).asset();

        MORPHO.flashLoan(
            underlyingCollateral,
            flashloanAmount,
            abi.encode(
                msgSender,
                collateralVault,
                targetAsset,
                underlyingCollateral,
                maxDebt,
                withdrawCollateralAmount,
                swapData
            )
        );

        IERC20(targetAsset).safeTransfer(msgSender, IERC20(targetAsset).balanceOf(address(this)));
        IERC20(underlyingCollateral).safeTransfer(msgSender, IERC20(underlyingCollateral).balanceOf(address(this)));

        emit T_LeverageDownExecuted(collateralVault);
    }

    /// @notice Callback function for Morpho flashloan
    /// @param amount Amount of tokens received in the flashloan
    /// @param data Encoded data containing swap and deposit parameters
    function onMorphoFlashLoan(uint amount, bytes calldata data) external {
        require(msg.sender == address(MORPHO), T_CallerNotMorpho());

        (
            address user,
            address collateralVault,
            address targetAsset,
            address underlyingCollateral,
            uint maxDebt,
            uint withdrawCollateralAmount,
            bytes[] memory swapData
        ) = abi.decode(data, (address, address, address, address, uint, uint, bytes[]));

        // Step 1: Transfer flashloaned underlying collateral asset to swapper
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
        IEVC(evc).call({
            targetContract: collateralVault,
            onBehalfOfAccount: user,
            value: 0,
            data: abi.encodeCall(CollateralVaultBase.redeemUnderlying, (withdrawCollateralAmount, address(this)))
        });

        // Step 5: Approve Morpho to take repayment
        IERC20(underlyingCollateral).forceApprove(address(MORPHO), amount);

        // Morpho will automatically pull the repayment amount
    }
}