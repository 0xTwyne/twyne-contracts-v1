// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {MorphoCollateralVault} from "src/twyne/MorphoCollateralVault.sol";
import {CollateralVaultBase} from "src/twyne/CollateralVaultBase.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {IMorpho, MarketParams, Id} from "morpho/interfaces/IMorpho.sol";
import {MorphoLib} from "morpho/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "morpho/libraries/periphery/MorphoBalancesLib.sol";
import {MarketParamsLib} from "morpho/libraries/MarketParamsLib.sol";
import {IErrors} from "src/interfaces/IErrors.sol";
import {IEvents} from "src/interfaces/IEvents.sol";
import {ReentrancyGuardTransient} from "openzeppelin-contracts/utils/ReentrancyGuardTransient.sol";
import {EVCUtil} from "ethereum-vault-connector/utils/EVCUtil.sol";

/// @title MorphoTeleportOperator
/// @notice Operator contract for migrating existing Morpho Blue positions to MorphoCollateralVault
/// @dev Uses Morpho flashloans to enable atomic migration of debt positions.
/// @dev The user must authorize this operator on Morpho (`setAuthorization`) before calling `executeTeleport`.
contract MorphoTeleportOperator is ReentrancyGuardTransient, EVCUtil, IErrors, IEvents {
    using SafeERC20 for IERC20;

    IMorpho public immutable MORPHO;
    CollateralVaultFactory public immutable COLLATERAL_VAULT_FACTORY;

    constructor(
        address _evc,
        address _morpho,
        address _collateralVaultFactory
    ) EVCUtil(_evc) {
        MORPHO = IMorpho(_morpho);
        COLLATERAL_VAULT_FACTORY = CollateralVaultFactory(_collateralVaultFactory);
    }

    /// @notice Migrate an existing Morpho Blue position to a MorphoCollateralVault
    /// @dev This function executes the following steps:
    /// 1. Takes a flashloan of the loan token from Morpho
    /// 2. Repays the user's existing Morpho debt
    /// 3. Withdraws the user's collateral from Morpho
    /// 4. Transfers collateral to the collateral vault and calls skim + borrow via EVC batch
    /// 5. Repays the flashloan
    /// @dev The user must have authorized this operator on Morpho (`setAuthorization`) prior to calling.
    /// @param collateralVault Address of the user's MorphoCollateralVault
    /// @param collateralAmount Amount of collateral to migrate (use type(uint).max for full balance)
    /// @param debtAmount Amount of debt to migrate (use type(uint).max for full debt)
    function executeTeleport(
        address collateralVault,
        uint collateralAmount,
        uint debtAmount
    ) external nonReentrant {
        address msgSender = _msgSender();

        require(COLLATERAL_VAULT_FACTORY.isCollateralVault(collateralVault), T_InvalidCollateralVault());
        require(MorphoCollateralVault(collateralVault).borrower() == msgSender, T_CallerNotBorrower());

        MarketParams memory mp = MorphoCollateralVault(collateralVault).marketParams();
        Id marketId = MarketParamsLib.id(mp);

        if (debtAmount == type(uint).max) {
            // Full migration: expectedBorrowAssets and repay(shares=...) both use round-up conversion.
            // Morpho's repay path can overrun by at most 1 wei, so +1 safely covers the full-share repayment.
            uint fullDebt = MorphoBalancesLib.expectedBorrowAssets(MORPHO, mp, msgSender);
            debtAmount = fullDebt == 0 ? 0 : fullDebt + 1;
        }

        if (collateralAmount == type(uint).max) {
            collateralAmount = MorphoLib.collateral(MORPHO, marketId, msgSender);
        }

        if (debtAmount == 0) {
            if (collateralAmount > 0) {
                MORPHO.withdrawCollateral({
                    marketParams: mp,
                    assets: collateralAmount,
                    onBehalf: msgSender,
                    receiver: collateralVault
                });

                IEVC(evc).call({
                    targetContract: collateralVault,
                    onBehalfOfAccount: msgSender,
                    value: 0,
                    data: abi.encodeCall(CollateralVaultBase.skim, ())
                });
            }

            emit T_Teleport(collateralAmount, 0);
            return;
        }

        // Take flashloan to repay user's debt
        MORPHO.flashLoan(
            mp.loanToken,
            debtAmount,
            abi.encode(
                msgSender,
                collateralVault,
                mp,
                marketId,
                collateralAmount
            )
        );

        emit T_Teleport(collateralAmount, debtAmount);
    }

    /// @notice Callback function for Morpho flashloan
    /// @param amount Amount of tokens received in the flashloan
    /// @param data Encoded data containing migration parameters
    function onMorphoFlashLoan(uint amount, bytes calldata data) external {
        require(msg.sender == address(MORPHO), T_CallerNotMorpho());

        (
            address user,
            address collateralVault,
            MarketParams memory mp,
            Id marketId,
            uint collateralAmount
        ) = abi.decode(data, (address, address, MarketParams, Id, uint));

        // Step 1: Repay user's existing Morpho debt.
        // Full migration repays by shares (to clear residual rounding dust); partial migration repays by assets.
        uint assetsToBorrow;
        uint borrowShares = MorphoLib.borrowShares(MORPHO, marketId, user);
        if (borrowShares > 0) {
            uint expectedDebt = MorphoBalancesLib.expectedBorrowAssets(MORPHO, mp, user);
            IERC20(mp.loanToken).forceApprove(address(MORPHO), amount);
            if (amount >= expectedDebt) {
                // Full repayment: repay by shares to clear dust
                (assetsToBorrow,) = MORPHO.repay({
                    marketParams: mp,
                    assets: 0,
                    shares: borrowShares,
                    onBehalf: user,
                    data: ""
                });
            } else {
                // Partial repayment: repay by assets
                (assetsToBorrow,) = MORPHO.repay({
                    marketParams: mp,
                    assets: amount,
                    shares: 0,
                    onBehalf: user,
                    data: ""
                });
            }
        }

        // Step 2: Withdraw user's collateral from Morpho (requires user authorization on Morpho)
        if (collateralAmount > 0) {
            MORPHO.withdrawCollateral({
                marketParams: mp,
                assets: collateralAmount,
                onBehalf: user,
                receiver: collateralVault
            });
        }

        // Step 3: Use EVC batch to deposit collateral and borrow from collateral vault
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // Skim to register the airdropped collateral in the vault
        items[0] = IEVC.BatchItem({
            targetContract: collateralVault,
            onBehalfOfAccount: user,
            value: 0,
            data: abi.encodeCall(CollateralVaultBase.skim, ())
        });

        // Borrow from collateral vault to repay flashloan
        items[1] = IEVC.BatchItem({
            targetContract: collateralVault,
            onBehalfOfAccount: user,
            value: 0,
            data: abi.encodeCall(CollateralVaultBase.borrow, (assetsToBorrow, address(this)))
        });

        IEVC(evc).batch(items);

        // Step 4: Approve Morpho to pull flashloan repayment
        IERC20(mp.loanToken).forceApprove(address(MORPHO), amount);
    }
}
