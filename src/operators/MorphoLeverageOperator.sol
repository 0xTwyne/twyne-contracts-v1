// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeERC20Lib, IERC20 as IERC20_Euler} from "euler-vault-kit/EVault/shared/lib/SafeERC20Lib.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {MorphoCollateralVault} from "src/twyne/MorphoCollateralVault.sol";
import {CollateralVaultBase} from "src/twyne/CollateralVaultBase.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {IMorpho, MarketParams} from "morpho/interfaces/IMorpho.sol";
import {IErrors} from "src/interfaces/IErrors.sol";
import {IEvents} from "src/interfaces/IEvents.sol";
import {ReentrancyGuardTransient} from "openzeppelin-contracts/utils/ReentrancyGuardTransient.sol";
import {EVCUtil} from "ethereum-vault-connector/utils/EVCUtil.sol";

interface ISwapper {
    function multicall(bytes[] memory calls) external;
}

/// @title MorphoLeverageOperator
/// @notice Operator contract for executing 1-click leverage operations on MorphoCollateralVaults
/// @dev Uses Morpho flashloans to enable atomic leverage operations.
/// @dev Flow: flashloan loan token → swap to collateral → take user collateral → deposit to vault via skim → borrow to repay flashloan
contract MorphoLeverageOperator is ReentrancyGuardTransient, EVCUtil, IErrors, IEvents {
    using SafeERC20 for IERC20;

    address public immutable SWAPPER;
    IMorpho public immutable MORPHO;
    CollateralVaultFactory public immutable COLLATERAL_VAULT_FACTORY;
    address public immutable permit2;

    constructor(
        address _evc,
        address _swapper,
        address _morpho,
        address _collateralVaultFactory,
        address _permit2
    ) EVCUtil(_evc) {
        SWAPPER = _swapper;
        MORPHO = IMorpho(_morpho);
        COLLATERAL_VAULT_FACTORY = CollateralVaultFactory(_collateralVaultFactory);
        permit2 = _permit2;
    }

    /// @notice Execute a leverage operation on a MorphoCollateralVault
    /// @dev This function executes the following steps:
    /// 1. Takes loan token (WETH) flashloan from Morpho
    /// 2. Swaps loan token to collateral token via Swapper multicall
    /// 3. Verifies swap output against minAmountOut and deadline
    /// 4. Takes user's collateral (WSTETH) after the swap verification
    /// 5. Transfers all collateral to the vault and calls skim + borrow (flashloan amount minus any loan tokens returned by the swap route) via EVC batch
    /// 6. Repays the flashloan
    /// @param collateralVault Address of the user's MorphoCollateralVault
    /// @param userCollateralAmount Amount of collateral token the user is providing (0 if none)
    /// @param flashloanAmount Amount of loan token to flashloan
    /// @param minAmountOut Minimum amount of collateral token expected from swap
    /// @param deadline Deadline timestamp for the swap verification
    /// @param swapData Encoded swap instructions for the swapper
    function executeLeverage(
        address collateralVault,
        uint userCollateralAmount,
        uint flashloanAmount,
        uint minAmountOut,
        uint deadline,
        bytes[] calldata swapData
    ) external nonReentrant {
        address msgSender = _msgSender();

        require(COLLATERAL_VAULT_FACTORY.isCollateralVault(collateralVault), T_InvalidCollateralVault());
        require(MorphoCollateralVault(collateralVault).borrower() == msgSender, T_CallerNotBorrower());

        MarketParams memory mp = MorphoCollateralVault(collateralVault).marketParams();

        MORPHO.flashLoan(
            mp.loanToken,
            flashloanAmount,
            abi.encode(
                msgSender,
                collateralVault,
                mp.loanToken,
                mp.collateralToken,
                userCollateralAmount,
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
            address collateralVault,
            address loanToken,
            address collateralToken,
            uint userCollateralAmount,
            uint minAmountOut,
            uint deadline,
            bytes[] memory swapData
        ) = abi.decode(data, (address, address, address, address, uint, uint, uint, bytes[]));

        // Step 1: Transfer flashloaned loan token to swapper
        IERC20(loanToken).safeTransfer(SWAPPER, amount);

        // Step 2: Execute swap loan token -> collateral token through multicall
        ISwapper(SWAPPER).multicall(swapData);

        // Step 3: Loan tokens the route returned to this contract (e.g. an exact-output
        // route sweeping its unconsumed input back). Only the consumed part needs to be
        // borrowed; the returned part settles the flashloan repayment directly.
        uint borrowAmount = amount - Math.min(amount, IERC20(loanToken).balanceOf(address(this)));

        // Step 4: Verify swap output
        uint collateralBalance = IERC20(collateralToken).balanceOf(address(this));
        require(collateralBalance >= minAmountOut, T_SlippageCheckFailed());
        require(block.timestamp <= deadline, T_DeadlineExpired());

        // Step 5: Collect user's collateral contribution
        if (userCollateralAmount > 0) {
            SafeERC20Lib.safeTransferFrom(IERC20_Euler(collateralToken), user, address(this), userCollateralAmount, permit2);
            collateralBalance += userCollateralAmount;
        }

        // Step 6: Transfer all collateral to the vault
        IERC20(collateralToken).safeTransfer(collateralVault, collateralBalance);

        // Step 7: EVC batch: skim (registers + supplies collateral to Morpho) + borrow
        {
            IEVC.BatchItem[] memory items = new IEVC.BatchItem[](Math.ternary(borrowAmount > 0, 2, 1));

            items[0] = IEVC.BatchItem({
                targetContract: collateralVault,
                onBehalfOfAccount: user,
                value: 0,
                data: abi.encodeCall(CollateralVaultBase.skim, ())
            });

            if (borrowAmount > 0) {
                items[1] = IEVC.BatchItem({
                    targetContract: collateralVault,
                    onBehalfOfAccount: user,
                    value: 0,
                    data: abi.encodeCall(CollateralVaultBase.borrow, (borrowAmount, address(this)))
                });
            }

            IEVC(evc).batch(items);
        }

        // Step 8: Approve Morpho to take repayment
        IERC20(loanToken).forceApprove(address(MORPHO), amount);
    }
}
