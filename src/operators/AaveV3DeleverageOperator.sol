// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeERC20Lib, IERC20 as IERC20_Euler} from "euler-vault-kit/EVault/shared/lib/SafeERC20Lib.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {AaveV3CollateralVault} from "src/twyne/AaveV3CollateralVault.sol";
import {CollateralVaultBase} from "src/twyne/CollateralVaultBase.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {IAaveV3ATokenWrapper} from "src/interfaces/IAaveV3ATokenWrapper.sol";
import {IPool as IAaveV3Pool} from "aave-v3/interfaces/IPool.sol";
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

/// @title AaveV3DeleverageOperator
/// @notice Operator contract for executing 1-click deleverage operations on AaveV3 collateral vaults
/// @dev Uses Morpho flashloans to enable atomic unwinding of leveraged positions
contract AaveV3DeleverageOperator is ReentrancyGuardTransient, EVCUtil, IErrors, IEvents {
    using SafeERC20 for IERC20;

    address public immutable SWAPPER;
    IMorpho public immutable MORPHO;
    CollateralVaultFactory public immutable COLLATERAL_VAULT_FACTORY;
    address public immutable permit2;
    IAaveV3Pool public immutable AAVE_POOL;

    constructor(
        address _evc,
        address _swapper,
        address _morpho,
        address _collateralVaultFactory,
        address _permit2,
        address _aavePool
    ) EVCUtil(_evc) {
        SWAPPER = _swapper;
        MORPHO = IMorpho(_morpho);
        COLLATERAL_VAULT_FACTORY = CollateralVaultFactory(_collateralVaultFactory);
        permit2 = _permit2;
        AAVE_POOL = IAaveV3Pool(_aavePool);
    }

    /// @notice Execute a deleverage operation on an AaveV3 collateral vault
    /// @dev This function executes the following steps:
    /// 1. Takes underlying collateral (like WETH) flashloan from Morpho: asset received in this contract.
    /// 2. Transfer flashloaned amount to swapper.
    /// 3. Swapper.multicall is called which swaps flashloaned amount to target asset. Swap should transfer target asset to this contract.
    ///    optional: multicall also sweeps underlying collateral asset to this contract.
    /// 4. Repays collateral vault debt to Aave, and ensures the final debt is at most `maxDebt`.
    /// 5. Withdraws `withdrawWrapperAmount` of wrapper shares from collateral vault.
    ///    Collateral vault redeems wrapper shares to aTokens, then redeems aTokens to underlying, and transfers it to this contract.
    /// 6. Approves Morpho to transfer underlying collateral from this contract.
    /// 7. Morpho transferFroms the flashloaned underlying collateral from this contract.
    /// 8. This contract transfers any remaining balance of underlying collateral and target asset to caller.
    /// @param collateralVault Address of the user's AaveV3 collateral vault
    /// @param flashloanAmount Amount of underlying collateral asset to flashloan
    /// @param maxDebt Maximum amount of debt expected after deleveraging
    /// @param withdrawWrapperAmount Amount of wrapper shares to withdraw from collateral vault
    /// @param swapData Encoded swap instructions for the swapper
    function executeDeleverage(
        address collateralVault,
        uint flashloanAmount,
        uint maxDebt,
        uint withdrawWrapperAmount,
        bytes[] calldata swapData
    ) external nonReentrant {
        address msgSender = _msgSender();

        require(COLLATERAL_VAULT_FACTORY.isCollateralVault(collateralVault), T_InvalidCollateralVault());
        require(AaveV3CollateralVault(collateralVault).borrower() == msgSender, T_CallerNotBorrower());

        address targetAsset = AaveV3CollateralVault(collateralVault).targetAsset();
        address wrapperAsset = AaveV3CollateralVault(collateralVault).asset();
        address underlyingCollateral = IAaveV3ATokenWrapper(wrapperAsset).asset();

        MORPHO.flashLoan(
            underlyingCollateral,
            flashloanAmount,
            abi.encode(
                msgSender,
                collateralVault,
                targetAsset,
                underlyingCollateral,
                maxDebt,
                withdrawWrapperAmount,
                swapData
            )
        );

        // Transfer remaining balances to user
        uint targetBalance = IERC20(targetAsset).balanceOf(address(this));
        if (targetBalance > 0) {
            IERC20(targetAsset).safeTransfer(msgSender, targetBalance);
        }

        uint underlyingBalance = IERC20(underlyingCollateral).balanceOf(address(this));
        if (underlyingBalance > 0) {
            IERC20(underlyingCollateral).safeTransfer(msgSender, underlyingBalance);
        }

        emit T_LeverageDownExecuted(collateralVault);
    }

    /// @notice Callback function for Morpho flashloan
    /// @param amount Amount of tokens received in the flashloan
    /// @param data Encoded data containing swap and repay parameters
    function onMorphoFlashLoan(uint amount, bytes calldata data) external {
        require(msg.sender == address(MORPHO), T_CallerNotMorpho());

        (
            address user,
            address collateralVault,
            address targetAsset,
            address underlyingCollateral,
            uint maxDebt,
            uint withdrawWrapperAmount,
            bytes[] memory swapData
        ) = abi.decode(data, (address, address, address, address, uint, uint, bytes[]));

        // Get Aave token addresses
        address vToken = AaveV3CollateralVault(collateralVault).aaveDebtToken();

        // Step 1: Transfer flashloaned underlying collateral asset to swapper
        IERC20(underlyingCollateral).safeTransfer(SWAPPER, amount);

        // Step 2: Execute swap underlying collateral -> target asset through multicall.
        // This contract receives the target asset.
        ISwapper(SWAPPER).multicall(swapData);

        // Step 3: Repay debt directly to Aave pool
        {
            uint debtToRepay = Math.min(
                IERC20(targetAsset).balanceOf(address(this)),
                IERC20(vToken).balanceOf(collateralVault)
            );

            if (debtToRepay > 0) {
                // Approve and repay directly to Aave pool on behalf of collateral vault
                IERC20(targetAsset).forceApprove(address(AAVE_POOL), debtToRepay);
                AAVE_POOL.repay(targetAsset, debtToRepay, 2, collateralVault); // 2 = variable rate mode
            }
        }

        // Check debt is below max
        require(IERC20(vToken).balanceOf(collateralVault) <= maxDebt, T_DebtMoreThanMax());

        // Step 4: Withdraw underlying collateral from vault
        if (withdrawWrapperAmount > 0) {
            IEVC(evc).call({
                targetContract: collateralVault,
                onBehalfOfAccount: user,
                value: 0,
                data: abi.encodeCall(CollateralVaultBase.redeemUnderlying, (withdrawWrapperAmount, address(this)))
            });
        }

        // Step 5: Approve Morpho to take repayment
        IERC20(underlyingCollateral).forceApprove(address(MORPHO), amount);

        // Morpho will automatically pull the repayment amount
    }
}