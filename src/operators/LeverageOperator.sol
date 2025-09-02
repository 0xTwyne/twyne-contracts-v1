// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {EulerCollateralVault, IEVault} from "src/twyne/EulerCollateralVault.sol";
import {CollateralVaultBase} from "src/twyne/CollateralVaultBase.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {IErrors} from "src/interfaces/IErrors.sol";
import {IEvents} from "src/interfaces/IEvents.sol";

interface IMorpho {
    function flashLoan(address token, uint assets, bytes calldata data) external;
}

interface ISwapper {
    function multicall(bytes[] memory calls) external;
}

interface ISwapVerifier {
    function verifyAmountMinAndSkim(address eulerVault, address receiver, uint amountMin, uint deadline) external;
}

/// @title LeverageOperator
/// @notice Operator contract for executing 1-click leverage operations on collateral vaults
/// @dev Uses Morpho flashloans to enable atomic leverage operations
contract LeverageOperator is IErrors, IEvents {
    using SafeERC20 for IERC20;

    // Immutable addresses
    address public immutable EVC;
    address public immutable SWAPPER;
    address public immutable SWAP_VERIFIER;
    IMorpho public immutable MORPHO;
    CollateralVaultFactory public immutable COLLATERAL_VAULT_FACTORY;

    // Transient storage for flashloan state
    bool private transient flashloanLock;
    uint private transient initialCollateralBalance;

    /// @notice Constructor to initialize the operator with required addresses
    /// @param _evc Address of the Ethereum Vault Connector
    /// @param _swapper Address of the swapper contract for token swaps
    /// @param _swapVerifier Address of the swap verifier contract
    /// @param _morpho Address of the Morpho protocol for flashloans
    /// @param _collateralVaultFactory Address of the CollateralVaultFactory
    constructor(
        address _evc,
        address _swapper,
        address _swapVerifier,
        address _morpho,
        address _collateralVaultFactory
    ) {
        EVC = _evc;
        SWAPPER = _swapper;
        SWAP_VERIFIER = _swapVerifier;
        MORPHO = IMorpho(_morpho);
        COLLATERAL_VAULT_FACTORY = CollateralVaultFactory(_collateralVaultFactory);
    }

    /// @notice Execute a leverage operation on a collateral vault
    /// @dev This function executes the following steps:
    /// 1. Takes user's collateral
    ///    a. Takes user's underlying collateral, deposit it to Euler vault and the collateral to collateral vault
    ///    b. Takes user's collateral, transfer it to collateral vault
    /// 2. Takes target asset flashloan from Morpho: target asset received in this contract
    /// 3. Transfers received target asset to Swapper
    /// 4. Swapper.multicall is called which swaps target asset to underlying collateral which is sent to Euler vault
    /// 5. SwapVerifier.verifyAmountMinAndSkim is called which does minAmountOut check and calls skim on Euler vault.
    ///    EulerVault.skim deposits underlying collateral and transfers Euler vault tokens (collateral) to collateral vault
    /// 6. EVC batch calls
    ///    a. skim on collateral vault to deposit all the airdropped collateral
    ///    b. borrow on collateral vault to borrow target asset, this contract receives the borrowed amount
    /// 7. Approves Morpho to transfer target asset from this contract
    /// 8. Morpho transferFroms the flashloaned target asset from this contract
    /// @param collateralVault Address of the user's collateral vault
    /// @param underlyingCollateralAmount Amount of underlying collateral the user is providing
    /// @param collateralAmount Amount of collateral the user is providing
    /// @param flashloanAmount Amount of target asset to flashloan
    /// @param minAmountOut Minimum amount of WETH expected from swap
    /// @param deadline Deadline timestamp for the swap verification
    /// @param swapData Encoded swap instructions for the swapper
    function executeLeverage(
        address collateralVault,
        uint underlyingCollateralAmount,
        uint collateralAmount,
        uint flashloanAmount,
        uint minAmountOut,
        uint deadline,
        bytes[] calldata swapData
    ) external {
        require(COLLATERAL_VAULT_FACTORY.isCollateralVault(collateralVault), T_InvalidCollateralVault());

        EulerCollateralVault vault = EulerCollateralVault(collateralVault);
        require(vault.borrower() == msg.sender, T_CallerNotBorrower());

        address collateral = vault.asset();
        address targetAsset = vault.targetAsset();

        initialCollateralBalance = IERC20(collateral).balanceOf(address(this));

        {
            if (underlyingCollateralAmount > 0) {
                address underlyingCollateral = IEVault(collateral).asset();
                IERC20(underlyingCollateral).safeTransferFrom(msg.sender, address(this), underlyingCollateralAmount);
                IERC20(underlyingCollateral).forceApprove(collateral, underlyingCollateralAmount);
                IEVault(collateral).deposit(underlyingCollateralAmount, collateralVault);
            }
            if (collateralAmount > 0) {
                IEVault(collateral).transferFrom(msg.sender, collateralVault, collateralAmount);
            }
        }

        flashloanLock = true;

        MORPHO.flashLoan(
            targetAsset,
            flashloanAmount,
            abi.encode(
                msg.sender,
                collateralVault,
                collateral,
                targetAsset,
                minAmountOut,
                deadline,
                swapData
            )
        );

        flashloanLock = false;
        delete initialCollateralBalance;

        emit T_LeverageUpExecuted(collateralVault);
    }

    /// @notice Callback function for Morpho flashloan
    /// @param amount Amount of tokens received in the flashloan
    /// @param data Encoded data containing swap and deposit parameters
    function onMorphoFlashLoan(uint amount, bytes calldata data) external {
        require(msg.sender == address(MORPHO), T_CallerNotMorpho());

        require(flashloanLock, T_FlashloanNotActive());

        (
            address user,
            address collateralVault,
            address collateral,
            address targetAsset,
            uint minAmountOut,
            uint deadline,
            bytes[] memory swapData
        ) = abi.decode(data, (address, address, address, address, uint, uint, bytes[]));

        // Step 1: Transfer flashloaned target asset to swapper
        IERC20(targetAsset).transfer(SWAPPER, amount);

        // Step 2: Execute swap target asset -> underlying collateral through multicall.
        // Euler vault receives the underlying collateral.
        ISwapper(SWAPPER).multicall(swapData);

        // Step 3: Verify swap output and skim collateral to collateral vault
        // The swap sends underlying collateral to Euler vault, which then needs to be skimmed.
        // Collateral vault receives the collateral.
        ISwapVerifier(SWAP_VERIFIER).verifyAmountMinAndSkim(
            collateral,
            collateralVault,
            minAmountOut,
            deadline
        );

        // Create batch items for EVC
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // Deposit all airdropped collateral to collateral vault
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

        // Execute batch through EVC
        IEVC(EVC).batch(items);

        // Step 6: Approve Morpho to take repayment
        IERC20(targetAsset).approve(address(MORPHO), amount);

        // Morpho will automatically pull the repayment amount
    }
}