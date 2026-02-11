// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {SafeERC20Lib, IERC20 as IERC20_Euler} from "euler-vault-kit/EVault/shared/lib/SafeERC20Lib.sol";
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

/// @title AaveV3TeleportOperator
/// @notice Operator contract for migrating existing Aave V3 positions to AaveV3CollateralVault
/// @dev Uses Morpho flashloans to enable atomic migration of debt positions
contract AaveV3TeleportOperator is ReentrancyGuardTransient, EVCUtil, IErrors, IEvents {
    using SafeERC20 for IERC20;

    IMorpho public immutable MORPHO;
    CollateralVaultFactory public immutable COLLATERAL_VAULT_FACTORY;
    address public immutable permit2;
    IAaveV3Pool public immutable AAVE_POOL;

    constructor(
        address _evc,
        address _morpho,
        address _collateralVaultFactory,
        address _permit2,
        address _aavePool
    ) EVCUtil(_evc) {
        MORPHO = IMorpho(_morpho);
        COLLATERAL_VAULT_FACTORY = CollateralVaultFactory(_collateralVaultFactory);
        permit2 = _permit2;
        AAVE_POOL = IAaveV3Pool(_aavePool);
    }

    /// @notice Migrate an existing Aave V3 position to an AaveV3CollateralVault
    /// @dev This function executes the following steps:
    /// 1. Takes a flashloan of the target asset (debt token) from Morpho
    /// 2. Repays the user's existing Aave debt
    /// 3. Transfers the user's aTokens to the wrapper and deposits to collateral vault
    /// 4. Borrows from the collateral vault to repay the flashloan
    /// @param collateralVault Address of the user's AaveV3 collateral vault
    /// @param aTokenAmount Amount of aTokens to transfer from user's position
    /// @param debtAmount Amount of debt to migrate (use type(uint).max for full debt)
    function executeTeleport(
        address collateralVault,
        uint aTokenAmount,
        uint debtAmount
    ) external nonReentrant {
        address msgSender = _msgSender();

        require(COLLATERAL_VAULT_FACTORY.isCollateralVault(collateralVault), T_InvalidCollateralVault());
        require(AaveV3CollateralVault(collateralVault).borrower() == msgSender, T_CallerNotBorrower());

        address targetAsset = AaveV3CollateralVault(collateralVault).targetAsset();
        address wrapperAsset = AaveV3CollateralVault(collateralVault).asset();
        address aToken = IAaveV3ATokenWrapper(wrapperAsset).aToken();
        address vToken = AaveV3CollateralVault(collateralVault).aaveDebtToken();

        debtAmount = Math.min(IERC20(vToken).balanceOf(msgSender), debtAmount);

        if (aTokenAmount == type(uint).max) {
            aTokenAmount = IERC20(aToken).balanceOf(msgSender);
        }

        // Take flashloan to repay user's debt
        MORPHO.flashLoan(
            targetAsset,
            debtAmount,
            abi.encode(
                msgSender,
                collateralVault,
                targetAsset,
                wrapperAsset,
                aToken,
                aTokenAmount
            )
        );

        emit T_Teleport(aTokenAmount, debtAmount);
    }

    /// @notice Callback function for Morpho flashloan
    /// @param amount Amount of tokens received in the flashloan
    /// @param data Encoded data containing migration parameters
    function onMorphoFlashLoan(uint amount, bytes calldata data) external {
        require(msg.sender == address(MORPHO), T_CallerNotMorpho());

        (
            address user,
            address collateralVault,
            address targetAsset,
            address wrapperAsset,
            address aToken,
            uint aTokenAmount
        ) = abi.decode(data, (address, address, address, address, address, uint));

        // Step 1: Repay user's existing Aave debt
        IERC20(targetAsset).forceApprove(address(AAVE_POOL), amount);
        AAVE_POOL.repay(targetAsset, amount, 2, user); // 2 = variable rate mode

        // Step 2: Transfer aTokens from user to this contract
        SafeERC20Lib.safeTransferFrom(IERC20_Euler(aToken), user, address(this), aTokenAmount, permit2);

        // Step 3: Deposit aTokens to wrapper and send shares to collateral vault
        IERC20(aToken).approve(wrapperAsset, type(uint).max);
        IAaveV3ATokenWrapper(wrapperAsset).depositATokens(type(uint).max, collateralVault);

        // Step 4: Use EVC batch to deposit wrapper shares and borrow from collateral vault
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // Deposit wrapper shares to collateral vault
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
            data: abi.encodeCall(CollateralVaultBase.borrow, (amount, address(this)))
        });

        IEVC(evc).batch(items);

        // Step 5: Approve Morpho to take repayment
        IERC20(targetAsset).forceApprove(address(MORPHO), amount);

        // Morpho will automatically pull the repayment amount
    }
}