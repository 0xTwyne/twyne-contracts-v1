// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {MorphoCollateralVault} from "src/twyne/MorphoCollateralVault.sol";
import {CollateralVaultBase} from "src/twyne/CollateralVaultBase.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {IMorpho, MarketParams} from "morpho/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "morpho/libraries/periphery/MorphoBalancesLib.sol";
import {MorphoLib} from "morpho/libraries/periphery/MorphoLib.sol";
import {MarketParamsLib} from "morpho/libraries/MarketParamsLib.sol";
import {IErrors} from "src/interfaces/IErrors.sol";
import {IEvents} from "src/interfaces/IEvents.sol";
import {ReentrancyGuardTransient} from "openzeppelin-contracts/utils/ReentrancyGuardTransient.sol";
import {EVCUtil} from "ethereum-vault-connector/utils/EVCUtil.sol";

interface ISwapper {
    function multicall(bytes[] memory calls) external;
}

/// @title MorphoDeleverageOperator
/// @notice Operator contract for executing 1-click deleverage operations on MorphoCollateralVaults
/// @dev Uses Morpho flashloans to enable atomic unwinding of leveraged positions.
/// Flow: flashloan collateral → swap to loan token → repay Morpho debt → withdraw collateral → repay flashloan
contract MorphoDeleverageOperator is ReentrancyGuardTransient, EVCUtil, IErrors, IEvents {
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

    /// @notice Execute a deleverage operation on a MorphoCollateralVault
    /// @dev This function executes the following steps:
    /// 1. Takes collateral token (WSTETH) flashloan from Morpho
    /// 2. Swaps collateral token to loan token (WETH) via Swapper multicall
    /// 3. Repays vault's Morpho debt directly, ensures final debt ≤ maxDebt
    /// 4. Withdraws collateral from the vault via EVC call
    /// 5. Repays the flashloan
    /// 6. Transfers remaining balances to user
    /// @param collateralVault Address of the user's MorphoCollateralVault
    /// @param flashloanAmount Amount of collateral token to flashloan
    /// @param maxDebt Maximum amount of debt expected after deleveraging
    /// @param withdrawCollateralAmount Amount of collateral to withdraw from the vault
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
        require(MorphoCollateralVault(collateralVault).borrower() == msgSender, T_CallerNotBorrower());

        MarketParams memory mp = MorphoCollateralVault(collateralVault).marketParams();

        MORPHO.flashLoan(
            mp.collateralToken,
            flashloanAmount,
            abi.encode(
                msgSender,
                collateralVault,
                mp,
                maxDebt,
                withdrawCollateralAmount,
                swapData
            )
        );

        // Transfer remaining balances to user
        uint loanTokenBalance = IERC20(mp.loanToken).balanceOf(address(this));
        if (loanTokenBalance > 0) {
            IERC20(mp.loanToken).safeTransfer(msgSender, loanTokenBalance);
        }

        uint collateralBalance = IERC20(mp.collateralToken).balanceOf(address(this));
        if (collateralBalance > 0) {
            IERC20(mp.collateralToken).safeTransfer(msgSender, collateralBalance);
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
            MarketParams memory mp,
            uint maxDebt,
            uint withdrawCollateralAmount,
            bytes[] memory swapData
        ) = abi.decode(data, (address, address, MarketParams, uint, uint, bytes[]));

        // Step 1: Transfer flashloaned collateral token to swapper
        IERC20(mp.collateralToken).safeTransfer(SWAPPER, amount);

        // Step 2: Execute swap collateral token -> loan token through multicall
        ISwapper(SWAPPER).multicall(swapData);

        // Step 3: Repay vault's Morpho debt directly
        uint loanTokenBalance = IERC20(mp.loanToken).balanceOf(address(this));
        uint currentDebt = MorphoBalancesLib.expectedBorrowAssets(MORPHO, mp, collateralVault);

        if (loanTokenBalance > 0 && currentDebt > 0) {
            IERC20(mp.loanToken).forceApprove(address(MORPHO), loanTokenBalance);
            if (loanTokenBalance >= currentDebt) {
                // Repay all debt by shares to avoid rounding issues with asset-based repay
                uint borrowShares = MorphoLib.borrowShares(MORPHO, MarketParamsLib.id(mp), collateralVault);
                MORPHO.repay({marketParams: mp, assets: 0, shares: borrowShares, onBehalf: collateralVault, data: ""});
            } else {
                // Partial repay by assets
                MORPHO.repay({marketParams: mp, assets: loanTokenBalance, shares: 0, onBehalf: collateralVault, data: ""});
            }
        }

        // Check debt is below max
        uint remainingDebt = MorphoBalancesLib.expectedBorrowAssets(MORPHO, mp, collateralVault);
        require(remainingDebt <= maxDebt, T_DebtMoreThanMax());

        // Step 4: Withdraw collateral from vault
        if (withdrawCollateralAmount > 0) {
            IEVC(evc).call({
                targetContract: collateralVault,
                onBehalfOfAccount: user,
                value: 0,
                data: abi.encodeCall(CollateralVaultBase.withdraw, (withdrawCollateralAmount, address(this)))
            });
        }

        // Step 5: Approve Morpho to take flashloan repayment
        IERC20(mp.collateralToken).forceApprove(address(MORPHO), amount);
    }
}
