// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {EulerTestBase, console2} from "./EulerTestBase.t.sol";
import "euler-vault-kit/EVault/shared/types/Types.sol";
import {EVCUtil} from "ethereum-vault-connector/utils/EVCUtil.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {EulerCollateralVault, IERC20 as IER20_OZ} from "src/twyne/EulerCollateralVault.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {Errors} from "euler-vault-kit/EVault/shared/Errors.sol";
import {Errors as EVCErrors} from "ethereum-vault-connector/Errors.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";
import {CollateralVaultFactory, VaultType} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {MockSwapper} from "test/mocks/MockSwapper.sol";
import {MockChainlinkOracle} from "test/mocks/MockChainlinkOracle.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {ChainlinkOracle} from "euler-price-oracle/src/adapter/chainlink/ChainlinkOracle.sol";

contract EulerOperators is EulerTestBase {

    // function test_e_LeverageOperator_EulerFL() public noGasMetering {
    //     e_creditDeposit(eulerWETH);
    //     MockSwapper mockSwapper = new MockSwapper();
    //     vm.etch(eulerSwapper, address(mockSwapper).code);

    //     vm.startPrank(bob);
    //     EulerCollateralVault bob_collateral_vault = EulerCollateralVault(
    //         collateralVaultFactory.createCollateralVault({
    //             _vaultType: VaultType.EULER_V2,
    //             _asset: eulerWETH,
    //             _targetVault: eulerUSDC,
    //             _liqLTV: twyneLiqLTV,
    //             _targetAsset: address(0)
    //         })
    //     );

    //     evc.setAccountOperator(bob, address(leverageOperator_EulerFL), true);
    //     // Approve leverage operator to take user's collateral
    //     IERC20(eulerWETH).approve(address(leverageOperator_EulerFL), type(uint).max);
    //     IERC20(WETH).approve(address(leverageOperator_EulerFL), type(uint).max);
    //     vm.stopPrank();

    //     // Create collateral vault for user
    //     vm.startPrank(alice);
    //     EulerCollateralVault alice_collateral_vault = EulerCollateralVault(
    //         collateralVaultFactory.createCollateralVault({
    //             _vaultType: VaultType.EULER_V2,
    //             _asset: eulerWETH,
    //             _targetVault: eulerUSDC,
    //             _liqLTV: twyneLiqLTV,
    //             _targetAsset: address(0)
    //         })
    //     );

    //     // Approve leverage operator to take user's collateral
    //     IERC20(eulerWETH).approve(address(leverageOperator_EulerFL), type(uint).max);
    //     IERC20(WETH).approve(address(leverageOperator_EulerFL), type(uint).max);

    //     {
    //         uint userUnderlyingCollateralAmount = 1 ether; // User provides 1 WETH
    //         uint userCollateralAmount = 1 ether; // User provides 1 eulerWETH
    //         uint flashloanAmount = 20000 * 1e6; // Flashloan 20,000 USDC
    //         uint minAmountOutWETH = 20 ether; // Expect at least 20 WETH from swap
    //         uint deadline = block.timestamp + 10; // deadline of the swap quote

    //         // Prepare swap data for the swapper
    //         deal(WETH, eulerSwapper, minAmountOutWETH + 10);
    //         bytes memory swapData = abi.encodeCall(MockSwapper.swap, (USDC, WETH, flashloanAmount, minAmountOutWETH, eulerWETH));
    //         bytes[] memory multicallData = new bytes[](1);
    //         multicallData[0] = swapData;

    //         bytes memory callbackData = abi.encode(minAmountOutWETH, deadline, multicallData);
    //         vm.expectRevert(TwyneErrors.T_CallerNotBorrower.selector);
    //         leverageOperator_EulerFL.executeLeverage(
    //             address(bob_collateral_vault),
    //             userUnderlyingCollateralAmount,
    //             userCollateralAmount,
    //             flashloanAmount,
    //             callbackData
    //         );

    //         vm.expectRevert(EVCErrors.EVC_NotAuthorized.selector);
    //         leverageOperator_EulerFL.executeLeverage(
    //             address(alice_collateral_vault),
    //             userUnderlyingCollateralAmount,
    //             userCollateralAmount,
    //             flashloanAmount,
    //             callbackData
    //         );

    //         uint256 snapshot = vm.snapshotState();

    //         // Execute leverage through EVC batch with operator setup
    //         IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);

    //         // Item 0: Enable operator
    //         items[0] = IEVC.BatchItem({
    //             targetContract: address(evc),
    //             onBehalfOfAccount: address(0),
    //             value: 0,
    //             data: abi.encodeCall(evc.setAccountOperator, (alice, address(leverageOperator_EulerFL), true))
    //         });

    //         // Item 1: Execute leverage operation
    //         items[1] = IEVC.BatchItem({
    //             targetContract: address(leverageOperator_EulerFL),
    //             onBehalfOfAccount: alice,
    //             value: 0,
    //             data: abi.encodeCall(leverageOperator_EulerFL.executeLeverage, (
    //                 address(alice_collateral_vault),
    //                 userUnderlyingCollateralAmount,
    //                 userCollateralAmount,
    //                 flashloanAmount,
    //                 callbackData
    //             ))
    //         });

    //         // Item 2: Disable operator
    //         items[2] = IEVC.BatchItem({
    //             targetContract: address(evc),
    //             onBehalfOfAccount: address(0),
    //             value: 0,
    //             data: abi.encodeCall(evc.setAccountOperator, (alice, address(leverageOperator_EulerFL), false))
    //         });

    //         evc.batch(items);

    //         assertGt(alice_collateral_vault.totalAssetsDepositedOrReserved() - alice_collateral_vault.maxRelease(), userCollateralAmount + userUnderlyingCollateralAmount);
    //         assertEq(alice_collateral_vault.maxRepay(), flashloanAmount);

    //         // Verify that LeverageOperator_EulerFL has no remaining token balances
    //         assertEq(IERC20(eulerWETH).balanceOf(address(leverageOperator_EulerFL)), 0, "LeverageOperator_EulerFL should have 0 eulerWETH");
    //         assertEq(IERC20(eulerUSDC).balanceOf(address(leverageOperator_EulerFL)), 0, "LeverageOperator_EulerFL should have 0 eulerUSDC");
    //         assertEq(IERC20(WETH).balanceOf(address(leverageOperator_EulerFL)), 0, "LeverageOperator_EulerFL should have 0 WETH");
    //         assertEq(IERC20(USDC).balanceOf(address(leverageOperator_EulerFL)), 0, "LeverageOperator_EulerFL should have 0 USDC");

    //         // Restore state so we can test the direct call to executeLeverage
    //         vm.revertToState(snapshot);

    //         evc.setAccountOperator(alice, address(leverageOperator_EulerFL), true);
    //         // Execute leverage through the operator
    //         leverageOperator_EulerFL.executeLeverage(
    //             address(alice_collateral_vault),
    //             userUnderlyingCollateralAmount,
    //             userCollateralAmount,
    //             flashloanAmount,
    //             callbackData
    //         );

    //         assertGt(alice_collateral_vault.totalAssetsDepositedOrReserved() - alice_collateral_vault.maxRelease(), userCollateralAmount + userUnderlyingCollateralAmount);
    //         assertEq(alice_collateral_vault.maxRepay(), flashloanAmount);

    //         // Verify that LeverageOperator_EulerFL has no remaining token balances
    //         assertEq(IERC20(eulerWETH).balanceOf(address(leverageOperator_EulerFL)), 0, "LeverageOperator_EulerFL should have 0 eulerWETH");
    //         assertEq(IERC20(eulerUSDC).balanceOf(address(leverageOperator_EulerFL)), 0, "LeverageOperator_EulerFL should have 0 eulerUSDC");
    //         assertEq(IERC20(WETH).balanceOf(address(leverageOperator_EulerFL)), 0, "LeverageOperator_EulerFL should have 0 WETH");
    //         assertEq(IERC20(USDC).balanceOf(address(leverageOperator_EulerFL)), 0, "LeverageOperator_EulerFL should have 0 USDC");
    //     }

    //     // Test deleverage functionality
    //     vm.warp(block.timestamp + 1 days);

    //     // Update oracle to avoid stale price revert
    //     {
    //         address configuredWETH_USD_Oracle = oracleRouter.getConfiguredOracle(WETH, USD);
    //         address chainlinkFeed = ChainlinkOracle(configuredWETH_USD_Oracle).feed();
    //         MockChainlinkOracle mockChainlink = new MockChainlinkOracle(WETH, USD, chainlinkFeed, 61 seconds);
    //         vm.etch(configuredWETH_USD_Oracle, address(mockChainlink).code);

    //         address configuredUSDC_USD_Oracle = oracleRouter.getConfiguredOracle(USDC, USD);
    //         chainlinkFeed = ChainlinkOracle(configuredUSDC_USD_Oracle).feed();
    //         mockChainlink = new MockChainlinkOracle(USDC, USD, chainlinkFeed, 61 seconds);
    //         vm.etch(configuredUSDC_USD_Oracle, address(mockChainlink).code);
    //     }

    //     // Calculate deleverage amounts based on current position
    //     uint borrowerCollateral = alice_collateral_vault.totalAssetsDepositedOrReserved() - alice_collateral_vault.maxRelease();
    //     uint maxDebt = alice_collateral_vault.maxRepay() / 2;
    //     uint withdrawCollateralAmount = borrowerCollateral / 2;
    //     uint deleverageFlashloanAmount = withdrawCollateralAmount + 1;

    //     deal(USDC, eulerSwapper, maxDebt + 11);

    //     // Prepare deleverage swap data
    //     bytes memory deleverageSwapData = abi.encodeCall(MockSwapper.swap, (WETH, USDC, deleverageFlashloanAmount, maxDebt + 1, address(deleverageOperator_EulerFL)));
    //     bytes[] memory deleverageMulticallData = new bytes[](1);
    //     deleverageMulticallData[0] = deleverageSwapData;

    //     IERC20 targetAsset = IERC20(alice_collateral_vault.targetAsset());
    //     uint aliceTargetAssetBal = targetAsset.balanceOf(alice);
    //     IERC20 underlyingCollateralAsset = IERC20(IEVault(alice_collateral_vault.asset()).asset());
    //     uint aliceUnderlyingCollateralBal = underlyingCollateralAsset.balanceOf(alice);

    //     // Test unauthorized deleverage attempts
    //     vm.startPrank(bob);
    //     vm.expectRevert(TwyneErrors.T_CallerNotBorrower.selector);
    //     deleverageOperator_EulerFL.executeDeleverage(
    //         address(alice_collateral_vault),
    //         deleverageFlashloanAmount,
    //         maxDebt,
    //         withdrawCollateralAmount,
    //         deleverageMulticallData
    //     );
    //     vm.stopPrank();

    //     vm.startPrank(alice);
    //     // Test deleverage without operator permission
    //     vm.expectRevert(EVCErrors.EVC_NotAuthorized.selector);
    //     deleverageOperator_EulerFL.executeDeleverage(
    //         address(alice_collateral_vault),
    //         deleverageFlashloanAmount,
    //         maxDebt,
    //         withdrawCollateralAmount,
    //         deleverageMulticallData
    //     );

    //     // Enable operator and execute deleverage
    //     evc.setAccountOperator(alice, address(deleverageOperator_EulerFL), true);
    //     deleverageOperator_EulerFL.executeDeleverage(
    //         address(alice_collateral_vault),
    //         deleverageFlashloanAmount,
    //         maxDebt,
    //         withdrawCollateralAmount,
    //         deleverageMulticallData
    //     );
    //     evc.setAccountOperator(alice, address(deleverageOperator_EulerFL), false);

    //     assertLe(IEVault(eulerUSDC).debtOf(address(alice_collateral_vault)), maxDebt, "Debt not fully repaid");
    //     assertEq(alice_collateral_vault.totalAssetsDepositedOrReserved() - alice_collateral_vault.maxRelease(), borrowerCollateral / 2 + 1, "Collateral not fully withdrawn");

    //     assertEq(targetAsset.balanceOf(alice), aliceTargetAssetBal);
    //     assertGt(underlyingCollateralAsset.balanceOf(alice), aliceUnderlyingCollateralBal, "alice collateral balance increases");

    //     // Check deleverageOperator_EulerFL has no remaining balances
    //     assertEq(targetAsset.balanceOf(address(deleverageOperator_EulerFL)), 0, "DeleverageOperator_EulerFL has remaining WETH");
    //     assertEq(underlyingCollateralAsset.balanceOf(address(deleverageOperator_EulerFL)), 0, "DeleverageOperator_EulerFL has remaining USDC");

    //     vm.stopPrank();
    // }
}