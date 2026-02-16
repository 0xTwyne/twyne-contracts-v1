// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
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

interface ISwapVerifier {
    function verifyAmountMinAndSkim(address eulerVault, address receiver, uint amountMin, uint deadline) external;
}

/// @title LeverageOperator_EulerFL
/// @notice Operator contract for executing 1-click leverage operations on collateral vaults
/// @dev Uses Euler flashloans to enable atomic leverage operations
contract LeverageOperator_EulerFL is ReentrancyGuardTransient, EVCUtil, IErrors, IEvents {
    using SafeERC20 for IERC20;

    address public immutable SWAPPER;
    address public immutable SWAP_VERIFIER;
    CollateralVaultFactory public immutable COLLATERAL_VAULT_FACTORY;
    IEVC public immutable EULER_EVC;

    constructor(
        address _eulerEVC,
        address _twyneEVC,
        address _swapper,
        address _swapVerifier,
        address _collateralVaultFactory
    ) EVCUtil(_twyneEVC) {
        EULER_EVC = IEVC(_eulerEVC);
        SWAPPER = _swapper;
        SWAP_VERIFIER = _swapVerifier;
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

    /// @notice Execute a leverage operation on a collateral vault
    /// @dev This function executes the following steps:
    /// 1. Takes user's collateral
    ///    a. Takes user's underlying collateral, deposit it to Euler vault and the collateral to collateral vault
    ///    b. Takes user's collateral, transfer it to collateral vault
    /// 2. Takes target asset flashloan from targetVault: target asset received in this contract
    /// 3. Transfers received target asset to Swapper
    /// 4. Swapper.multicall is called which swaps target asset to underlying collateral which is sent to Euler vault
    /// 5. SwapVerifier.verifyAmountMinAndSkim is called which does minAmountOut check and calls skim on Euler vault.
    ///    EulerVault.skim deposits underlying collateral and transfers Euler vault tokens (collateral) to collateral vault
    /// 6. EVC batch calls
    ///    a. skim on collateral vault to deposit all the airdropped collateral
    ///    b. borrow on collateral vault to borrow target asset, this contract receives the borrowed amount
    /// 7. Transfers target asset to targetVault to repay flashloan
    /// @param collateralVault Address of the user's collateral vault
    /// @param underlyingCollateralAmount Amount of underlying collateral the user is providing
    /// @param collateralAmount Amount of collateral the user is providing
    /// @param flashloanAmount Amount of target asset to flashloan
    /// @param callbackData ABI encoded bytes containing
    ///        `minAmountOut` Minimum amount of WETH expected from swap
    ///        `deadline` Deadline timestamp for the swap verification
    ///        `swapData` Encoded swap instructions for the swapper
    function executeLeverage(
        address collateralVault,
        uint underlyingCollateralAmount,
        uint collateralAmount,
        uint flashloanAmount,
        bytes calldata callbackData
    ) external nonReentrant {
        address msgSender = _msgSender();

        require(COLLATERAL_VAULT_FACTORY.isCollateralVault(collateralVault), T_InvalidCollateralVault());

        require(EulerCollateralVault(collateralVault).borrower() == msgSender, T_CallerNotBorrower());

        address collateral = EulerCollateralVault(collateralVault).asset();
        address targetVault = EulerCollateralVault(collateralVault).targetVault();

        {
            if (underlyingCollateralAmount > 0) {
                address underlyingCollateral = IEVault(collateral).asset();
                IERC20(underlyingCollateral).safeTransferFrom(msgSender, collateral, underlyingCollateralAmount);
                IEVault(collateral).skim(underlyingCollateralAmount, collateralVault);
            }
            if (collateralAmount > 0) {
                IEVault(collateral).transferFrom(msgSender, collateralVault, collateralAmount);
            }
        }

        bytes memory flashloanData = abi.encodeCall(
            this.onFlashLoan, (
                targetVault,
                flashloanAmount,
                msgSender,
                collateralVault,
                collateral,
                callbackData
            ));

        IEVC.BatchItem[] memory eulerFL_items = new IEVC.BatchItem[](5);

        eulerFL_items[0] = IEVC.BatchItem({
            targetContract: address(EULER_EVC),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeCall(IEVC.enableController, (address(this), address(targetVault)))
        });
        // 2) borrow to THIS contract
        eulerFL_items[1] = IEVC.BatchItem({
            targetContract: address(targetVault),
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
        // 4) repay from the contract’s address(this)
        eulerFL_items[3] = IEVC.BatchItem({
            targetContract: address(targetVault),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeCall(IBorrowing.repay, (flashloanAmount, address(this)))
        });
        // 5) Disable controller
        eulerFL_items[4] = IEVC.BatchItem({
            targetContract: address(targetVault),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeCall(IRiskManager.disableController, ())
        });

        EULER_EVC.batch(eulerFL_items);

        emit T_LeverageUpExecuted(collateralVault);
    }

    /// @notice Callback function for Euler flashloan
    function onFlashLoan(
        address targetVault,
        uint amount,
        address user,
        address collateralVault,
        address collateral,
        bytes calldata callbackData
    ) external {
        require(_msgSenderEulerEVC() == address(this), T_CallerNotSelf());

        address targetAsset = IEVault(targetVault).asset();
        // Step 1: Transfer flashloaned target asset to swapper
        IERC20(targetAsset).safeTransfer(SWAPPER, amount);

        (uint minAmountOut, uint deadline, bytes[] memory swapData) = abi.decode(callbackData, (uint, uint, bytes[]));

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

        evc.batch(items);

        // Step 6: Approve targetVault to repay flashloan
        IERC20(targetAsset).forceApprove(targetVault, amount);
    }
}
