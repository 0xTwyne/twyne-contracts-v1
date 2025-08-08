// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {OverCollateralizedTestBase, console2, BridgeHookTarget} from "./OverCollateralizedTestBase.t.sol";
import "euler-vault-kit/EVault/shared/types/Types.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {CrossAdapter} from "euler-price-oracle/src/adapter/CrossAdapter.sol";
import {IPriceOracle} from "euler-price-oracle/src/interfaces/IPriceOracle.sol";
import {Errors as OracleErrors} from "euler-price-oracle/src/lib/Errors.sol";
import {EulerCollateralVault} from "src/twyne/EulerCollateralVault.sol";
import {Errors} from "euler-vault-kit/EVault/shared/Errors.sol";
import {Events} from "euler-vault-kit/EVault/shared/Events.sol";
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

    function test_e_preLiquidationSetup(uint16 liqLTV) public {
        // copy logic from checkLiqLTV
        uint16 minLTV = IEVault(eulerUSDC).LTVLiquidation(eulerWETH);
        uint16 extLiqBuffer = twyneVaultManager.externalLiqBuffers(eulerWETH);
        vm.assume(uint(minLTV) * uint(extLiqBuffer) <= uint256(liqLTV) * MAXFACTOR);
        vm.assume(liqLTV <= twyneVaultManager.maxTwyneLTVs(eulerWETH));
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
                _liqLTV: liqLTV
            })
        );

        vm.label(address(alice_collateral_vault), "alice_collateral_vault");

        // Alice deposit the eulerWETH token into the collateral vault
        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint256).max);

        BORROW_ETH_AMOUNT = getReservedAssets(COLLATERAL_AMOUNT, alice_collateral_vault);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        // reserve assets from intermediate vault
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.deposit, (COLLATERAL_AMOUNT))
        });

        evc.batch(items);

        // Assume the user max borrows to arrive at the extreme limit of what is possible without liquidation
        vm.startPrank(alice);

        // Use the first liquidation condition in _canLiquidate
        (uint256 externalCollateralValueScaledByLiqLTV, ) = IEVault(alice_collateral_vault.targetVault()).accountLiquidity(address(alice_collateral_vault), true);
        uint256 borrowAmountUSD1 = uint256(twyneVaultManager.externalLiqBuffers(alice_collateral_vault.asset())) * externalCollateralValueScaledByLiqLTV / MAXFACTOR;

        uint USDCPrice = eulerOnChain.getQuote(1, USDC, USD); // returns a value times 1e10

        // Use the second liquidation condition in _canLiquidate
        (externalCollateralValueScaledByLiqLTV, ) = IEVault(alice_collateral_vault.targetVault()).accountLiquidity(address(alice_collateral_vault), true);
        uint borrowAmountUSD2 = eulerOnChain.getQuote(
            alice_collateral_vault.totalAssetsDepositedOrReserved() * uint(IEVault(eulerUSDC).LTVBorrow(eulerWETH)) / MAXFACTOR,
            eulerWETH,
            USD
        );

        if (borrowAmountUSD1 < borrowAmountUSD2) {
            BORROW_USD_AMOUNT = borrowAmountUSD1 / USDCPrice;
        } else {
            BORROW_USD_AMOUNT = borrowAmountUSD2 / USDCPrice;
        }

        alice_collateral_vault.borrow(BORROW_USD_AMOUNT, alice);

        if (borrowAmountUSD1 < borrowAmountUSD2) { // this case happens when safety buffer is low (below 0.975)
            vm.expectRevert(TwyneErrors.VaultStatusLiquidatable.selector);
        } else { // this case happens when safety buffer is very high (near 1)
            vm.expectRevert(Errors.E_AccountLiquidity.selector);
        }
        alice_collateral_vault.borrow(1, alice);

        vm.stopPrank();
    }

    function test_e_postSetupChecks() public noGasMetering {
        test_e_preLiquidationSetup(twyneLiqLTV);

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
    }

    // There are different ways to trigger a liquidation on Twyne:
    // 1. Interest accrual over time
    // 2. A price decrease of the collateral asset
    // 3. A price increase of the borrowed asset
    // 4. Safety buffer change on Twyne
    // 5. Liquidation LTV change in the underlying protocol
    // 6. User changing their liquidation LTV (actually this reverts, but confirm the revert case)

    // This accrues interest only for low safety buffers, otherwise it triggers liquidation by price movement of mock oracle
    function test_e_setupLiquidationAccrueInterest(uint16 liqLTV) public noGasMetering {
        test_e_preLiquidationSetup(liqLTV);

        // Put the vault into a liquidatable state
        if (twyneVaultManager.externalLiqBuffers(eulerWETH) < 0.975e4) {
            // If safety buffer is not very high, can warp forward a small amount to achieve a liquidatable position
            vm.warp(block.timestamp + 600); // accrue interest
        } else {
            // If safety buffer is very high, set price with mockOracle
            address eulerRouter = IEVault(eulerUSDC).oracle();
            vm.startPrank(EulerRouter(eulerRouter).governor());
            EulerRouter(eulerRouter).govSetConfig(WETH, USD, address(mockOracle));
            EulerRouter(eulerRouter).govSetConfig(USDC, USD, address(mockOracle));
            mockOracle.setPrice(WETH, USD, WETH_USD_PRICE_INITIAL*95/100);
            mockOracle.setPrice(USDC, USD, USDC_USD_PRICE_INITIAL);
            vm.stopPrank();

            vm.startPrank(oracleRouter.governor());
            oracleRouter.govSetConfig(WETH, USD, address(mockOracle));
            mockOracle.setPrice(WETH, USD, WETH_USD_PRICE_INITIAL*95/100);
            vm.stopPrank();
        }

        // Verify debt to intermediate vault increased IF there was a non-zero BORROW_ETH_AMOUNT amount reserved
        (, uint liabilityValue) = eeWETH_intermediate_vault.accountLiquidity(address(alice_collateral_vault), true);
        if (BORROW_ETH_AMOUNT != 0) {
            assertGt(liabilityValue, BORROW_ETH_AMOUNT, "alice debt to intermediate vault did not increase");
        }

        // confirm vault can be liquidated now that there is more collateral
        assertTrue(alice_collateral_vault.canLiquidate(), "Vault should be unhealthy but it cannot be liquidated!");

        vm.startPrank(liquidator);
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint256).max);
        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint256).max);

        vm.stopPrank();
    }

    function test_e_setupLiquidationFromSafetyBufferChange(uint16 liqLTV) public noGasMetering {
        test_e_preLiquidationSetup(liqLTV);

        // To put the vault into a liquidatable state, don't warp, but alter the safety buffer
        vm.startPrank(admin);
        twyneVaultManager.setExternalLiqBuffer(eulerWETH, 0.8e4);
        vm.stopPrank();

        // Verify debt to intermediate vault increased
        (, uint liabilityValue) = eeWETH_intermediate_vault.accountLiquidity(address(alice_collateral_vault), true);
        if (BORROW_ETH_AMOUNT != 0) {
            assertGt(liabilityValue, BORROW_ETH_AMOUNT, "alice debt to intermediate vault did not increase");
        }

        // confirm vault can be liquidated now that there is more collateral
        assertTrue(alice_collateral_vault.canLiquidate(), "Vault should be unhealthy but it cannot be liquidated!");

        vm.startPrank(liquidator);
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint256).max);
        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint256).max);

        vm.stopPrank();
    }

    function test_e_setupLiquidationFromExternalLTVChange(uint16 liqLTV) public noGasMetering {
        test_e_preLiquidationSetup(liqLTV);

        // To put the vault into a liquidatable state, don't warp, but lower the external LTV
        vm.startPrank(IEVault(eulerUSDC).governorAdmin());
        IEVault(eulerUSDC).setLTV(eulerWETH, 0.5e4, 0.6e4, 0);
        vm.stopPrank();

        // to ensure vaults are out of liquidation cool off period
        vm.warp(block.timestamp + 2);

        // Verify debt to intermediate vault increased
        (, uint liabilityValue) = eeWETH_intermediate_vault.accountLiquidity(address(alice_collateral_vault), true);
        if (BORROW_ETH_AMOUNT != 0) {
            assertGt(liabilityValue, BORROW_ETH_AMOUNT, "alice debt to intermediate vault did not increase");
        }

        // confirm vault can be liquidated now that there is more collateral
        assertTrue(alice_collateral_vault.canLiquidate(), "Vault should be unhealthy but it cannot be liquidated!");

        // Confirm external liquidation is possible from eulerUSDC perspective
        (uint maxrepay, ) = IEVault(eulerUSDC).checkLiquidation(address(this), address(alice_collateral_vault), eulerWETH);
        assertGt(maxrepay, 0, "Vault cannot be externally liquidated");

        vm.startPrank(liquidator);
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint256).max);
        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint256).max);

        vm.stopPrank();
    }

    function test_e_cannotSetupLiquidationFromTwyneLTVChange() public noGasMetering {
        test_e_preLiquidationSetup(twyneLiqLTV);

        // To put the vault into a liquidatable state, user sets a dumb LTV
        // But it encounters an error
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_collateral_vault.setTwyneLiqLTV(0.95e4);
        vm.stopPrank();
    }

    function test_e_setupCompleteExternalLiquidation() public noGasMetering {
        test_e_preLiquidationSetup(twyneLiqLTV);

        // Borrow using the exact amounts of an older test setup
        vm.startPrank(alice);
        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint).max);
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint).max);
        alice_collateral_vault.deposit(5 ether);
        alice_collateral_vault.borrow(6983982500, alice);
        vm.stopPrank();

                // Put the vault into a liquidatable state
        if (twyneVaultManager.externalLiqBuffers(eulerWETH) < 0.975e4) {
            // If safety buffer is not very high, can warp forward a small amount to achieve a liquidatable position
            vm.warp(block.timestamp + 600); // accrue interest
        } else {
            // If safety buffer is very high, set price with mockOracle
            address eulerRouter = IEVault(eulerUSDC).oracle();
            vm.startPrank(EulerRouter(eulerRouter).governor());
            EulerRouter(eulerRouter).govSetConfig(WETH, USD, address(mockOracle));
            EulerRouter(eulerRouter).govSetConfig(USDC, USD, address(mockOracle));
            mockOracle.setPrice(WETH, USD, WETH_USD_PRICE_INITIAL*3/10);
            mockOracle.setPrice(USDC, USD, USDC_USD_PRICE_INITIAL);
            vm.stopPrank();

            vm.startPrank(oracleRouter.governor());
            oracleRouter.govSetConfig(WETH, USD, address(mockOracle));
            mockOracle.setPrice(WETH, USD, WETH_USD_PRICE_INITIAL*3/10);
            vm.stopPrank();
        }
    }

    function test_e_handleCompleteExternalLiquidation() public noGasMetering {
        test_e_setupCompleteExternalLiquidation();

        // Verify debt to intermediate vault increased
        (, uint liabilityValue) = eeWETH_intermediate_vault.accountLiquidity(address(alice_collateral_vault), true);
        if (BORROW_ETH_AMOUNT != 0) {
            assertGt(liabilityValue, BORROW_ETH_AMOUNT, "alice debt to intermediate vault did not increase");
        }

        // confirm vault can be liquidated now that there is more collateral
        assertTrue(alice_collateral_vault.canLiquidate(), "Vault should be unhealthy but it cannot be liquidated!");

        vm.warp(block.timestamp + 1);

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

        assertTrue(alice_collateral_vault.isExternallyLiquidated(), "collateral vault was not externally liquidated");

        // Since the external liquidation reduced the debt and its collateral amount to 0,
        // there is no collateral that is collateralizing the intermediate vault debt.
        assertEq(IEVault(eulerUSDC).debtOf(address(alice_collateral_vault)), 0, "collateral vault debt to euler USDC vault is not zero");
        assertEq(IERC20(eulerWETH).balanceOf(address(alice_collateral_vault)), 0, "euler WETH in collateral vault is not zero");
        assertGt(alice_collateral_vault.maxRelease(), 0, "collateral vault maxRelease is zero");
        uint initialMaxRelease = alice_collateral_vault.maxRelease();

        // Check that you can't do operations on collateral vault
        // after external liquidation.
        vm.startPrank(alice);

        vm.expectRevert(TwyneErrors.ExternallyLiquidated.selector);
        alice_collateral_vault.liquidate();

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

        vm.expectRevert(TwyneErrors.BadDebtNotSettled.selector);
        evc.batch(items);

        // Need to call liquidate() on intermediate vault in the same batch as handleExternalLiquidation() to settle accounting
        IEVC.BatchItem[] memory items1 = new IEVC.BatchItem[](2);
        items1[0] = items[0];
        items1[1] = IEVC.BatchItem({
            onBehalfOfAccount: newLiquidator,
            targetContract: address(alice_collateral_vault.intermediateVault()),
            value: 0,
            data: abi.encodeCall(IEVault(eulerWETH).liquidate, (address(alice_collateral_vault), address(alice_collateral_vault), 0, 0))
        });

        vm.expectEmit(false, false, true, true);
        emit Events.DebtSocialized(address(alice_collateral_vault), initialMaxRelease);
        evc.batch(items1);

        // Confirm collateral vault is empty
        assertEq(IERC20(eulerWETH).balanceOf(address(alice_collateral_vault)), 0, "collateral vault is not empty");

        vm.stopPrank();

        assertEq(IERC20(eulerWETH).balanceOf(address(alice_collateral_vault)), 0, "collateral vault is not empty");
        assertEq(alice_collateral_vault.borrower(), address(0));
        assertEq(alice_collateral_vault.balanceOf(address(alice_collateral_vault)), 0);
        assertEq(alice_collateral_vault.maxRelease(), 0);

        // Confirm that the collateral vault is no longer usable
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_collateral_vault.deposit(1);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_collateral_vault.depositUnderlying(1);
    }

    function test_e_handleExternalLiquidationWithZeroMaxRelease() public noGasMetering {
        // Calculate minimum LTV so the collateral vault mimics a position on the underlying protocol
        uint16 minimumLTV = uint16(uint(IEVault(eulerUSDC).LTVLiquidation(eulerWETH)) * uint(twyneVaultManager.externalLiqBuffers(eulerWETH)) / MAXFACTOR);
        test_e_preLiquidationSetup(minimumLTV);

        // Put the vault into a liquidatable state
        if (twyneVaultManager.externalLiqBuffers(eulerWETH) < 0.975e4) {
            // If safety buffer is not very high, can warp forward a small amount to achieve a liquidatable position
            vm.warp(block.timestamp + 600); // accrue interest
        } else {
            // If safety buffer is very high, set price with mockOracle
            address eulerRouter = IEVault(eulerUSDC).oracle();
            vm.startPrank(EulerRouter(eulerRouter).governor());
            EulerRouter(eulerRouter).govSetConfig(WETH, USD, address(mockOracle));
            EulerRouter(eulerRouter).govSetConfig(USDC, USD, address(mockOracle));
            mockOracle.setPrice(WETH, USD, WETH_USD_PRICE_INITIAL*95/100);
            mockOracle.setPrice(USDC, USD, USDC_USD_PRICE_INITIAL);
            vm.stopPrank();

            vm.startPrank(oracleRouter.governor());
            oracleRouter.govSetConfig(WETH, USD, address(mockOracle));
            mockOracle.setPrice(WETH, USD, WETH_USD_PRICE_INITIAL*95/100);
            vm.stopPrank();
        }

        // confirm vault can be liquidated now that there is more collateral
        assertTrue(alice_collateral_vault.canLiquidate(), "Vault should be unhealthy but it cannot be liquidated!");

        vm.warp(block.timestamp + 1);

        // Ensure liquidator has enough eulerWETH to be a valid liquidator
        dealEToken(eulerWETH, liquidator, 100 ether);

        vm.startPrank(liquidator);

        IEVC(IEVault(eulerWETH).EVC()).enableCollateral(liquidator, address(eulerWETH));
        IEVC(IEVault(eulerUSDC).EVC()).enableController(liquidator, address(eulerUSDC));

        // Assert initial state, the reverse will be true after external liquidation
        assertFalse(alice_collateral_vault.isExternallyLiquidated());
        assertGt(IERC20(eulerWETH).balanceOf(address(alice_collateral_vault)), 0, "before: euler WETH in collateral vault is not zero");

        // liquidate alice_collateral_vault via eulerUSDC EVault
        assertGt(alice_collateral_vault.maxRepay(), 0);

        // This decreases the entire debt to 0, but leaves some collateral.
        IEVault(eulerUSDC).liquidate({
            violator: address(alice_collateral_vault),
            collateral: eulerWETH,
            repayAssets: type(uint).max,
            minYieldBalance: 0
        });
        vm.stopPrank();

        assertTrue(alice_collateral_vault.isExternallyLiquidated(), "collateral vault was not externally liquidated");

        assertEq(IEVault(eulerUSDC).debtOf(address(alice_collateral_vault)), 0, "collateral vault debt to euler USDC vault is not zero");
        // TODO fix below line
        assertGt(IERC20(eulerWETH).balanceOf(address(alice_collateral_vault)), 0, "after: euler WETH in collateral vault is not zero");
        assertEq(alice_collateral_vault.maxRelease(), 0, "collateral vault maxRelease is zero");

        address newLiquidator = makeAddr("newLiquidator");
        vm.startPrank(newLiquidator);

        evc.enableController(newLiquidator, address(alice_collateral_vault.intermediateVault()));

        // Only borrower can call this function since reserved credit is 0.
        vm.expectRevert(TwyneErrors.NoLiquidationForZeroReserve.selector);
        alice_collateral_vault.handleExternalLiquidation();
        vm.stopPrank();

        vm.startPrank(alice);
        alice_collateral_vault.handleExternalLiquidation();
        vm.stopPrank();

        // Confirm collateral vault is empty
        assertEq(IERC20(eulerWETH).balanceOf(address(alice_collateral_vault)), 0, "collateral vault is not empty");
        assertEq(alice_collateral_vault.borrower(), address(0));
        assertEq(alice_collateral_vault.balanceOf(address(alice_collateral_vault)), 0);
        assertEq(alice_collateral_vault.maxRelease(), 0);
    }

    function test_e_handlePartialExternalLiquidation() public noGasMetering {
        test_e_setupLiquidationFromExternalLTVChange(twyneLiqLTV);
        vm.warp(block.timestamp + 1);

        // Ensure liquidator has enough eulerWETH to be a valid liquidator
        dealEToken(eulerWETH, liquidator, 100 ether);

        vm.startPrank(liquidator);

        IEVC(IEVault(eulerWETH).EVC()).enableCollateral(liquidator, address(eulerWETH));
        IEVC(IEVault(eulerUSDC).EVC()).enableController(liquidator, address(eulerUSDC));

        IEVC(IEVault(alice_collateral_vault.intermediateVault()).EVC()).enableCollateral(liquidator, address(alice_collateral_vault));
        IEVC(IEVault(alice_collateral_vault.intermediateVault()).EVC()).enableController(liquidator, address(alice_collateral_vault.intermediateVault()));

        assertFalse(alice_collateral_vault.isExternallyLiquidated());
        // liquidate alice_collateral_vault via eulerUSDC EVault
        assertGt(alice_collateral_vault.maxRepay(), 0);

        // Cache the amount to repay to fully settle the liquidation
        (uint maxrepay, ) = IEVault(eulerUSDC).checkLiquidation(address(this), address(alice_collateral_vault), eulerWETH);

        // Test for non-zero debt and collateral amount after external liquidation.
        IEVault(eulerUSDC).liquidate({
            violator: address(alice_collateral_vault),
            collateral: eulerWETH,
            repayAssets: maxrepay,
            minYieldBalance: 0
        });
        assertTrue(alice_collateral_vault.isExternallyLiquidated());

        // Need to call handleExternalLiquidation, and then in the same batch, liquidate on intermediate vault
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            onBehalfOfAccount: liquidator,
            targetContract: address(alice_collateral_vault),
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.handleExternalLiquidation, ())
        });
        items[1] = IEVC.BatchItem({
            onBehalfOfAccount: liquidator,
            targetContract: address(alice_collateral_vault.intermediateVault()),
            value: 0,
            data: abi.encodeCall(IEVault(eulerWETH).liquidate, (address(alice_collateral_vault), address(alice_collateral_vault), 0, 0))
        });

        evc.batch(items);

        // Now create the proper CrossOracleAdapter for this scenario
        address baseAsset = alice_collateral_vault.targetAsset();
        address crossAsset = IEVault(alice_collateral_vault.asset()).unitOfAccount();
        address quoteAsset = IEVault(alice_collateral_vault.asset()).asset();
        address oracleBaseCross = EulerRouter(IEVault(eulerUSDC).oracle()).getConfiguredOracle(baseAsset, crossAsset);
        address oracleCrossQuote = EulerRouter(IEVault(eulerUSDC).oracle()).getConfiguredOracle(quoteAsset, crossAsset);
        // Add the crossAdapter oracle to the EulerRouter
        vm.startPrank(admin);
        CrossAdapter crossAdapterOracle = new CrossAdapter(baseAsset, crossAsset, quoteAsset, address(oracleBaseCross), address(oracleCrossQuote));
        twyneVaultManager.doCall(address(twyneVaultManager.oracleRouter()), 0, abi.encodeCall(EulerRouter.govSetConfig, (baseAsset, quoteAsset, address(crossAdapterOracle))));
        vm.stopPrank();

        // assertGt(IEVault(eulerUSDC).debtOf(address(alice_collateral_vault)), 0);
        // assertGt(IERC20(eulerWETH).balanceOf(address(alice_collateral_vault)), 0);

        vm.stopPrank();

        // Check that you can't do operations on collateral vault
        // after external liquidation.
        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_collateral_vault.withdraw(1, alice);
        vm.stopPrank();

        assertEq(alice_collateral_vault.borrower(), address(0), "borrower NEQ address(0)");
        assertEq(alice_collateral_vault.balanceOf(address(alice_collateral_vault)), 0, "balanceOf alice NEQ 0");
        assertEq(alice_collateral_vault.maxRelease(), 0, "maxRelease NEQ 0");
    }

    function test_e_handleExternalLiquidationOnUnhealthyEulerPosition() public noGasMetering {
        test_e_setupCompleteExternalLiquidation();

        // confirm vault can be liquidated now that there is more collateral
        assertTrue(alice_collateral_vault.canLiquidate(), "Vault should be unhealthy but it cannot be liquidated!");

        vm.warp(block.timestamp + 1);

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
            repayAssets: 2,
            minYieldBalance: 0
        });
        vm.stopPrank();

        assertTrue(alice_collateral_vault.isExternallyLiquidated(), "collateral vault was not externally liquidated");
        (uint externalCollateralValueScaledByLiqLTV, uint externalBorrowDebtValue) = IEVault(eulerUSDC).accountLiquidity(address(alice_collateral_vault), true);
        assertTrue(externalCollateralValueScaledByLiqLTV < externalBorrowDebtValue, "Euler position should be unhealthy");

        address newLiquidator = makeAddr("newLiquidator");
        vm.startPrank(newLiquidator);

        evc.enableController(newLiquidator, address(alice_collateral_vault.intermediateVault()));

        vm.expectRevert(TwyneErrors.ExternalPositionUnhealthy.selector);
        alice_collateral_vault.handleExternalLiquidation();
    }

    function test_e_externalLiquidationDetectionConsidersCollateralAirdrop() public noGasMetering {
        test_e_setupLiquidationFromExternalLTVChange(twyneLiqLTV);
        vm.warp(block.timestamp + 1);

        // Ensure liquidator has enough eulerWETH to be a valid liquidator
        dealEToken(eulerWETH, liquidator, 100 ether);

        vm.startPrank(liquidator);

        IEVC(IEVault(eulerWETH).EVC()).enableCollateral(liquidator, address(eulerWETH));
        IEVC(IEVault(eulerUSDC).EVC()).enableController(liquidator, address(eulerUSDC));

        assertFalse(alice_collateral_vault.isExternallyLiquidated());
        // liquidate alice_collateral_vault via eulerUSDC EVault
        assertGt(alice_collateral_vault.maxRepay(), 0);

        // Cache the amount to repay to fully settle the liquidation
        (uint maxrepay, ) = IEVault(eulerUSDC).checkLiquidation(address(this), address(alice_collateral_vault), eulerWETH);

        // Test for non-zero debt and collateral amount after external liquidation.
        IEVault(eulerUSDC).liquidate({
            violator: address(alice_collateral_vault),
            collateral: eulerWETH,
            repayAssets: maxrepay/2,
            minYieldBalance: 0
        });
        assertTrue(alice_collateral_vault.isExternallyLiquidated());

        (uint256 collateralValue,) = IEVault(eulerUSDC).accountLiquidity(address(alice_collateral_vault), false);

        uint collateralToDeposit = alice_collateral_vault.totalAssetsDepositedOrReserved() - IERC20(eulerWETH).balanceOf(address(alice_collateral_vault));

        IERC20(eulerWETH).transfer(address(alice_collateral_vault), collateralToDeposit - 1);
        assertTrue(alice_collateral_vault.isExternallyLiquidated());
        IERC20(eulerWETH).transfer(address(alice_collateral_vault), 1);
        assertFalse(alice_collateral_vault.isExternallyLiquidated());
        IERC20(eulerWETH).transfer(address(alice_collateral_vault), 1);
        assertFalse(alice_collateral_vault.isExternallyLiquidated());
        vm.stopPrank();

        // Check that Euler sees the correct collateral amount
        (uint256 collateralValue1,) = IEVault(eulerUSDC).accountLiquidity(address(alice_collateral_vault), false);
        assertGt(
            collateralValue1,
            collateralValue,
            "Euler collateral amount doesn't consider airdrop"
        );
    }

    // Edge case where a batch attempts to force an external liquidation
    // This should not be possible
    function test_e_verifyBatchCannotForceExtLiquidation() public noGasMetering {
        test_e_setupLiquidationFromExternalLTVChange(twyneLiqLTV);

        // to ensure vaults are out of liquidation cool off period
        vm.warp(block.timestamp + 2);

        address eulerEVC = IEVault(eulerWETH).EVC();

        vm.startPrank(alice);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: eulerEVC,
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(evc.enableCollateral, (address(evc), eulerWETH))
        });
        items[1] = IEVC.BatchItem({
            targetContract: eulerEVC,
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(evc.enableController, (address(evc), eulerUSDC))
        });
        evc.batch(items);

        // Confirm Twyne liquidation can happen
        assertTrue(alice_collateral_vault.canLiquidate(), "Vault cannot be liquidated!");
        // Confirm external liquidation can happen
        (uint maxrepay, ) = IEVault(eulerUSDC).checkLiquidation(address(this), address(alice_collateral_vault), eulerWETH);
        assertGt(maxrepay, 0, "Vault cannot be externally liquidated");

        items[0] = IEVC.BatchItem({
            targetContract: eulerUSDC,
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(IEVault(eulerUSDC).liquidate, (address(alice_collateral_vault), eulerWETH, type(uint).max, 0))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.handleExternalLiquidation, ())
        });

        // cannot make a position unhealthy and liquidate in the same tx.
        // this reverts in items[2] tx.
        vm.expectRevert(Errors.E_AccountLiquidity.selector);
        evc.batch(items);
        vm.stopPrank();
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
    // 8. what happens if the Twyne reserved assets borrow becomes liquidatable on the intermediate vault before the Twyne liquidation is triggered?
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
    function test_e_liquidate_without_making_healthy_accrue_interest() public noGasMetering {
        test_e_setupLiquidationAccrueInterest(twyneLiqLTV);

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_collateral_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.VaultStatusLiquidatable.selector);
        alice_collateral_vault.liquidate();
        vm.stopPrank();
    }

    // Test 2: liquidator who liquidates and makes the position healthy with some extra collateral cannot get liquidated by someone else (and has expected LTV). Verify original borrower LTV is zero
    function test_e_liquidate_make_healthy_more_collateral_accrue_interest() public noGasMetering {
        test_e_setupLiquidationAccrueInterest(twyneLiqLTV);

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

        evc.batch(items);

        // confirm vault owner is liquidator
        assertEq(alice_collateral_vault.borrower(), liquidator, "Wrong collateral vault owner after liquidation");
        assertEq(collateralVaultFactory.getCollateralVaults(liquidator)[1], address(alice_collateral_vault));
        assertEq(collateralVaultFactory.getCollateralVaults(alice)[0], address(alice_collateral_vault));
        // confirm vault can NOT be liquidated now that there is more collateral
        // This tests scenario F3
        assertFalse(alice_collateral_vault.canLiquidate(), "Vault should be healthy but it can be liquidated!");

        vm.stopPrank();
    }

    // Test 3: liquidator who liquidates and makes the position healthy by repaying some debt cannot get liquidated by someone else (and has expected LTV). Verify original borrower LTV is zero
    function test_e_liquidate_make_healthy_reduce_debt_accrue_interest() public noGasMetering {
        test_e_setupLiquidationAccrueInterest(twyneLiqLTV);

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
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_collateral_vault.withdraw(1, alice);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_collateral_vault.withdraw(1, liquidator);
        vm.stopPrank();
    }

    // Test 4: liquidator who liquidates and makes the position healthy by repaying Aave debt ends up with LTV of 0 to Euler (no vUSDC debt)
    function test_e_liquidate_make_healthy_zero_euler_debt_accrue_interest() public noGasMetering {
        test_e_setupLiquidationAccrueInterest(twyneLiqLTV);
        // Verify all asset balances before liquidation process
        assertApproxEqRel(
            alice_collateral_vault.maxRelease(),
            BORROW_ETH_AMOUNT,
            1e14,
            "EVK debt not correct amount before liquidation"
        );
        uint256 eulerCurrentDebt = alice_collateral_vault.maxRepay();
        assertApproxEqRel(eulerCurrentDebt, BORROW_USD_AMOUNT, 1e12, "Euler current debt is wrong"); // original debt was BORROW_USD_AMOUNT
        // Verify that liquidator has no collateral vault shares and no intermediate vault debt before the liquidation
        assertEq(alice_collateral_vault.balanceOf(liquidator), 0, "Liquidator should have zero collateral vault shares 1");
        assertEq(eeWETH_intermediate_vault.debtOf(liquidator), 0, "Liquidator should have zero intermediate vault debt 1");

        // Avoid liquidation cooloff
        vm.warp(block.timestamp + 12);

        // Verify that the internal borrow from the intermediate vault cannot be liquidated currently
        vm.startPrank(liquidator);

        (uint256 repay, uint256 yield) = eeWETH_intermediate_vault.checkLiquidation(liquidator, address(alice_collateral_vault), address(alice_collateral_vault));
        if (repay != 0 || yield != 0) {
            // either repay or yield is NOT zero, means internal borrow can be liquidated
            console2.log("Repay or yield is not zero!", repay);
        }

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

        vm.stopPrank();
    }


    // Test 5: liquidator who liquidates and makes the position healthy by repaying all debt ends up with LTV of 0 (no debt at all)
    function test_e_liquidate_make_healthy_zero_debt_accrue_interest() public noGasMetering {
        test_e_setupLiquidationAccrueInterest(twyneLiqLTV);
        // Verify all asset balances before liquidation process
        // Verify that Alice holds collateral vault shares and intermediate vault debt
        assertApproxEqRel(alice_collateral_vault.maxRelease(), BORROW_ETH_AMOUNT, 1e14, "EVK debt not correct amount before liquidation");
        uint256 eulerCurrentDebt = alice_collateral_vault.maxRepay();
        assertApproxEqRel(eulerCurrentDebt, BORROW_USD_AMOUNT, 1e12, "Euler current debt is wrong"); // original debt was BORROW_USD_AMOUNT
        // Verify that liquidator has no collateral vault shares and no intermediate vault debt before the liquidation
        assertEq(alice_collateral_vault.balanceOf(liquidator), 0, "Liquidator should have zero collateral vault shares 1");
        assertEq(eeWETH_intermediate_vault.debtOf(liquidator), 0, "Liquidator should have zero intermediate vault debt 1");

        // Avoid liquidation cooloff
        vm.warp(block.timestamp + 12);

        // Verify that the internal borrow from the intermediate vault cannot be liquidated currently
        vm.startPrank(liquidator);

        (uint256 repay, uint256 yield) = eeWETH_intermediate_vault.checkLiquidation(liquidator, address(alice_collateral_vault), address(alice_collateral_vault));
        if (repay != 0 || yield != 0) {
            // either repay or yield is NOT zero, means internal borrow can be liquidated
            console2.log("Repay or yield is not zero!", repay);
        }

        // Use the checkLiquidation() function to verify that the position can be liquidated
        bool canLiq = alice_collateral_vault.canLiquidate();
        assertTrue(canLiq, "Vault should be unhealthy, but cannot be liquidated!");

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_collateral_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);

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

        items[2] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.withdraw, (maxWithdraw - 1, alice))
        });

        // liquidator didn't withdraw fully to satisfy invariants
        vm.expectRevert(Errors.E_AccountLiquidity.selector);
        evc.batch(items);

        items[2].data = abi.encodeCall(alice_collateral_vault.withdraw, (maxWithdraw, alice));
        evc.batch(items);

        // confirm vault ownership changed to liquidator
        assertEq(alice_collateral_vault.borrower(), liquidator, "Wrong collateral vault owner after liquidation");

        // confirm no Euler external borrow debt remains
        uint256 externalCurrentDebt = alice_collateral_vault.maxRepay();
        assertEq(externalCurrentDebt, 0, "Debt to Euler is not zero!");
        // Verify that Alice holds no collateral vault shares and no intermediate vault debt
        assertEq(alice_collateral_vault.maxRelease(), 0, "Alice intermediate vault debt not zero");

        // now collateral vault is empty
        assertEq(IERC20(eulerWETH).balanceOf(address(alice_collateral_vault)), 0, "Incorrect eulerWETH balance remaining in vault");

        vm.stopPrank();
    }

    // Test 6: liquidator who liquidates worthless collateral doesn't need to repay anything (what is the reasoning for adding code to this case? Maybe for memecoins?)
    // TODO not sure how to handle this case, because if collateral value is insufficient, liquidating means you have to supply some collateral to make it healthy
    function test_e_liquidate_worthless_collateral_accrue_interest() public noGasMetering {
        test_e_setupLiquidationAccrueInterest(twyneLiqLTV);

        // skip this test with high safety buffers
        if (twyneVaultManager.externalLiqBuffers(eulerWETH) < 0.975e4) {
            // make the collateral value worthless
            address eulerRouter = IEVault(eulerWETH).oracle();
            vm.startPrank(EulerRouter(eulerRouter).governor());
            EulerRouter(eulerRouter).govSetConfig(WETH, USD, address(mockOracle));
            vm.stopPrank();
            vm.startPrank(admin);
            // set WETH price in USD
            mockOracle.setPrice(WETH, USD, 0);
            vm.stopPrank();

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
    }

    // Test 8: what happens if the Twyne reserved assets borrow becomes liquidatable on the intermediate vault before the Twyne liquidation is triggered?
    // We have disabled EVK vault liquidation (BridgeHookTarget is called on EVK liquidation which reverts).
    function test_e_liquidate_bad_evk_debt_accrue_interest() public noGasMetering {
        // Set max twyneLiqLTV value
        twyneLiqLTV = twyneVaultManager.maxTwyneLTVs(eulerWETH);
        test_e_setupLiquidationAccrueInterest(twyneLiqLTV);

        // lower the liquidation LTV on the EVK vault to below the current borrow LTV to make it instantly liquidatable
        vm.startPrank(address(twyneVaultManager.owner()));
        twyneVaultManager.setLTV(eeWETH_intermediate_vault, address(alice_collateral_vault), 0.1e3, 0.15e3, 0);
        vm.stopPrank();

        // Confirm that Twyne collateral vault can be liquidated
        assertTrue(alice_collateral_vault.canLiquidate(), "Vault should be unhealthy but it cannot be liquidated!");

        // setLiquidationCoolOffTime(1) is called when intermediate vault is created, so warp forward by 1 block timestamp
        vm.warp(block.timestamp + 12);

        (uint256 collateralValue, uint256 liabilityValue) =
            eeWETH_intermediate_vault.accountLiquidity(address(alice_collateral_vault), true);
        if (BORROW_ETH_AMOUNT != 0) {
            assertGt(liabilityValue, collateralValue, "liability is not greater than collateral, EVK liquidation is not possible");
        }

        // Confirm that the intermediate vault's liquidation of the Twyne vault is possible
        // checkLiquidate() returns (0, 0) if the account is healthy (no liquidation possible)
        (uint256 maxRepay, uint256 maxYield) = eeWETH_intermediate_vault.checkLiquidation(liquidator, address(alice_collateral_vault), address(alice_collateral_vault));
        assertGt(maxRepay, 0, "maxRepay is zero!");
        assertGt(maxYield, 0, "maxYield is zero!");

        vm.deal(liquidator, 10 ether);
        deal(address(USDC), liquidator, 10e20);
        dealEToken(eulerWETH, liquidator, 10 * COLLATERAL_AMOUNT);

        IEVC(eeWETH_intermediate_vault.EVC()).enableController(address(this), address(eeWETH_intermediate_vault));
        IEVC(eeWETH_intermediate_vault.EVC()).enableCollateral(address(this), address(alice_collateral_vault));

        // first: liquidate() call on the intermediate vault reverts due to custom Twyne hook
        vm.expectRevert(TwyneErrors.NotExternallyLiquidated.selector);
        eeWETH_intermediate_vault.liquidate(address(alice_collateral_vault), address(alice_collateral_vault), type(uint256).max, 0);

        // second: try evc batch call, observe same revert
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
        assertGt(alice_collateral_vault.maxRelease(), 0, "EVK debt after EVK liq should be non-zero");
    }

    // Test F1: liquidation reverts when borrower position is healthy
    function test_e_liquidate_fails_healthy_cant_liquidate_accrue_interest() public noGasMetering {
        test_e_setupLiquidationAccrueInterest(twyneLiqLTV);

        vm.startPrank(alice);
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint).max);
        alice_collateral_vault.repay(BORROW_USD_AMOUNT/2);
        vm.stopPrank();

        // move the chain to current timestamp and block + 1 days (not the +365 days of normal liquidation flow)
        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 12);

        bool canLiq = alice_collateral_vault.canLiquidate();
        assertFalse(canLiq, "Vault should be healthy but it can be liquidated!");
        vm.startPrank(liquidator);
        // try to liquidate, but it will revert
        vm.expectRevert(TwyneErrors.HealthyNotLiquidatable.selector);
        alice_collateral_vault.liquidate();
        vm.stopPrank();
    }


    // Test F2: if liquidator attempts to repay with more than maxRepay, liquidate call reverts
    function test_e_liquidate_fails_excess_repay_accrue_interest() public noGasMetering {
        test_e_setupLiquidationAccrueInterest(twyneLiqLTV);


        // Check vault owner changes before/after liquidation happens
        assertEq(alice_collateral_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(liquidator);

        vm.expectRevert(TwyneErrors.VaultStatusLiquidatable.selector);
        alice_collateral_vault.liquidate();

        vm.stopPrank();
    }

    // Test F3: liquidator who liquidates and makes the position healthy cannot be liquidated immediately
    // This test case is covered by previous test cases

    // Test F3.1: liquidator who liquidates and doesn't handle the debt but tries to withdraw collateral should not be able to (subcase of above, no need to test)

    // Test F4: borrower who has LTV at the liquidation threshold cannot be liquidated (LTV must be worse than threshold)
    function test_e_liquidate_fails_at_threshold_accrue_interest() public noGasMetering {
        test_e_setupLiquidationAccrueInterest(twyneLiqLTV);

        // Skip this test with high safety buffers
        // Undo the process of putting the vault into a liquidatable state
        if (twyneVaultManager.externalLiqBuffers(eulerWETH) < 0.975e4) {
            // If safety buffer is not very high, can warp forward a small amount to achieve a liquidatable position
            vm.warp(block.timestamp - 600);  // reverse the accrual of 10 minutes of interest

            vm.startPrank(alice);
            IERC20(USDC).approve(address(alice_collateral_vault), type(uint256).max);
            alice_collateral_vault.repay(1);
            alice_collateral_vault.borrow(1, alice);
            vm.expectRevert(TwyneErrors.VaultStatusLiquidatable.selector);
            alice_collateral_vault.borrow(1, alice);
            vm.stopPrank();

            vm.startPrank(liquidator);
            vm.expectRevert(TwyneErrors.HealthyNotLiquidatable.selector);
            alice_collateral_vault.liquidate();
            vm.stopPrank();
        }
    }

    // Test F5: self-liquidation should revert
    function test_e_liquidate_fails_self_liquidate_accrue_interest() public noGasMetering {
        test_e_setupLiquidationAccrueInterest(twyneLiqLTV);

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
    // 8. what happens if the Twyne reserved assets borrow becomes liquidatable on the intermediate vault before the Twyne liquidation is triggered?
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
    function test_e_liquidate_without_making_healthy_safetybuffer() public noGasMetering {
        test_e_setupLiquidationFromSafetyBufferChange(twyneLiqLTV);

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_collateral_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.VaultStatusLiquidatable.selector);
        alice_collateral_vault.liquidate();
        vm.stopPrank();
    }

    // Test 2: liquidator who liquidates and makes the position healthy with some extra collateral cannot get liquidated by someone else (and has expected LTV). Verify original borrower LTV is zero
    function test_e_liquidate_make_healthy_more_collateral_safetybuffer() public noGasMetering {
        test_e_setupLiquidationFromSafetyBufferChange(twyneLiqLTV);

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

        evc.batch(items);

        // confirm vault owner is liquidator
        assertEq(alice_collateral_vault.borrower(), liquidator, "Wrong collateral vault owner after liquidation");
        assertEq(collateralVaultFactory.getCollateralVaults(liquidator)[1], address(alice_collateral_vault));
        assertEq(collateralVaultFactory.getCollateralVaults(alice)[0], address(alice_collateral_vault));
        // confirm vault can NOT be liquidated now that there is more collateral
        // This tests scenario F3
        assertFalse(alice_collateral_vault.canLiquidate(), "Vault should be healthy but it can be liquidated!");

        vm.stopPrank();
    }

    // Test 3: liquidator who liquidates and makes the position healthy by repaying some debt cannot get liquidated by someone else (and has expected LTV). Verify original borrower LTV is zero
    function test_e_liquidate_make_healthy_reduce_debt_safetybuffer() public noGasMetering {
        test_e_setupLiquidationFromSafetyBufferChange(twyneLiqLTV);

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

        vm.stopPrank();

        // alice can't withdraw from collateral vault now
        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_collateral_vault.withdraw(1, alice);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_collateral_vault.withdraw(1, liquidator);
        vm.stopPrank();
    }

    // Test 4: liquidator who liquidates and makes the position healthy by repaying Aave debt ends up with LTV of 0 to Euler (no vUSDC debt)
    function test_e_liquidate_make_healthy_zero_euler_debt_safetybuffer() public noGasMetering {
        test_e_setupLiquidationFromSafetyBufferChange(twyneLiqLTV);
        // Verify all asset balances before liquidation process
        uint256 eulerCurrentDebt = alice_collateral_vault.maxRepay();
        assertApproxEqRel(eulerCurrentDebt, BORROW_USD_AMOUNT, 1e12, "Euler current debt is wrong"); // original debt was BORROW_USD_AMOUNT
        // Verify that liquidator has no collateral vault shares and no intermediate vault debt before the liquidation
        assertEq(alice_collateral_vault.balanceOf(liquidator), 0, "Liquidator should have zero collateral vault shares 1");
        assertEq(eeWETH_intermediate_vault.debtOf(liquidator), 0, "Liquidator should have zero intermediate vault debt 1");

        // Avoid liquidation cooloff
        vm.warp(block.timestamp + 12);

        // Verify that the internal borrow from the intermediate vault cannot be liquidated currently
        vm.startPrank(liquidator);

        (uint256 repay, uint256 yield) = eeWETH_intermediate_vault.checkLiquidation(liquidator, address(alice_collateral_vault), address(alice_collateral_vault));
        if (repay != 0 || yield != 0) {
            // either repay or yield is NOT zero, means internal borrow can be liquidated
            console2.log("Repay or yield is not zero!", repay);
        }

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

        // confirm no Euler debt remains
        eulerCurrentDebt = alice_collateral_vault.maxRepay();
        assertEq(eulerCurrentDebt, 0, "Debt to Euler is not zero!");
        vm.stopPrank();
    }


    // Test 5: liquidator who liquidates and makes the position healthy by repaying all debt ends up with LTV of 0 (no debt at all)
    function test_e_liquidate_make_healthy_zero_debt_safetybuffer() public noGasMetering {
        test_e_setupLiquidationFromSafetyBufferChange(twyneLiqLTV);
        // Verify all asset balances before liquidation process
        uint256 eulerCurrentDebt = alice_collateral_vault.maxRepay();
        assertApproxEqRel(eulerCurrentDebt, BORROW_USD_AMOUNT, 1e12, "Euler current debt is wrong"); // original debt was BORROW_USD_AMOUNT
        // Verify that liquidator has no collateral vault shares and no intermediate vault debt before the liquidation
        assertEq(alice_collateral_vault.balanceOf(liquidator), 0, "Liquidator should have zero collateral vault shares 1");
        assertEq(eeWETH_intermediate_vault.debtOf(liquidator), 0, "Liquidator should have zero intermediate vault debt 1");

        // Avoid liquidation cooloff
        vm.warp(block.timestamp + 12);

        // Verify that the internal borrow from the intermediate vault cannot be liquidated currently
        vm.startPrank(liquidator);

        (uint256 repay, uint256 yield) = eeWETH_intermediate_vault.checkLiquidation(liquidator, address(alice_collateral_vault), address(alice_collateral_vault));
        if (repay != 0 || yield != 0) {
            // either repay or yield is NOT zero, means internal borrow can be liquidated
            console2.log("Repay or yield is not zero!", repay);
        }

        // Use the checkLiquidation() function to verify that the position can be liquidated
        bool canLiq = alice_collateral_vault.canLiquidate();
        assertTrue(canLiq, "Vault should be unhealthy, but cannot be liquidated!");

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_collateral_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);

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

        items[2] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.withdraw, (maxWithdraw - 1, alice))
        });

        // liquidator didn't withdraw fully to satisfy invariants
        vm.expectRevert(Errors.E_AccountLiquidity.selector);
        evc.batch(items);

        items[2].data = abi.encodeCall(alice_collateral_vault.withdraw, (maxWithdraw, alice));
        evc.batch(items);

        // confirm vault ownership changed to liquidator
        assertEq(alice_collateral_vault.borrower(), liquidator, "Wrong collateral vault owner after liquidation");

        // confirm no Euler external borrow debt remains
        uint256 externalCurrentDebt = alice_collateral_vault.maxRepay();
        assertEq(externalCurrentDebt, 0, "Debt to Euler is not zero!");
        // Verify that Alice holds no collateral vault shares and no intermediate vault debt
        assertEq(alice_collateral_vault.maxRelease(), 0, "Alice intermediate vault debt not zero");

        // now collateral vault is empty
        assertEq(IERC20(eulerWETH).balanceOf(address(alice_collateral_vault)), 0, "Incorrect eulerWETH balance remaining in vault");

        vm.stopPrank();
    }

    // Test 6: liquidator who liquidates worthless collateral doesn't need to repay anything (what is the reasoning for adding code to this case? Maybe for memecoins?)
    // TODO not sure how to handle this case, because if collateral value is insufficient, liquidating means you have to supply some collateral to make it healthy
    function test_e_liquidate_worthless_collateral_safetybuffer() public noGasMetering {
        test_e_setupLiquidationFromSafetyBufferChange(twyneLiqLTV);

        // make the collateral value worthless
        address eulerRouter = IEVault(eulerWETH).oracle();
        vm.startPrank(EulerRouter(eulerRouter).governor());
        EulerRouter(eulerRouter).govSetConfig(WETH, USD, address(mockOracle));
        vm.stopPrank();
        vm.startPrank(admin);
        // set WETH price in USD
        mockOracle.setPrice(WETH, USD, 0);
        vm.stopPrank();

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

        // engn33r did not expect that the liquidator has to call enableCollateral() and enableController() for the EVK vault being liquidated
        // but in hindsight this makes sense because the liquidator is taking over the borrower's position
        // so the liquidator should call the same functions that the borrower does before borrowing
        // evc.enableCollateral(backupLiquidator, address(alice_collateral_vault));
        // evc.enableController(backupLiquidator, address(eeWETH_intermediate_vault));

        vm.stopPrank();
    }

    // Test 8: what happens if the Twyne reserved assets borrow becomes liquidatable on the intermediate vault before the Twyne liquidation is triggered?
    // We have disabled EVK vault liquidation (BridgeHookTarget is called on EVK liquidation which reverts).
    function test_e_liquidate_bad_evk_debt_safetybuffer() public noGasMetering {
        // Set max twyneLiqLTV value
        twyneLiqLTV = twyneVaultManager.maxTwyneLTVs(eulerWETH);
        test_e_setupLiquidationFromSafetyBufferChange(twyneLiqLTV);

        // lower the liquidation LTV on the EVK vault to below the current borrow LTV to make it instantly liquidatable
        vm.startPrank(address(twyneVaultManager.owner()));
        twyneVaultManager.setLTV(eeWETH_intermediate_vault, address(alice_collateral_vault), 0.1e3, 0.15e3, 0);
        vm.stopPrank();

        // Confirm that Twyne collateral vault can be liquidated
        assertTrue(alice_collateral_vault.canLiquidate(), "Vault should be unhealthy but it cannot be liquidated!");

        // setLiquidationCoolOffTime(1) is called when intermediate vault is created, so warp forward by 1 block timestamp
        vm.warp(block.timestamp + 12);

        (uint256 collateralValue, uint256 liabilityValue) =
            eeWETH_intermediate_vault.accountLiquidity(address(alice_collateral_vault), true);
        if (BORROW_ETH_AMOUNT != 0) {
            assertGt(liabilityValue, collateralValue, "liability is not greater than collateral, EVK liquidation is not possible");
        }

        // Confirm that the intermediate vault's liquidation of the Twyne vault is possible
        // checkLiquidate() returns (0, 0) if the account is healthy (no liquidation possible)
        (uint256 maxRepay, uint256 maxYield) = eeWETH_intermediate_vault.checkLiquidation(liquidator, address(alice_collateral_vault), address(alice_collateral_vault));
        assertGt(maxRepay, 0, "maxRepay is zero!");
        assertGt(maxYield, 0, "maxYield is zero!");

        vm.deal(liquidator, 10 ether);
        deal(address(USDC), liquidator, 10e20);
        dealEToken(eulerWETH, liquidator, 10 * COLLATERAL_AMOUNT);

        IEVC(eeWETH_intermediate_vault.EVC()).enableController(address(this), address(eeWETH_intermediate_vault));
        IEVC(eeWETH_intermediate_vault.EVC()).enableCollateral(address(this), address(alice_collateral_vault));

        // first: liquidate() call on the intermediate vault reverts due to custom Twyne hook
        vm.expectRevert(TwyneErrors.NotExternallyLiquidated.selector);
        eeWETH_intermediate_vault.liquidate(address(alice_collateral_vault), address(alice_collateral_vault), type(uint256).max, 0);

        // second: try evc batch call, observe same revert
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
        assertGt(alice_collateral_vault.maxRelease(), 0, "EVK debt after EVK liq should be non-zero");
    }

    // Test F1: liquidation reverts when borrower position is healthy
    function test_e_liquidate_fails_healthy_cant_liquidate_safetybuffer() public noGasMetering {
        test_e_setupLiquidationFromSafetyBufferChange(twyneLiqLTV);

        vm.startPrank(alice);
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint).max);
        alice_collateral_vault.repay(BORROW_USD_AMOUNT/2);
        vm.stopPrank();

        // move the chain to current timestamp and block + 1 days (not the +365 days of normal liquidation flow)
        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 12);

        bool canLiq = alice_collateral_vault.canLiquidate();
        assertFalse(canLiq, "Vault should be healthy but it can be liquidated!");
        vm.startPrank(liquidator);
        // try to liquidate, but it will revert
        vm.expectRevert(TwyneErrors.HealthyNotLiquidatable.selector);
        alice_collateral_vault.liquidate();
        vm.stopPrank();
    }


    // Test F2: if liquidator attempts to repay with more than maxRepay, liquidate call reverts
    function test_e_liquidate_fails_excess_repay_safetybuffer() public noGasMetering {
        test_e_setupLiquidationFromSafetyBufferChange(twyneLiqLTV);


        // Check vault owner changes before/after liquidation happens
        assertEq(alice_collateral_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(liquidator);

        vm.expectRevert(TwyneErrors.VaultStatusLiquidatable.selector);
        alice_collateral_vault.liquidate();

        vm.stopPrank();
    }

    // Test F3: liquidator who liquidates and makes the position healthy cannot be liquidated immediately
    // This test case is covered by previous test cases

    // Test F3.1: liquidator who liquidates and doesn't handle the debt but tries to withdraw collateral should not be able to (subcase of above, no need to test)

    // Test F4: borrower who has LTV at the liquidation threshold cannot be liquidated (LTV must be worse than threshold)
    function test_e_liquidate_fails_at_threshold_safetybuffer() public noGasMetering {
        test_e_setupLiquidationFromSafetyBufferChange(twyneLiqLTV);

        // reverse the liquidation condition
        vm.startPrank(admin);
        twyneVaultManager.setExternalLiqBuffer(eulerWETH, externalLiqBufferInitial);
        vm.stopPrank();

        vm.startPrank(alice);
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint256).max);
        alice_collateral_vault.repay(2);
        alice_collateral_vault.borrow(1, alice);
        vm.stopPrank();

        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.HealthyNotLiquidatable.selector);
        alice_collateral_vault.liquidate();
        vm.stopPrank();
    }

    // Test F5: self-liquidation should revert
    function test_e_liquidate_fails_self_liquidate_safetybuffer() public noGasMetering {
        test_e_setupLiquidationFromSafetyBufferChange(twyneLiqLTV);

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
    // 8. what happens if the Twyne reserved assets borrow becomes liquidatable on the intermediate vault before the Twyne liquidation is triggered?
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
    function test_e_liquidate_without_making_healthy_externalLTV() public noGasMetering {
        test_e_setupLiquidationFromExternalLTVChange(twyneLiqLTV);

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_collateral_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.VaultStatusLiquidatable.selector);
        alice_collateral_vault.liquidate();
        vm.stopPrank();
    }

    // Test 2: liquidator who liquidates and makes the position healthy with some extra collateral cannot get liquidated by someone else (and has expected LTV). Verify original borrower LTV is zero
    function test_e_liquidate_make_healthy_more_collateral_externalLTV() public noGasMetering {
        test_e_setupLiquidationFromExternalLTVChange(twyneLiqLTV);

        dealEToken(eulerWETH, liquidator, 10 * COLLATERAL_AMOUNT);

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

        evc.batch(items);

        // confirm vault owner is liquidator
        assertEq(alice_collateral_vault.borrower(), liquidator, "Wrong collateral vault owner after liquidation");
        assertEq(collateralVaultFactory.getCollateralVaults(liquidator)[1], address(alice_collateral_vault));
        assertEq(collateralVaultFactory.getCollateralVaults(alice)[0], address(alice_collateral_vault));
        // confirm vault can NOT be liquidated now that there is more collateral
        // This tests scenario F3
        assertFalse(alice_collateral_vault.canLiquidate(), "Vault should be healthy but it can be liquidated!");

        vm.stopPrank();
    }

    // Test 3: liquidator who liquidates and makes the position healthy by repaying some debt cannot get liquidated by someone else (and has expected LTV). Verify original borrower LTV is zero
    function test_e_liquidate_make_healthy_reduce_debt_externalLTV() public noGasMetering {
        test_e_setupLiquidationFromExternalLTVChange(twyneLiqLTV);

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

        vm.stopPrank();

        // alice can't withdraw from collateral vault now
        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_collateral_vault.withdraw(1, alice);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_collateral_vault.withdraw(1, liquidator);
        vm.stopPrank();
    }

    // Test 4: liquidator who liquidates and makes the position healthy by repaying Aave debt ends up with LTV of 0 to Euler (no vUSDC debt)
    function test_e_liquidate_make_healthy_zero_euler_debt_externalLTV() public noGasMetering {
        test_e_setupLiquidationFromExternalLTVChange(twyneLiqLTV);
        // Verify all asset balances before liquidation process
        assertApproxEqRel(
            alice_collateral_vault.maxRelease(),
            BORROW_ETH_AMOUNT,
            1e14,
            "EVK debt not correct amount before liquidation"
        );
        uint256 eulerCurrentDebt = alice_collateral_vault.maxRepay();
        assertApproxEqRel(eulerCurrentDebt, BORROW_USD_AMOUNT, 1e12, "Euler current debt is wrong"); // original debt was BORROW_USD_AMOUNT
        // Verify that liquidator has no collateral vault shares and no intermediate vault debt before the liquidation
        assertEq(alice_collateral_vault.balanceOf(liquidator), 0, "Liquidator should have zero collateral vault shares 1");
        assertEq(eeWETH_intermediate_vault.debtOf(liquidator), 0, "Liquidator should have zero intermediate vault debt 1");

        // Avoid liquidation cooloff
        vm.warp(block.timestamp + 12);

        // Verify that the internal borrow from the intermediate vault cannot be liquidated currently
        vm.startPrank(liquidator);

        (uint256 repay, uint256 yield) = eeWETH_intermediate_vault.checkLiquidation(liquidator, address(alice_collateral_vault), address(alice_collateral_vault));
        if (repay != 0 || yield != 0) {
            // either repay or yield is NOT zero, means internal borrow can be liquidated
            console2.log("Repay or yield is not zero!", repay);
        }

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

        // confirm no Euler debt remains
        eulerCurrentDebt = alice_collateral_vault.maxRepay();
        assertEq(eulerCurrentDebt, 0, "Debt to Euler is not zero!");
        vm.stopPrank();
    }


    // Test 5: liquidator who liquidates and makes the position healthy by repaying all debt ends up with LTV of 0 (no debt at all)
    function test_e_liquidate_make_healthy_zero_debt_externalLTV() public noGasMetering {
        test_e_setupLiquidationFromExternalLTVChange(twyneLiqLTV);
        // Verify all asset balances before liquidation process
        // Verify that Alice holds collateral vault shares and intermediate vault debt
        assertApproxEqRel(alice_collateral_vault.maxRelease(), BORROW_ETH_AMOUNT, 1e14, "EVK debt not correct amount before liquidation");
        uint256 eulerCurrentDebt = alice_collateral_vault.maxRepay();
        assertApproxEqRel(eulerCurrentDebt, BORROW_USD_AMOUNT, 1e12, "Euler current debt is wrong"); // original debt was BORROW_USD_AMOUNT
        // Verify that liquidator has no collateral vault shares and no intermediate vault debt before the liquidation
        assertEq(alice_collateral_vault.balanceOf(liquidator), 0, "Liquidator should have zero collateral vault shares 1");
        assertEq(eeWETH_intermediate_vault.debtOf(liquidator), 0, "Liquidator should have zero intermediate vault debt 1");

        // Avoid liquidation cooloff
        vm.warp(block.timestamp + 12);

        // Verify that the internal borrow from the intermediate vault cannot be liquidated currently
        vm.startPrank(liquidator);

        (uint256 repay, uint256 yield) = eeWETH_intermediate_vault.checkLiquidation(liquidator, address(alice_collateral_vault), address(alice_collateral_vault));
        if (repay != 0 || yield != 0) {
            // either repay or yield is NOT zero, means internal borrow can be liquidated
            console2.log("Repay or yield is not zero!", repay);
        }

        // Use the checkLiquidation() function to verify that the position can be liquidated
        bool canLiq = alice_collateral_vault.canLiquidate();
        assertTrue(canLiq, "Vault should be unhealthy, but cannot be liquidated!");

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_collateral_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);

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

        items[2] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.withdraw, (maxWithdraw - 1, alice))
        });

        // liquidator didn't withdraw fully to satisfy invariants
        vm.expectRevert(Errors.E_AccountLiquidity.selector);
        evc.batch(items);

        items[2].data = abi.encodeCall(alice_collateral_vault.withdraw, (maxWithdraw, alice));
        evc.batch(items);

        // confirm vault ownership changed to liquidator
        assertEq(alice_collateral_vault.borrower(), liquidator, "Wrong collateral vault owner after liquidation");

        // confirm no Euler external borrow debt remains
        uint256 externalCurrentDebt = alice_collateral_vault.maxRepay();
        assertEq(externalCurrentDebt, 0, "Debt to Euler is not zero!");
        // Verify that Alice holds no collateral vault shares and no intermediate vault debt
        assertEq(alice_collateral_vault.maxRelease(), 0, "Alice intermediate vault debt not zero");

        // now collateral vault is empty
        assertEq(IERC20(eulerWETH).balanceOf(address(alice_collateral_vault)), 0, "Incorrect eulerWETH balance remaining in vault");

        vm.stopPrank();
    }

    // Test 6: liquidator who liquidates worthless collateral doesn't need to repay anything (what is the reasoning for adding code to this case? Maybe for memecoins?)
    // TODO not sure how to handle this case, because if collateral value is insufficient, liquidating means you have to supply some collateral to make it healthy
    function test_e_liquidate_worthless_collateral_externalLTV() public noGasMetering {
        test_e_setupLiquidationFromExternalLTVChange(twyneLiqLTV);

        // make the collateral value worthless
        address eulerRouter = IEVault(eulerWETH).oracle();
        vm.startPrank(EulerRouter(eulerRouter).governor());
        EulerRouter(eulerRouter).govSetConfig(WETH, USD, address(mockOracle));
        vm.stopPrank();
        vm.startPrank(admin);
        // set WETH price in USD
        mockOracle.setPrice(WETH, USD, 0);
        vm.stopPrank();

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

        // engn33r did not expect that the liquidator has to call enableCollateral() and enableController() for the EVK vault being liquidated
        // but in hindsight this makes sense because the liquidator is taking over the borrower's position
        // so the liquidator should call the same functions that the borrower does before borrowing
        // evc.enableCollateral(backupLiquidator, address(alice_collateral_vault));
        // evc.enableController(backupLiquidator, address(eeWETH_intermediate_vault));

        vm.stopPrank();
    }

    // Test 8: what happens if the Twyne reserved assets borrow becomes liquidatable on the intermediate vault before the Twyne liquidation is triggered?
    // We have disabled EVK vault liquidation (BridgeHookTarget is called on EVK liquidation which reverts).
    function test_e_liquidate_bad_evk_debt_externalLTV() public noGasMetering {
        test_e_setupLiquidationFromExternalLTVChange(twyneLiqLTV);

        // lower the liquidation LTV on the EVK vault to below the current borrow LTV to make it instantly liquidatable
        vm.startPrank(address(twyneVaultManager.owner()));
        twyneVaultManager.setLTV(eeWETH_intermediate_vault, address(alice_collateral_vault), 0.1e3, 0.15e3, 0);
        vm.stopPrank();

        // Confirm that Twyne collateral vault can be liquidated
        assertTrue(alice_collateral_vault.canLiquidate(), "Vault should be unhealthy but it cannot be liquidated!");

        // setLiquidationCoolOffTime(1) is called when intermediate vault is created, so warp forward by 1 block timestamp
        vm.warp(block.timestamp + 12);

        (uint256 collateralValue, uint256 liabilityValue) =
            eeWETH_intermediate_vault.accountLiquidity(address(alice_collateral_vault), true);
        if (BORROW_ETH_AMOUNT != 0) {
            assertGt(liabilityValue, collateralValue, "liability is not greater than collateral, EVK liquidation is not possible");
        }

        // Confirm that the intermediate vault's liquidation of the Twyne vault is possible
        // checkLiquidate() returns (0, 0) if the account is healthy (no liquidation possible)
        (uint256 maxRepay, uint256 maxYield) = eeWETH_intermediate_vault.checkLiquidation(liquidator, address(alice_collateral_vault), address(alice_collateral_vault));
        assertGt(maxRepay, 0, "maxRepay is zero!");
        assertGt(maxYield, 0, "maxYield is zero!");

        vm.deal(liquidator, 10 ether);
        deal(address(USDC), liquidator, 10e20);
        dealEToken(eulerWETH, liquidator, 10 * COLLATERAL_AMOUNT);

        IEVC(eeWETH_intermediate_vault.EVC()).enableController(address(this), address(eeWETH_intermediate_vault));
        IEVC(eeWETH_intermediate_vault.EVC()).enableCollateral(address(this), address(alice_collateral_vault));

        // first: liquidate() call on the intermediate vault reverts due to custom Twyne hook
        vm.expectRevert(TwyneErrors.NotExternallyLiquidated.selector);
        eeWETH_intermediate_vault.liquidate(address(alice_collateral_vault), address(alice_collateral_vault), type(uint256).max, 0);

        // second: try evc batch call, observe same revert
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
        assertGt(alice_collateral_vault.maxRelease(), 0, "EVK debt after EVK liq should be non-zero");
    }

    // Test F1: liquidation reverts when borrower position is healthy
    function test_e_liquidate_fails_healthy_cant_liquidate_externalLTV() public noGasMetering {
        test_e_setupLiquidationFromExternalLTVChange(twyneLiqLTV);

        vm.startPrank(alice);
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint).max);
        alice_collateral_vault.repay(BORROW_USD_AMOUNT/2);
        vm.stopPrank();

        // move the chain to current timestamp and block + 1 days (not the +365 days of normal liquidation flow)
        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 12);

        bool canLiq = alice_collateral_vault.canLiquidate();
        assertFalse(canLiq, "Vault should be healthy but it can be liquidated!");
        vm.startPrank(liquidator);
        // try to liquidate, but it will revert
        vm.expectRevert(TwyneErrors.HealthyNotLiquidatable.selector);
        alice_collateral_vault.liquidate();
        vm.stopPrank();
    }


    // Test F2: if liquidator attempts to repay with more than maxRepay, liquidate call reverts
    function test_e_liquidate_fails_excess_repay_externalLTV() public noGasMetering {
        test_e_setupLiquidationFromExternalLTVChange(twyneLiqLTV);


        // Check vault owner changes before/after liquidation happens
        assertEq(alice_collateral_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(liquidator);

        vm.expectRevert(TwyneErrors.VaultStatusLiquidatable.selector);
        alice_collateral_vault.liquidate();

        vm.stopPrank();
    }

    // Test F3: liquidator who liquidates and makes the position healthy cannot be liquidated immediately
    // This test case is covered by previous test cases

    // Test F3.1: liquidator who liquidates and doesn't handle the debt but tries to withdraw collateral should not be able to (subcase of above, no need to test)

    // Test F4: borrower who has LTV at the liquidation threshold cannot be liquidated (LTV must be worse than threshold)
    function test_e_liquidate_fails_at_threshold_externalLTV() public noGasMetering {
        test_e_setupLiquidationFromExternalLTVChange(twyneLiqLTV);

        // go back to the starting time
        vm.warp(block.timestamp - 2);

        // reverse the accrual of excess interest
        vm.startPrank(IEVault(eulerUSDC).governorAdmin());
        if (block.chainid == 1) {
            IEVault(eulerUSDC).setLTV(eulerWETH, 0.83e4, 0.85e4, 0);
        } else if (block.chainid == 8453) {
            IEVault(eulerUSDC).setLTV(eulerWETH, 0.85e4, 0.87e4, 0);
        }
        vm.stopPrank();

        vm.startPrank(alice);
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint256).max);
        alice_collateral_vault.repay(1);
        alice_collateral_vault.borrow(1, alice);
        vm.expectRevert();
        alice_collateral_vault.borrow(1, alice);
        vm.stopPrank();

        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.HealthyNotLiquidatable.selector);
        alice_collateral_vault.liquidate();
        // Warp forward few seconds and confirm that this vault was on the edge of liquidation
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 10);
        // assertTrue(alice_collateral_vault.canLiquidate()); // TODO uncomment this line
        vm.stopPrank();
    }

    // Test F5: self-liquidation should revert
    function test_e_liquidate_fails_self_liquidate_externalLTV() public noGasMetering {
        test_e_setupLiquidationFromExternalLTVChange(twyneLiqLTV);

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
