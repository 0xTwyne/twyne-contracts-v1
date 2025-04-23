// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import {OverCollateralizedTestBase, console2, BridgeHookTarget} from "./OverCollateralizedTestBase.t.sol";
import "euler-vault-kit/EVault/shared/types/Types.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {EulerCollateralVault} from "src/twyne/EulerCollateralVault.sol";
import {Errors} from "euler-vault-kit/EVault/shared/Errors.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";

interface IWETH is IERC20 {
    receive() external payable;
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

contract EulerLiquidationTest is OverCollateralizedTestBase {
    uint256 BORROW_ETH_AMOUNT;

    function setUp() public override {
        super.setUp();
    }

    function test_e_preLiquidationSetup() public {
        // Bob deposits into eeWETH_intermediate_vault to earn boosted yield
        vm.startPrank(bob);
        IERC20(eulerWETH).approve(address(eeWETH_intermediate_vault), type(uint256).max);
        eeWETH_intermediate_vault.deposit(CREDIT_LP_AMOUNT, bob);
        vm.stopPrank();

        // repeat but for Collateral non-EVK vault
        vm.startPrank(alice);
        alice_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _asset: eulerWETH,
                _targetVault: eulerUSDC,
                _liqLTV: twyneLiqLTV
            })
        );

        vm.label(address(alice_collateral_vault), "alice_collateral_vault");

        // Alice deposit the eulerWETH token into the collateral vault
        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint256).max);

        BORROW_ETH_AMOUNT = getReservedAssets(COLLATERAL_AMOUNT, 0, alice_collateral_vault);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        // reserve assets from intermediate vault
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.deposit, (COLLATERAL_AMOUNT))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.reserve, BORROW_ETH_AMOUNT)
        });

        evc.batch(items);

        vm.stopPrank();

        // Alice borrows from the target vault
        vm.startPrank(alice);
        uint256 aliceBalanceBefore = IERC20(USDC).balanceOf(alice);
        alice_collateral_vault.borrow(BORROW_USD_AMOUNT, alice);
        assertEq(IERC20(USDC).balanceOf(alice) - aliceBalanceBefore, BORROW_USD_AMOUNT, "Borrower not holding correct target assets");
        vm.stopPrank();
    }

    function test_e_postSetupChecks() public noGasMetering {
        test_e_preLiquidationSetup();

        // Confirm balances are as expected
        assertEq(alice_collateral_vault.totalAssetsDepositedOrReserved() - alice_collateral_vault.maxRelease(), COLLATERAL_AMOUNT);
        assertEq(alice_collateral_vault.balanceOf(address(alice_collateral_vault)), COLLATERAL_AMOUNT);

        // borrower holds Twyne/EVK debt
        assertEq(
            alice_collateral_vault.maxRelease(),
            BORROW_ETH_AMOUNT,
            "EVK debt not correct amount"
        );
        assertEq(eeWETH_intermediate_vault.totalAssets(), CREDIT_LP_AMOUNT);

        // collateral vault holds borrowed eulerWETH from intermediate vault
        assertApproxEqRel(
            IERC20(eulerWETH).balanceOf(address(alice_collateral_vault)),
            COLLATERAL_AMOUNT + BORROW_ETH_AMOUNT,
            1e5,
            "Collateral vault not holding correct eulerWETH balance"
        );
        // intermediate vault holds credit LP's eulerWETH minus the borrowed amount
        assertApproxEqRel(
            IERC20(eulerWETH).balanceOf(address(eeWETH_intermediate_vault)),
            CREDIT_LP_AMOUNT - BORROW_ETH_AMOUNT,
            1e5,
            "Intermediate vault not holding correct eulerWETH balance"
        );
    }

    function test_e_setupLiquidation() public noGasMetering {
        test_e_preLiquidationSetup();

        (uint256 collateralValue, uint256 liabilityValue) = eeWETH_intermediate_vault.accountLiquidity(address(alice_collateral_vault), true);

        uint256 eulerWETH_quote = oracleRouter.getQuote(1e28, eulerWETH, USD);
        assertApproxEqRel(
            collateralValue,
            COLLATERAL_AMOUNT * eulerWETH_quote/1e28,
            1e5,
            "Wrong intermediate vault collateralValue before time warp"
        ); // this is deposited collateral * liquidation LTV
        assertApproxEqRel(
            liabilityValue,
            BORROW_ETH_AMOUNT * eulerWETH_quote/1e28,
            1e5,
            "Wrong intermediate vault liabilityValue before time warp"
        );

        // console2.log("collateralvalue before", collateralValue);
        // console2.log("liabilityValue before", liabilityValue);

        // Change price to meet liquidation criteria
        mockOracle.setPrice(eulerWETH, USD, uint256(WETH_USD_PRICE_INITIAL * 7 / 10));
        mockOracle.setPrice(USDC, WETH, (1e18 * WETH_USD_PRICE_INITIAL * 7) / (USDC_USD_PRICE_INITIAL * 10));

        vm.startPrank(twyneVaultManager.owner());
        twyneVaultManager.doCall(address(twyneVaultManager.oracleRouter()), 0, abi.encodeCall(EulerRouter.govSetConfig, (USDC, WETH, address(mockOracle))));
        vm.stopPrank();

        // Verify debt to intermediate vault increased
        (collateralValue, liabilityValue) = eeWETH_intermediate_vault.accountLiquidity(address(alice_collateral_vault), true);
        // console2.log("collateralvalue after", collateralValue);
        // console2.log("liabilityValue after", liabilityValue);
        assertGt(liabilityValue, BORROW_ETH_AMOUNT, "alice debt to intermediate vault did not increase");

        // // Verify that debt to Aave increased and now the health factor is below the 1.02 liquidation threshold
        // (, , , , , healthFactor) = IAavePool(aavePool).getUserAccountData(address(alice_collateral_vault));
        // assertLt(healthFactor, alice_collateral_vault.twyneEVKSafetyFactor(), "Alice borrow is still healthy after time warp");

        // confirm vault can be liquidated now that there is more collateral
        assertTrue(alice_collateral_vault.canLiquidate(), "Vault should be unhealthy but it cannot be liquidated!");

        vm.startPrank(liquidator);
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint256).max);
        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint256).max);

        // engn33r did not expect that the liquidator has to call enableCollateral() and enableController() for the EVK vault being liquidated
        // but in hindsight this makes sense because the liquidator is taking over the borrower's position
        // so the liquidator should call the same functions that the borrower does before borrowing
        // BUT these calls aren't necessary for the liquidator to call now that the Collateral vault does them (because in design6, Collateral vault does all the borrowing from the intermediate vault)
        // evc.enableCollateral(liquidator, address(alice_collateral_vault));
        // evc.enableController(liquidator, address(eeWETH_intermediate_vault));
        vm.stopPrank();
    }

    function test_e_handleCompleteExternalLiquidation() public noGasMetering {
        test_e_setupLiquidation();
        mockOracle.setPrice(eulerWETH, USD, uint256(WETH_USD_PRICE_INITIAL * 3 / 10));
        vm.warp(block.timestamp + 1);

        (uint maxrepay, ) = IEVault(eulerUSDC).checkLiquidation(address(this), address(alice_collateral_vault), eulerWETH);

        assertGt(maxrepay, 0);

        // Ensure liquidator has enough eulerWETH to be a valid liquidator
        dealEToken(eulerWETH, liquidator, 100 ether);

        vm.startPrank(liquidator);

        IEVC(IEVault(eulerWETH).EVC()).enableCollateral(liquidator, address(eulerWETH));
        IEVC(IEVault(eulerUSDC).EVC()).enableController(liquidator, address(eulerUSDC));

        assertFalse(alice_collateral_vault.isExternallyLiquidated());
        // liquidate alice_collateral_vault via eulerUSDC EVault
        assertGt(alice_collateral_vault.maxRepay(), 0);

        // This decreases the entire debt and collateral amount to 0.
        // Hence, this test only tests a subset of possibilities.
        IEVault(eulerUSDC).liquidate({
            violator: address(alice_collateral_vault),
            collateral: eulerWETH,
            repayAssets: type(uint).max,
            minYieldBalance: 0
        });
        vm.stopPrank();

        assertTrue(alice_collateral_vault.isExternallyLiquidated());

        // Since the external liquidation reduceed the debt and its collateral amount to 0,
        // there is no collateral that is collateralizing the intermediate vault debt.
        assertEq(alice_collateral_vault.balanceOf(address(alice_collateral_vault)), 0);

        // External liquidation sets debt to 0 and leaves some collateral
        assertEq(IEVault(eulerUSDC).debtOf(address(alice_collateral_vault)), 0);
        assertEq(IERC20(eulerWETH).balanceOf(address(alice_collateral_vault)), 0);
        assertGt(alice_collateral_vault.maxRelease(), 0);

        // Check that you can't do operations on collateral vault
        // after external liquidation.
        vm.startPrank(alice);

        vm.expectRevert(TwyneErrors.ExternallyLiquidated.selector);
        alice_collateral_vault.liquidate();

        vm.expectRevert(TwyneErrors.ExternallyLiquidated.selector);
        alice_collateral_vault.release(1);

        vm.expectRevert(TwyneErrors.ExternallyLiquidated.selector);
        alice_collateral_vault.reserve(1);

        vm.expectRevert(TwyneErrors.ExternallyLiquidated.selector);
        alice_collateral_vault.rebalance();

        vm.expectRevert(TwyneErrors.ExternallyLiquidated.selector);
        alice_collateral_vault.deposit(1);

        vm.expectRevert(TwyneErrors.ExternallyLiquidated.selector);
        alice_collateral_vault.depositUnderlying(1);

        vm.expectRevert(TwyneErrors.ExternallyLiquidated.selector);
        alice_collateral_vault.withdraw(1, alice);

        vm.expectRevert(TwyneErrors.ExternallyLiquidated.selector);
        alice_collateral_vault.redeemUnderlying(1, alice);
        vm.stopPrank();

        address newLiquidator = makeAddr("newLiquidator");
        vm.startPrank(newLiquidator);

        evc.enableController(newLiquidator, address(alice_collateral_vault.intermediateVault()));

        // Calling just handleExternalLiquidation should fail.
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            onBehalfOfAccount: newLiquidator,
            targetContract: address(alice_collateral_vault),
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.handleExternalLiquidation, ())
        });

        // Vault status check reverts since `_canLiquidate()` reverts.
        // `totalAssetsOrDepositedReserverd(0) - maxRelease()(>0)` reverts.
        vm.expectRevert();
        evc.batch(items);

        // Need to call liquidate() on intermediate vault after handleExternalLiquidation()
        IEVC.BatchItem[] memory items1 = new IEVC.BatchItem[](2);
        items1[0] = items[0];
        items1[1] = IEVC.BatchItem({
            onBehalfOfAccount: newLiquidator,
            targetContract: address(alice_collateral_vault.intermediateVault()),
            value: 0,
            data: abi.encodeCall(IEVault(eulerWETH).liquidate, (address(alice_collateral_vault), address(alice_collateral_vault), 0, 0))
        });

        evc.batch(items1);
        vm.stopPrank();

        assertEq(alice_collateral_vault.borrower(), address(0));
        assertEq(alice_collateral_vault.balanceOf(address(alice_collateral_vault)), 0);
        assertEq(alice_collateral_vault.maxRelease(), 0);
    }

    function test_e_handlePartialExternalLiquidation() public noGasMetering {
        test_e_setupLiquidation();
        vm.warp(block.timestamp + 1);

        (uint maxrepay, ) = IEVault(eulerUSDC).checkLiquidation(address(this), address(alice_collateral_vault), eulerWETH);

        assertGt(maxrepay, 0);

        // Ensure liquidator has enough eulerWETH to be a valid liquidator
        dealEToken(eulerWETH, liquidator, 100 ether);

        vm.startPrank(liquidator);

        IEVC(IEVault(eulerWETH).EVC()).enableCollateral(liquidator, address(eulerWETH));
        IEVC(IEVault(eulerUSDC).EVC()).enableController(liquidator, address(eulerUSDC));

        assertFalse(alice_collateral_vault.isExternallyLiquidated());
        // liquidate alice_collateral_vault via eulerUSDC EVault
        assertGt(alice_collateral_vault.maxRepay(), 0);

        // Test for non-zero debt and collateral amount after external liquidation.
        IEVault(eulerUSDC).liquidate({
            violator: address(alice_collateral_vault),
            collateral: eulerWETH,
            repayAssets: maxrepay/2,
            minYieldBalance: 0
        });
        assertTrue(alice_collateral_vault.isExternallyLiquidated());
        assertGt(alice_collateral_vault.balanceOf(address(alice_collateral_vault)), 0);
        assertGt(IEVault(eulerUSDC).debtOf(address(alice_collateral_vault)), 0);
        assertGt(IERC20(eulerWETH).balanceOf(address(alice_collateral_vault)), 0);

        vm.stopPrank();

        // Check that you can't do operations on collateral vault
        // after external liquidation.
        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.ExternallyLiquidated.selector);
        alice_collateral_vault.withdraw(1, alice);
        vm.stopPrank();

        address newLiquidator = makeAddr("newLiquidator");

        // Deal USDC to newLiquidator
        deal(address(USDC), newLiquidator, 10e20);

        vm.startPrank(newLiquidator);

        evc.enableController(newLiquidator, address(alice_collateral_vault.intermediateVault()));
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint).max);
        assertEq(IEVault(eulerWETH).balanceOf(newLiquidator), 0);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            onBehalfOfAccount: newLiquidator,
            targetContract: address(alice_collateral_vault),
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.handleExternalLiquidation, ())
        });

        // This should pass without explicit liquidation call
        // since we it repays the entire debt to intermediate vault.
        evc.batch(items);
        vm.stopPrank();

        assertEq(alice_collateral_vault.borrower(), address(0), "borrower NEQ address(0)");
        assertEq(alice_collateral_vault.balanceOf(address(alice_collateral_vault)), 0, "balanceOf alice NEQ 0");
        assertEq(alice_collateral_vault.maxRelease(), 0, "maxRelease NEQ 0");
        // assertGt(IEVault(eulerWETH).balanceOf(newLiquidator), 0, "balanceOf newLiq NEQ 0"); // TODO uncomment this line by fixing the test
        assertLt(IERC20(USDC).balanceOf(newLiquidator), 10e20, "balanceOf NEQ 10e20");
    }

    // There are 3 cases where a liquidation can be triggered:
    // Case 1: Debt accumulation only from Euler triggers liquidation
    // Case 2: Debt accumulation only from internal intermediate vault borrow triggers liquidation
    // Case 3: Debt accumulation combined from BOTH Euler and internal intermediate vault borrow triggers liquidation (this should be the "normal" case for users)

    // passing tests to write
    // 1. liquidator who liquidates and doesn't make the position healthy can immediately get liquidated by someone else. Verify original borrower LTV and first liquidator LTV is zero
    // 2. liquidator who liquidates and makes the position healthy with some extra collateral cannot get liquidated by someone else (and has expected LTV). Verify original borrower LTV is zero
    // 3. liquidator who liquidates and makes the position healthy by repaying some debt cannot get liquidated by someone else (and has expected LTV). Verify original borrower LTV is zero
    // 4. liquidator who liquidates and makes the position healthy by repaying ALL debt ends up with LTV of 0 (no debt)
    // 5: liquidator who liquidates and makes the position healthy by repaying all debt ends up with LTV of 0 (no debt at all)
    // 6. liquidator who liquidates worthless collateral doesn't need to repay anything (what is the reasoning for adding code to this case? Maybe for memecoins?)
    // 7. test liquidation case when position is unhealthy on Euler (can test extreme bad debt case, with very low or zero collateral value)
    // 8. what happens if the Twyne EVK borrow becomes liquidatable before the Euler liquidation is triggered?
    //   NOTE: the above case cannot happen if intermediate vault liquidation LTV = 1
    // 9. test tokens with other decimals
    // 10. test bad debt socialization (or lack thereof)
    // 11. Test liquidation when governance changes LTV (this simulates a response to Euler parameters changing. Test LTV ramping if implemented)
    // 12. Test liquidation flow using a flashloan (relevant for liquidation bot repo)

    // failing tests to write
    // F1. liquidation reverts when borrower position is healthy
    // F2. if liquidator attempts to repay with more than maxRepay, liquidate call reverts
    // F3. liquidator who liquidates and makes the position healthy cannot be liquidated immediately
    // F3.1 liquidator who liquidates and doesn't handle the debt but tries to withdraw collateral should not be able to (subcase of above, no need to test)
    // F4. borrower who has LTV at the liquidation threshold cannot be liquidated (LTV must be below threshold)
    // F5. self-liquidation should revert
    // F6. if vault is not set up yet (i.e. no price oracle), liquidation should not be possible
    // F7. Test repaying aave twice in 1 block (or tx) to confirm this revert case need documenting
    // F8. Test that governance cannot set liquidation LTV below borrowing LTV on Collateral vault
    //
    // TODO Questions
    // if liquidator liquidates and position is not made healthy in the same block, should the liquidation revert?
    // How to handle bad debt - socialize it or not?
    // Do we want to set some cooloff like Euler, or does it not make sense?

    // Test 1: liquidator who liquidates and doesn't make the position healthy cannot liquidate.
    // Verify original borrower LTV and first liquidator LTV is zero
    function test_e_liquidate_without_making_healthy() public noGasMetering {
        test_e_setupLiquidation();

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_collateral_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.VaultStatusLiquidatable.selector);
        alice_collateral_vault.liquidate();
        vm.stopPrank();
    }

    // Test 2: liquidator who liquidates and makes the position healthy with some extra collateral cannot get liquidated by someone else (and has expected LTV). Verify original borrower LTV is zero
    function test_e_liquidate_make_healthy_more_collateral() public noGasMetering {
        test_e_setupLiquidation();

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_collateral_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(liquidator);

        // first, assume that the liquidator is already a Twyne user
        // This confirms that a user with an existing vault can ALSO liquidate other vaults
        EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _asset: eulerWETH,
                _targetVault: eulerUSDC,
                _liqLTV: twyneLiqLTV
            })
        );

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // repay debt in Aave
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.liquidate, ())
        });

        // and now add collateral to make position more healthy
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.deposit, (COLLATERAL_AMOUNT))
        });

        // Liquidated collateral vault needs to satisfy invariants
        vm.expectRevert(TwyneErrors.VaultHasNegativeExcessCredit.selector);
        evc.batch(items);

        IEVC.BatchItem[] memory newItems = new IEVC.BatchItem[](3);

        uint reserveAmount = getReservedAssets(
            COLLATERAL_AMOUNT + (alice_collateral_vault.totalAssetsDepositedOrReserved() - alice_collateral_vault.maxRelease()),
            0,
            alice_collateral_vault
        ) - alice_collateral_vault.maxRelease();

        newItems[0] = items[0];
        newItems[1] = items[1];
        newItems[2] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.reserve, (reserveAmount))
        });

        evc.batch(newItems);

        // confirm vault owner is liquidator
        assertEq(alice_collateral_vault.borrower(), liquidator, "Wrong collateral vault owner after liquidation");
        assertEq(collateralVaultFactory.getCollateralVaults(liquidator)[1], address(alice_collateral_vault));
        assertEq(collateralVaultFactory.getCollateralVaults(alice)[0], address(alice_collateral_vault));
        // confirm vault can NOT be liquidated now that there is more collateral
        bool canLiq = alice_collateral_vault.canLiquidate();
        assertFalse(canLiq, "Vault should be healthy but it can be liquidated!");
        // confirm collateral balance in vault is greater now than before
        assertEq(
            IERC20(eulerWETH).balanceOf(address(alice_collateral_vault)),
            2 * COLLATERAL_AMOUNT + BORROW_ETH_AMOUNT + reserveAmount,
            "Collateral vault did not receive more eulerWETH"
        );

        // This tests scenario F3
        canLiq = alice_collateral_vault.canLiquidate();
        assertFalse(canLiq, "Vault should be healthy but it can be liquidated!");

        vm.stopPrank();
    }

    // Test 3: liquidator who liquidates and makes the position healthy by repaying some debt cannot get liquidated by someone else (and has expected LTV). Verify original borrower LTV is zero
    function test_e_liquidate_make_healthy_reduce_debt() public noGasMetering {
        test_e_setupLiquidation();

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_collateral_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(liquidator);

        // Save Euler external debt amount
        uint256 previousEulerDebt = alice_collateral_vault.maxRepay();

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // repay debt in Aave
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.liquidate, ())
        });

        // and now add collateral to make position more healthy
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.repay, (BORROW_USD_AMOUNT/2))
        });

        evc.batch(items);
        // confirm vault owner is liquidator
        assertEq(alice_collateral_vault.borrower(), liquidator, "Wrong collateral vault owner after liquidation");
        // confirm vault can NOT be liquidated now that there is more collateral
        bool canLiq = alice_collateral_vault.canLiquidate();
        assertFalse(canLiq, "Vault should be healthy but it can be liquidated!");
        // confirm vault debt to Euler is lower than before
        uint256 latestEulerDebt = alice_collateral_vault.maxRepay();
        assertLt(latestEulerDebt, previousEulerDebt, "Euler current debt is wrong");

        // This tests scenario F3
        canLiq = alice_collateral_vault.canLiquidate();
        assertFalse(canLiq, "Vault should be healthy but it can be liquidated!");

        // intermediate vault debt is unchanged
        assertApproxEqRel(
            alice_collateral_vault.maxRelease(),
            BORROW_ETH_AMOUNT,
            1e15,
            "EVK debt not correct amount after liquidation"
        );

        vm.stopPrank();

        // alice can't withdraw from collateral vault now
        vm.startPrank(alice);
        vm.expectRevert();
        alice_collateral_vault.withdraw(1, alice);
        vm.expectRevert();
        alice_collateral_vault.withdraw(1, liquidator);
        vm.stopPrank();
    }

    // Test 4: liquidator who liquidates and makes the position healthy by repaying Aave debt ends up with LTV of 0 to Euler (no vUSDC debt)
    function test_e_liquidate_make_healthy_zero_euler_debt() public noGasMetering {
        test_e_setupLiquidation();
        // Verify all asset balances before liquidation process
        // Verify that Alice holds collateral vault shares and intermediate vault debt
        assertEq(
            alice_collateral_vault.balanceOf(address(alice_collateral_vault)),
            COLLATERAL_AMOUNT,
            "Alice has wrong collateral vault shares balance"
        );
        assertApproxEqRel(
            alice_collateral_vault.maxRelease(),
            BORROW_ETH_AMOUNT,
            1e5,
            "EVK debt not correct amount before liquidation"
        );
        uint256 eulerCurrentDebt = alice_collateral_vault.maxRepay();
        assertEq(eulerCurrentDebt, BORROW_USD_AMOUNT, "Euler current debt is wrong"); // original debt was BORROW_USD_AMOUNT
        // Verify that liquidator has no collateral vault shares and no intermediate vault debt before the liquidation
        assertEq(alice_collateral_vault.balanceOf(liquidator), 0, "Liquidator should have zero collateral vault shares 1");
        assertEq(eeWETH_intermediate_vault.debtOf(liquidator), 0, "Liquidator should have zero intermediate vault debt 1");

        // Verify that the internal borrow from the intermediate vault cannot be liquidated currently
        vm.startPrank(liquidator);
        // TODO why is the call below reverting due to liquidation cooloff?
        // (uint256 repay, uint256 yield) = eeWETH_intermediate_vault.checkLiquidation(liquidator, address(alice_collateral_vault), address(alice_collateral_vault));
        // if (repay != 0 || yield != 0) {
        //     // either repay or yield is NOT zero, means internal borrow can be liquidated
        //     console2.log("Repay or yield is not zero!", repay);
        // }

        // Use the checkLiquidation() function to verify that the position can be liquidated
        bool canLiq = alice_collateral_vault.canLiquidate();
        assertTrue(canLiq, "Vault should be unhealthy, but cannot be liquidated!");

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_collateral_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // repay debt in Euler
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.liquidate, ())
        });

        // and now add collateral to make position more healthy
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.repay, (alice_collateral_vault.maxRepay()))
        });

        evc.batch(items);

        // confirm vault ownership changed to liquidator
        assertEq(alice_collateral_vault.borrower(), liquidator, "Wrong collateral vault owner after liquidation");

        // intermediate vault debt is unchanged
        assertApproxEqRel(
            alice_collateral_vault.maxRelease(),
            BORROW_ETH_AMOUNT,
            1e15,
            "EVK debt not correct amount after liquidation"
        );

        // confirm no Euler debt remains
        eulerCurrentDebt = alice_collateral_vault.maxRepay();
        assertEq(eulerCurrentDebt, 0, "Debt to Euler is not zero!");

        // confirm withdrawal not possible because intermediate vault debt remains
        // TODO fix this vm.expectRevert() to confirm withdraw() fails
        // vm.expectRevert(Errors.E_AccountLiquidity.selector);
        // alice_collateral_vault.withdraw(alice_collateral_vault.balanceOf(address(alice_collateral_vault)), liquidator, liquidator);

        vm.stopPrank();
    }


    // Test 5: liquidator who liquidates and makes the position healthy by repaying all debt ends up with LTV of 0 (no debt at all)
    function test_e_liquidate_make_healthy_zero_debt() public noGasMetering {
        test_e_setupLiquidation();
        // Verify all asset balances before liquidation process
        // Verify that Alice holds collateral vault shares and intermediate vault debt
        assertEq(alice_collateral_vault.balanceOf(address(alice_collateral_vault)), COLLATERAL_AMOUNT, "Alice has wrong collateral vault shares balance");
        assertApproxEqRel(alice_collateral_vault.maxRelease(), BORROW_ETH_AMOUNT, 1e5, "EVK debt not correct amount before liquidation");
        uint256 eulerCurrentDebt = alice_collateral_vault.maxRepay();
        assertEq(eulerCurrentDebt, BORROW_USD_AMOUNT, "Euler current debt is wrong"); // original debt was BORROW_USD_AMOUNT
        // Verify that liquidator has no collateral vault shares and no intermediate vault debt before the liquidation
        assertEq(alice_collateral_vault.balanceOf(liquidator), 0, "Liquidator should have zero collateral vault shares 1");
        assertEq(eeWETH_intermediate_vault.debtOf(liquidator), 0, "Liquidator should have zero intermediate vault debt 1");

        // Verify that the internal borrow from the intermediate vault cannot be liquidated currently
        vm.startPrank(liquidator);
        // TODO why is the call below reverting due to liquidation cooloff?
        // (uint256 repay, uint256 yield) = eeWETH_intermediate_vault.checkLiquidation(liquidator, address(alice_collateral_vault), address(alice_collateral_vault));
        // if (repay != 0 || yield != 0) {
        //     // either repay or yield is NOT zero, means internal borrow can be liquidated
        //     console2.log("Repay or yield is not zero!", repay);
        // }

        // Use the checkLiquidation() function to verify that the position can be liquidated
        bool canLiq = alice_collateral_vault.canLiquidate();
        assertTrue(canLiq, "Vault should be unhealthy, but cannot be liquidated!");

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_collateral_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](4);

        uint maxWithdraw = alice_collateral_vault.totalAssetsDepositedOrReserved() - alice_collateral_vault.maxRelease();
        // repay debt in Euler
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.liquidate, ())
        });

        // and now add collateral to make position more healthy
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.repay, (alice_collateral_vault.maxRepay()))
        });

        // and now add collateral to make position more healthy
        items[2] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.release, (type(uint256).max))
        });

        items[3] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.withdraw, (maxWithdraw - 1, alice))
        });

        // liquidator didn't withdraw fully to satisfy invariants
        vm.expectRevert(TwyneErrors.VaultHasNegativeExcessCredit.selector);
        evc.batch(items);

        items[3].data = abi.encodeCall(alice_collateral_vault.withdraw, (maxWithdraw, alice));
        evc.batch(items);

        // confirm vault ownership changed to liquidator
        assertEq(alice_collateral_vault.borrower(), liquidator, "Wrong collateral vault owner after liquidation");

        // confirm no Euler external borrow debt remains
        uint256 externalCurrentDebt = alice_collateral_vault.maxRepay();
        assertEq(externalCurrentDebt, 0, "Debt to Euler is not zero!");
        // Verify that Alice holds no collateral vault shares and no intermediate vault debt
        assertEq(alice_collateral_vault.maxRelease(), 0, "Alice intermediate vault debt not zero");

        // now assets can be withdrawn from the collateral vault because there is no debt
        assertEq(alice_collateral_vault.balanceOf(address(alice_collateral_vault)), 0);

        vm.stopPrank();
    }

    // Test 6: liquidator who liquidates worthless collateral doesn't need to repay anything (what is the reasoning for adding code to this case? Maybe for memecoins?)
    // TODO not sure how to handle this case, because if collateral value is insufficient, liquidating means you have to supply some collateral to make it healthy
    function test_e_liquidate_worthless_collateral() public noGasMetering {
        test_e_setupLiquidation();

        // make the collateral value worthless
        mockOracle.setPrice(eulerWETH, USD, 0);

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_collateral_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(liquidator);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // repay debt in Euler
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.liquidate, ())
        });

        // and now add collateral to make position more healthy
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.repay, (alice_collateral_vault.maxRepay()))
        });

        evc.batch(items);

        vm.stopPrank();

        assertEq(alice_collateral_vault.borrower(), liquidator, "Wrong collateral vault owner after liquidation");

        // intermediate vault debt is unchanged
        assertApproxEqRel(
            alice_collateral_vault.maxRelease(),
            BORROW_ETH_AMOUNT,
            1e15,
            "EVK debt not correct amount after liquidation"
        );

        // engn33r did not expect that the liquidator has to call enableCollateral() and enableController() for the EVK vault being liquidated
        // but in hindsight this makes sense because the liquidator is taking over the borrower's position
        // so the liquidator should call the same functions that the borrower does before borrowing
        // evc.enableCollateral(backupLiquidator, address(alice_collateral_vault));
        // evc.enableController(backupLiquidator, address(eeWETH_intermediate_vault));

        vm.stopPrank();
    }

    // Test 8: what happens if the Twyne EVK borrow becomes liquidatable before the Euler liquidation is triggered?
    // We have disabled EVK vault liquidation (BridgeHookTarget is called on EVK liquidation which reverts).
    function test_e_liquidate_bad_evk_debt() public noGasMetering {
        test_e_setupLiquidation();

        // lower the liquidation LTV on the EVK vault to below the current borrow LTV to make it instantly liquidatable
        vm.startPrank(address(twyneVaultManager.owner()));
        twyneVaultManager.setLTV(eeWETH_intermediate_vault, address(alice_collateral_vault), 0.01e4, 0.05e4, 0);
        vm.stopPrank();

        assertTrue(alice_collateral_vault.canLiquidate(), "Vault should be unhealthy but it cannot be liquidated!");

        // setLiquidationCoolOffTime(1) is called when intermediate vault is created, so warp forward by 1 block timestamp
        vm.warp(block.timestamp + 12);

        (uint256 collateralValue, uint256 liabilityValue) =
            eeWETH_intermediate_vault.accountLiquidity(address(alice_collateral_vault), true);
        assertGt(liabilityValue, collateralValue, "liability is not less than collateral, EVK liquidation is not possible");

        (uint256 maxRepay, uint256 maxYield) = eeWETH_intermediate_vault.checkLiquidation(liquidator, address(alice_collateral_vault), address(alice_collateral_vault));
        assertTrue(maxRepay > 0, "maxRepay is zero!");
        assertTrue(maxYield > 0, "maxYield is zero!");

        vm.deal(liquidator, 10 ether);
        deal(address(USDC), liquidator, 10e20);
        dealEToken(eulerWETH, liquidator, 10 * COLLATERAL_AMOUNT);

        IEVC(eeWETH_intermediate_vault.EVC()).enableController(address(this), address(eeWETH_intermediate_vault));
        IEVC(eeWETH_intermediate_vault.EVC()).enableCollateral(address(this), address(alice_collateral_vault));

        // first: try a direct liquidate call
        vm.expectRevert(TwyneErrors.NotExternallyLiquidated.selector);
        eeWETH_intermediate_vault.liquidate(address(alice_collateral_vault), address(alice_collateral_vault), type(uint256).max, 0);

        // second: try evc batch call
        IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](1);
        batchItems[0] = IEVC.BatchItem({
            targetContract: address(eeWETH_intermediate_vault),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeCall(
                ILiquidation.liquidate,
                (address(alice_collateral_vault), address(alice_collateral_vault), type(uint256).max, 0)
            )
        });

        vm.expectRevert(TwyneErrors.NotExternallyLiquidated.selector);
        evc.batch(batchItems);

        assertEq(alice_collateral_vault.maxRelease(), badEVKDebtAmount, "EVK debt after EVK liq incorrect");
    }

    // Test F1: liquidation reverts when borrower position is healthy
    function test_e_liquidate_fails_healthy_cant_liquidate() public noGasMetering {
        test_e_setupLiquidation();

        vm.startPrank(alice);
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint).max);
        alice_collateral_vault.repay(BORROW_USD_AMOUNT/2);
        vm.stopPrank();

        // move the chain to current timestamp and block + 1 days (not the +365 days of normal liquidation flow)
        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 12);
        mockOracle.setPrice(eulerWETH, USD, WETH_USD_PRICE_INITIAL);

        bool canLiq = alice_collateral_vault.canLiquidate();
        assertFalse(canLiq, "Vault should be healthy but it can be liquidated!");
        vm.startPrank(liquidator);
        // try to liquidate, but it will revert
        vm.expectRevert(TwyneErrors.HealthyNotLiquidatable.selector);
        alice_collateral_vault.liquidate();
        vm.stopPrank();
    }


    // Test F2: if liquidator attempts to repay with more than maxRepay, liquidate call reverts
    function test_e_liquidate_fails_excess_repay() public noGasMetering {
        test_e_setupLiquidation();


        // Check vault owner changes before/after liquidation happens
        assertEq(alice_collateral_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(liquidator);

        vm.expectRevert();
        alice_collateral_vault.liquidate();

        vm.stopPrank();
    }

    // Test F3: liquidator who liquidates and makes the position healthy cannot be liquidated immediately
    // This test case is covered by previous test cases

    // Test F3.1: liquidator who liquidates and doesn't handle the debt but tries to withdraw collateral should not be able to (subcase of above, no need to test)

    // Test F4: borrower who has LTV at the liquidation threshold cannot be liquidated (LTV must be worse than threshold)
    function test_e_liquidate_fails_at_threshold() public noGasMetering {
    }

    // Test F5: self-liquidation should revert
    function test_e_liquidate_fails_self_liquidate() public noGasMetering {
        test_e_setupLiquidation();

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_collateral_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(alice);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // repay debt in Euler
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.liquidate, ())
        });

        // and now add collateral to make position more healthy
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.deposit, (COLLATERAL_AMOUNT))
        });

        // Expect SelfLiquidation() error
        vm.expectRevert(TwyneErrors.SelfLiquidation.selector);
        evc.batch(items);

        // confirm vault owner is still alice
        assertEq(alice_collateral_vault.borrower(), alice, "Wrong collateral vault owner after liquidation");

        vm.stopPrank();
    }
}
