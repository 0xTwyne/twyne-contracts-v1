// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
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

interface ISwapper {
    function multicall(bytes[] memory calls) external;
}

/// @title AaveV3LeverageOperator
/// @notice Operator contract for executing 1-click leverage operations on AaveV3 collateral vaults
/// @dev Uses Morpho flashloans to enable atomic leverage operations with AaveV3 wrapper tokens
contract AaveV3LeverageOperator is ReentrancyGuardTransient, EVCUtil, IErrors, IEvents {
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

    /// @notice Execute a leverage operation on an AaveV3 collateral vault
    /// @dev This function executes the following steps:
    /// 1. Takes user's collateral
    ///    a. Takes user's underlying collateral, deposits it to AaveV3 wrapper and transfers wrapper shares to collateral vault
    ///    b. Takes user's aTokens, deposits them to AaveV3 wrapper and transfers wrapper shares to collateral vault
    /// 2. Takes target asset flashloan from Morpho: target asset received in this contract
    /// 3. Transfers received target asset to Swapper
    /// 4. Swapper.multicall is called which swaps target asset to underlying collateral which is sent to AaveV3 wrapper
    /// 5. SwapVerifier.verifyAmountMinAndDeposit is called which does minAmountOut check and calls deposit on AaveV3 wrapper.
    ///    AaveV3Wrapper.deposit deposits underlying collateral and transfers wrapper shares to collateral vault
    /// 6. EVC batch calls
    ///    a. skim on collateral vault to deposit all the airdropped wrapper shares
    ///    b. borrow on collateral vault to borrow target asset, this contract receives the borrowed amount
    /// 7. Approves Morpho to transfer target asset from this contract
    /// 8. Morpho transferFroms the flashloaned target asset from this contract
    /// @param collateralVault Address of the user's AaveV3 collateral vault
    /// @param underlyingCollateralAmount Amount of underlying collateral the user is providing
    /// @param aTokenCollateralAmount Amount of aTokens the user is providing
    /// @param flashloanAmount Amount of target asset to flashloan
    /// @param minAmountOut Minimum amount of underlying collateral expected from swap
    /// @param deadline Deadline timestamp for the swap verification
    /// @param swapData Encoded swap instructions for the swapper
    function executeLeverage(
        address collateralVault,
        uint underlyingCollateralAmount,
        uint aTokenCollateralAmount,
        uint flashloanAmount,
        uint minAmountOut,
        uint deadline,
        bytes[] calldata swapData
    ) external nonReentrant {
        address msgSender = _msgSender();

        require(COLLATERAL_VAULT_FACTORY.isCollateralVault(collateralVault), T_InvalidCollateralVault());
        require(AaveV3CollateralVault(collateralVault).borrower() == msgSender, T_CallerNotBorrower());

        address targetAsset = AaveV3CollateralVault(collateralVault).targetAsset();

        MORPHO.flashLoan(
            targetAsset,
            flashloanAmount,
            abi.encode(
                msgSender,
                targetAsset,
                collateralVault,
                underlyingCollateralAmount,
                aTokenCollateralAmount,
                minAmountOut,
                deadline,
                swapData
            )
        );

        emit T_LeverageUpExecuted(collateralVault);
    }

    /// @notice Callback function for Morpho flashloan
    /// @param amount Amount of tokens received in the flashloan
    /// @param data Encoded data containing swap and deposit parameters
    function onMorphoFlashLoan(uint amount, bytes calldata data) external {
        require(msg.sender == address(MORPHO), T_CallerNotMorpho());

        (
            address user,
            address targetAsset,
            address collateralVault,
            uint underlyingCollateralAmount,
            uint aTokenCollateralAmount,
            uint minAmountOut,
            uint deadline,
            bytes[] memory swapData
        ) = abi.decode(data, (address, address, address, uint, uint, uint, uint, bytes[]));

        address wrapperAsset = AaveV3CollateralVault(collateralVault).asset();
        address aToken = IAaveV3ATokenWrapper(wrapperAsset).aToken();

        // Step 1: Transfer flashloaned target asset to swapper
        IERC20(targetAsset).safeTransfer(SWAPPER, amount);

        // Step 2: Execute swap target asset -> underlying collateral through multicall.
        // This contract receives the underlying collateral.
        ISwapper(SWAPPER).multicall(swapData);

        // Step 3: Check minimum amount received from swap
        {
            address underlyingCollateral = IAaveV3ATokenWrapper(wrapperAsset).asset();
            uint totalUnderlyingToSupply = IERC20(underlyingCollateral).balanceOf(address(this));
            require(totalUnderlyingToSupply >= minAmountOut, "Slippage check failed");
            require(block.timestamp <= deadline, "Deadline expired");

            // Step 4: Collect user's collateral contributions

            if (underlyingCollateralAmount > 0) {
                SafeERC20Lib.safeTransferFrom(IERC20_Euler(underlyingCollateral), user, address(this), underlyingCollateralAmount, permit2);
                totalUnderlyingToSupply += underlyingCollateralAmount;
            }

            if (aTokenCollateralAmount > 0) {
                SafeERC20Lib.safeTransferFrom(IERC20_Euler(aToken), user, address(this), aTokenCollateralAmount, permit2);
            }

            // Step 5: Supply all underlying collateral to Aave
            IERC20(underlyingCollateral).forceApprove(address(AAVE_POOL), totalUnderlyingToSupply);
            AAVE_POOL.supply(underlyingCollateral, totalUnderlyingToSupply, address(this), 0);
        }

        // Step 6: Deposit all aTokens to wrapper and send shares to collateral vault
        IERC20(aToken).forceApprove(wrapperAsset, type(uint).max);
        IAaveV3ATokenWrapper(wrapperAsset).depositATokens(type(uint).max, collateralVault);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // Deposit all airdropped wrapper shares to collateral vault
        items[0] = IEVC.BatchItem({
            targetContract: collateralVault,
            onBehalfOfAccount: user,
            value: 0,
            data: abi.encodeCall(CollateralVaultBase.skim, ())
        });

        // Borrow target asset from collateral vault (amount needed to repay flashloan)
        items[1] = IEVC.BatchItem({
            targetContract: collateralVault,
            onBehalfOfAccount: user,
            value: 0,
            data: abi.encodeCall(CollateralVaultBase.borrow, (amount, address(this)))
        });

        IEVC(evc).batch(items);

        // Step 6: Approve Morpho to take repayment
        IERC20(targetAsset).forceApprove(address(MORPHO), amount);

        // Morpho will automatically pull the repayment amount
    }
}