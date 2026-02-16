// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AaveTestBase, console2} from "./AaveTestBase.t.sol";
import {AaveV3CollateralVault, IAaveV3ATokenWrapper} from "src/twyne/AaveV3CollateralVault.sol";
import {IAaveV3ATokenWrapper} from "src/interfaces/IAaveV3ATokenWrapper.sol";
import {IPool as IAaveV3Pool} from "aave-v3/interfaces/IPool.sol";
import {IAToken as IAaveV3AToken} from "aave-v3/interfaces/IAToken.sol";
import {IVariableDebtToken as IAaveV3DebtToken} from "aave-v3/interfaces/IVariableDebtToken.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {MockSwapper} from "test/mocks/MockSwapper.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";
import {Errors as EVCErrors} from "ethereum-vault-connector/Errors.sol";
import {VaultType} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {SafeERC20Lib} from "euler-vault-kit/EVault/shared/lib/SafeERC20Lib.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Permit2ECDSASigner} from "euler-vault-kit/../test/mocks/Permit2ECDSASigner.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

interface IMorpho {
    function flashLoan(address token, uint assets, bytes calldata data) external;
}

contract AaveOperatorsTest is AaveTestBase {

    function setUp() public override {
        super.setUp();
    }

    // Test leverage + deleverage operators - complete end-to-end flow
    function test_AaveV3LeverageAndDeleverageOperators_Success() public noGasMetering {
        // Setup mock swapper like Euler tests
        MockSwapper mockSwapper = new MockSwapper();
        vm.etch(eulerSwapper, address(mockSwapper).code);

        // Create collateral vault (includes credit deposit automatically)
        aave_createCollateralVault(address(aWETHWrapper), 9100);

        vm.startPrank(alice);

        // === LEVERAGE PHASE ===

        // Setup leverage parameters
        uint userUnderlyingCollateralAmount = 1 ether; // User provides 1 WETH
        uint userCollateralAmount = 0; // No direct aToken provision
        uint flashloanAmount = 1000e6; // Flashloan 1000 USDC
        uint minAmountOutWETH = 0.9 ether; // Expect at least 0.9 WETH from swap
        uint deadline = block.timestamp + 1000;

        // Deal tokens and approvals
        deal(WETH, alice, userUnderlyingCollateralAmount * 2);
        IERC20(WETH).approve(address(alice_aave_vault), type(uint256).max);
        IERC20(WETH).approve(address(aaveV3LeverageOperator), type(uint256).max);

        // Make initial deposit to the vault
        alice_aave_vault.depositUnderlying(userUnderlyingCollateralAmount);
        uint initialCollateral = alice_aave_vault.totalAssetsDepositedOrReserved() - alice_aave_vault.maxRelease();
        assertGt(initialCollateral, 0, "Initial deposit should create collateral");

        // Deal WETH to swapper for successful swap simulation
        deal(WETH, eulerSwapper, minAmountOutWETH + 1 ether);

        // Prepare leverage swap data (USDC -> WETH)
        bytes memory leverageSwapData = abi.encodeCall(
            MockSwapper.swap,
            (USDC, WETH, flashloanAmount, minAmountOutWETH, address(aaveV3LeverageOperator))
        );
        bytes[] memory leverageMulticallData = new bytes[](1);
        leverageMulticallData[0] = leverageSwapData;

        // Enable leverage operator and execute
        evc.setAccountOperator(alice, address(aaveV3LeverageOperator), true);
        aaveV3LeverageOperator.executeLeverage(
            address(alice_aave_vault),
            userUnderlyingCollateralAmount,
            userCollateralAmount,
            flashloanAmount,
            minAmountOutWETH,
            deadline,
            leverageMulticallData
        );

        // Verify leverage success
        uint leveragedCollateral = alice_aave_vault.totalAssetsDepositedOrReserved() - alice_aave_vault.maxRelease();
        assertGt(leveragedCollateral, initialCollateral, "Leverage should increase collateral");
        assertApproxEqAbs(alice_aave_vault.maxRepay(), flashloanAmount, 1, "Vault should have debt from leverage");

        // === DELEVERAGE PHASE ===

        // Calculate deleverage amounts based on current leveraged position (following Euler pattern)
        uint currentDebt = alice_aave_vault.maxRepay();
        uint currentCollateral = alice_aave_vault.totalAssetsDepositedOrReserved() - alice_aave_vault.maxRelease();
        uint maxDebt = currentDebt / 2; // Target: reduce debt by half
        uint withdrawCollateralAmount = currentCollateral / 4; // Withdraw 25% of collateral
        uint deleverageFlashloanAmount = withdrawCollateralAmount + 1; // Flashloan underlying collateral (WETH) + buffer

        // Deal USDC to swapper for deleverage swap simulation
        deal(USDC, eulerSwapper, maxDebt + 11);

        bytes memory deleverageSwapData = abi.encodeCall(
            MockSwapper.swap,
            (WETH, USDC, deleverageFlashloanAmount, maxDebt + 1, address(aaveV3DeleverageOperator))
        );
        bytes[] memory deleverageMulticallData = new bytes[](1);
        deleverageMulticallData[0] = deleverageSwapData;

        evc.setAccountOperator(alice, address(aaveV3DeleverageOperator), true);
        aaveV3DeleverageOperator.executeDeleverage(
            address(alice_aave_vault),
            deleverageFlashloanAmount,
            maxDebt + 50e6,
            withdrawCollateralAmount,
            deleverageMulticallData
        );

        // Verify deleverage success
        assertLt(alice_aave_vault.totalAssetsDepositedOrReserved() - alice_aave_vault.maxRelease(), currentCollateral, "Deleverage should reduce collateral");
        assertLe(alice_aave_vault.maxRepay(), maxDebt, "Deleverage should reduce debt");

        vm.stopPrank();
    }

    // Test leverage operator - unauthorized access
    function test_AaveV3LeverageOperator_Unauthorized() public {
        vm.startPrank(alice);
        alice_aave_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _asset: address(aWETHWrapper),
                _targetVault: aavePool,
                _liqLTV: 9100,
                _targetAsset: USDC
            })
        );
        vm.stopPrank();

        bytes[] memory swapData = new bytes[](0);

        // Bob tries to leverage Alice's vault
        vm.startPrank(bob);
        vm.expectRevert(TwyneErrors.T_CallerNotBorrower.selector);
        aaveV3LeverageOperator.executeLeverage(
            address(alice_aave_vault),
            0,
            0,
            0,
            0,
            block.timestamp,
            swapData
        );
        vm.stopPrank();
    }

    // Test teleport operator - migrate existing Aave position to CollateralVault
    function test_AaveV3TeleportOperator_Success() public noGasMetering {
        // Setup credit deposit for borrowing liquidity
        aave_creditDeposit(address(aWETHWrapper));

        // Step 1: Create an existing Aave position for alice (following Euler pattern)
        vm.startPrank(alice);

        // Setup initial position parameters (following Euler pattern)
        uint collateralAmount = 10 ether; // 10 WETH worth of aWETH collateral
        uint borrowAmount = 5000e6; // 5000 USDC debt

        // Create direct Aave position (like Euler's direct position before teleport)
        deal(WETH, alice, collateralAmount);
        IERC20(WETH).approve(aavePool, collateralAmount);
        IAaveV3Pool(aavePool).supply(WETH, collateralAmount, alice, 0);
        IAaveV3Pool(aavePool).borrow(USDC, borrowAmount, 2, 0, alice); // Variable rate debt

        // Verify the direct Aave position exists
        IAaveV3AToken aWETH = IAaveV3AToken(aWETHWrapper.aToken());
        assertApproxEqAbs(aWETH.balanceOf(alice), collateralAmount, 5, "User should have aWETH collateral");
        assertApproxEqAbs(IERC20(address(aDebtUSDC)).balanceOf(alice), borrowAmount, 5, "User should have USDC debt");

        // Step 2: Create collateral vault for teleport migration
        alice_aave_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _asset: address(aWETHWrapper),
                _targetVault: aavePool,
                _liqLTV: 9100,
                _targetAsset: USDC
            })
        );

        // Get actual balances for teleport (may differ slightly due to interest)
        uint actualATokenBalance = aWETH.balanceOf(alice);
        uint actualDebtBalance = IERC20(address(aDebtUSDC)).balanceOf(alice);

        // Step 3: Setup approvals for teleport operator
        IERC20(address(aWETH)).approve(address(aaveV3TeleportOperator), actualATokenBalance);
        evc.setAccountOperator(alice, address(aaveV3TeleportOperator), true);

        // Step 4: Execute teleport to migrate the position
        aaveV3TeleportOperator.executeTeleport(
            address(alice_aave_vault),
            actualATokenBalance,
            actualDebtBalance
        );

        // Step 5: Verify teleport success - position migrated from direct Aave to CollateralVault
        assertEq(aWETH.balanceOf(alice), 0, "User's direct aWETH should be transferred");
        assertEq(IERC20(address(aDebtUSDC)).balanceOf(alice), 0, "User's direct debt should be repaid");

        // Verify the position is now in the CollateralVault
        uint vaultCollateral = alice_aave_vault.totalAssetsDepositedOrReserved() - alice_aave_vault.maxRelease();
        assertApproxEqAbs(vaultCollateral, IAaveV3ATokenWrapper(alice_aave_vault.asset()).previewWithdraw(actualATokenBalance), 1, "Vault should have received collateral from teleport");
        assertApproxEqAbs(alice_aave_vault.maxRepay(), actualDebtBalance, 1, "Vault should have migrated debt");

        vm.stopPrank();
    }

    // Test teleport with excess debtAmount - should cap to actual debt
    function test_AaveV3TeleportOperator_ExcessDebtAmount() public noGasMetering {
        // Setup credit deposit for borrowing liquidity
        aave_creditDeposit(address(aWETHWrapper));

        // Step 1: Create an existing Aave position for alice
        vm.startPrank(alice);

        uint collateralAmount = 10 ether;
        uint borrowAmount = 5000e6;

        deal(WETH, alice, collateralAmount);
        IERC20(WETH).approve(aavePool, collateralAmount);
        IAaveV3Pool(aavePool).supply(WETH, collateralAmount, alice, 0);
        IAaveV3Pool(aavePool).borrow(USDC, borrowAmount, 2, 0, alice);

        IAaveV3AToken aWETH = IAaveV3AToken(aWETHWrapper.aToken());

        // Step 2: Create collateral vault for teleport migration
        alice_aave_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _asset: address(aWETHWrapper),
                _targetVault: aavePool,
                _liqLTV: 9100,
                _targetAsset: USDC
            })
        );

        uint actualATokenBalance = aWETH.balanceOf(alice);
        uint actualDebtBalance = IERC20(address(aDebtUSDC)).balanceOf(alice);

        // Step 3: Setup approvals for teleport operator
        IERC20(address(aWETH)).approve(address(aaveV3TeleportOperator), actualATokenBalance);
        evc.setAccountOperator(alice, address(aaveV3TeleportOperator), true);

        // Step 4: Execute teleport with debtAmount + 10 (excess amount)
        aaveV3TeleportOperator.executeTeleport(
            address(alice_aave_vault),
            actualATokenBalance,
            actualDebtBalance + 10  // Pass excess debt amount
        );

        // Step 5: Verify teleport success - no leftover for user or operator
        assertEq(aWETH.balanceOf(alice), 0, "User's direct aWETH should be transferred");
        assertEq(IERC20(address(aDebtUSDC)).balanceOf(alice), 0, "User's direct debt should be fully repaid");
        assertEq(IERC20(USDC).balanceOf(address(aaveV3TeleportOperator)), 0, "Operator should have no leftover USDC");
        assertEq(IERC20(address(aDebtUSDC)).balanceOf(address(aaveV3TeleportOperator)), 0, "Operator should have no debt token");

        // Verify the position is now in the CollateralVault
        uint vaultCollateral = alice_aave_vault.totalAssetsDepositedOrReserved() - alice_aave_vault.maxRelease();
        assertApproxEqAbs(vaultCollateral, IAaveV3ATokenWrapper(alice_aave_vault.asset()).previewWithdraw(actualATokenBalance), 1, "Vault should have received collateral from teleport");
        assertApproxEqAbs(alice_aave_vault.maxRepay(), actualDebtBalance, 1, "Vault should have migrated debt");

        vm.stopPrank();
    }

    // Test teleport operator - unauthorized access
    function test_AaveV3TeleportOperator_Unauthorized() public {
        // Setup: Alice creates a collateral vault
        vm.startPrank(alice);
        alice_aave_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _asset: address(aWETHWrapper),
                _targetVault: aavePool,
                _liqLTV: 9100,
                _targetAsset: USDC
            })
        );
        vm.stopPrank();

        // Bob tries to teleport to Alice's vault
        vm.startPrank(bob);
        vm.expectRevert(TwyneErrors.T_CallerNotBorrower.selector);
        aaveV3TeleportOperator.executeTeleport(
            address(alice_aave_vault),
            1 ether,
            1000e6
        );
        vm.stopPrank();
    }

    // Test flashloan callback access control
    function test_AaveV3Operators_CallbackAccessControl() public {
        // Try to call leverage operator callback directly
        vm.expectRevert(TwyneErrors.T_CallerNotMorpho.selector);
        aaveV3LeverageOperator.onMorphoFlashLoan(1000e6, "");

        // Try to call deleverage operator callback directly
        vm.expectRevert(TwyneErrors.T_CallerNotMorpho.selector);
        aaveV3DeleverageOperator.onMorphoFlashLoan(1 ether, "");

        // Try to call teleport operator callback directly
        vm.expectRevert(TwyneErrors.T_CallerNotMorpho.selector);
        aaveV3TeleportOperator.onMorphoFlashLoan(1000e6, "");
    }

}