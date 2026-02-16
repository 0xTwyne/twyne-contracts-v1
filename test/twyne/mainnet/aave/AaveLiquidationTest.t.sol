// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {AaveTestBase, AaveV3CollateralVault, IAaveV3Pool, IAaveV3AToken, console2, BridgeHookTarget} from "./AaveTestBase.t.sol";
import "euler-vault-kit/EVault/shared/types/Types.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {CrossAdapter} from "euler-price-oracle/src/adapter/CrossAdapter.sol";
import {IPriceOracle} from "euler-price-oracle/src/interfaces/IPriceOracle.sol";
import {Errors as OracleErrors} from "euler-price-oracle/src/lib/Errors.sol";
import {EulerCollateralVault} from "src/twyne/EulerCollateralVault.sol";
import {IAaveV3ATokenWrapper} from "src/interfaces/IAaveV3ATokenWrapper.sol";
import {Errors} from "euler-vault-kit/EVault/shared/Errors.sol";
import {Events} from "euler-vault-kit/EVault/shared/Events.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";
import {VaultType} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {MockAaveFeed} from "test/mocks/MockAaveFeed.sol";
import {Errors as AaveErrors} from "aave-v3/protocol/libraries/helpers/Errors.sol";

interface IWETH is IERC20 {
    receive() external payable;
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

contract AaveLiquidationTest is AaveTestBase {
    uint256 BORROW_ETH_AMOUNT;

    function setUp() public override {
        super.setUp();
        vm.startPrank(admin);
        //twyneVaultManager.setExternalLiqBuffer(address(aWETHWrapper), 0.98e4);
        twyneVaultManager.setExternalLiqBuffer(address(aWETHWrapper), 1e4);
	    vm.stopPrank();
    }

    function test_aave_preLiquidationSetup(uint16 liqLTV) public {
        // copy logic from checkLiqLTV
        address collateral = address(aWETHWrapper);
        uint16 minLTV = uint16(getLiqLTV(collateral));
        uint16 extLiqBuffer = twyneVaultManager.externalLiqBuffers(collateral);
        vm.assume(uint(minLTV) * uint(extLiqBuffer) <= uint256(liqLTV) * MAXFACTOR);
        vm.assume(liqLTV <= twyneVaultManager.maxTwyneLTVs(collateral));
        // Bob deposits into eeWETH_intermediate_vault to earn boosted yield
        vm.startPrank(bob);
        IERC20(collateral).approve(address(aaveEthVault), type(uint256).max);
        aaveEthVault.deposit(CREDIT_LP_AMOUNT, bob);
        vm.stopPrank();

        // repeat but for Collateral non-EVK vault
        vm.startPrank(alice);
        alice_aave_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _asset: collateral,
                _targetVault: aavePool,
                _liqLTV: liqLTV,
                _targetAsset: USDC
            })
        );

        vm.label(address(alice_aave_vault), "alice_aave_vault");

        // Alice deposit the aWETHWrapper token into the collateral vault
        IERC20(collateral).approve(address(alice_aave_vault), type(uint256).max);

        BORROW_ETH_AMOUNT = getReservedAssetsForAave(COLLATERAL_AMOUNT, alice_aave_vault);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        // reserve assets from intermediate vault
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.deposit, (COLLATERAL_AMOUNT))
        });

        evc.batch(items);


        // Use the first liquidation condition in _canLiquidate

        vm.startPrank(address(alice_aave_vault));

        IAaveV3Pool(aavePool).setUserUseReserveAsCollateral(WETH, true);

        vm.stopPrank();


        (,,uint availableBorrowsBase,,,) = IAaveV3Pool(aavePool).getUserAccountData(address(alice_aave_vault));
        availableBorrowsBase = availableBorrowsBase/1e2;
        console2.log("Available borrow base init: ", availableBorrowsBase);
        uint256 borrowAmountUSD1 = uint256(twyneVaultManager.externalLiqBuffers(alice_aave_vault.asset())) * availableBorrowsBase / MAXFACTOR;

        uint USDCPrice = getAavePrice(USDC); // returns a value times 1e10

        // Use the second liquidation condition in _canLiquidate
        uint borrowAmountUSD2 = availableBorrowsBase;

        if (borrowAmountUSD1 < borrowAmountUSD2) {
            BORROW_USD_AMOUNT = borrowAmountUSD1 * 1e8 / USDCPrice;
        } else {
            BORROW_USD_AMOUNT = borrowAmountUSD2 * 1e8 / USDCPrice;
        }

        console2.log("Amount 1: ", borrowAmountUSD1);
        console2.log("Amount 2: ", borrowAmountUSD2);
        // Assume the user max borrows to arrive at the extreme limit of what is possible without liquidation
        vm.startPrank(alice);

        // BORROW_USD_AMOUNT-10 is used to avoid insufficient collateral issue which cause borrowing to fail
	    alice_aave_vault.borrow(BORROW_USD_AMOUNT - 10, alice);

        (,,availableBorrowsBase,,,) = IAaveV3Pool(aavePool).getUserAccountData(address(alice_aave_vault));
        uint amountToBorrow = 1;
        availableBorrowsBase = availableBorrowsBase/1e2;
        if (availableBorrowsBase > 0){
            amountToBorrow = Math.mulDiv(availableBorrowsBase+1, 1e8, USDCPrice, Math.Rounding.Ceil);
            if(amountToBorrow == 0){
                amountToBorrow = 1;
            }
        }
        // if (borrowAmountUSD1 < borrowAmountUSD2) { // this case happens when safety buffer is low (below 0.975)
        //     vm.expectRevert(TwyneErrors.VaultStatusLiquidatable.selector);
        // } else { // this case happens when safety buffer is very high (near 1)
        vm.expectRevert(AaveErrors.CollateralCannotCoverNewBorrow.selector);

        alice_aave_vault.borrow(amountToBorrow, alice);

        vm.stopPrank();
    }

    function test_aave_postSetupChecks() public noGasMetering {
        test_aave_preLiquidationSetup(twyneLiqLTV);

        // Confirm balances are as expected
        assertEq(alice_aave_vault.totalAssetsDepositedOrReserved() - alice_aave_vault.maxRelease(), COLLATERAL_AMOUNT);
        assertEq(alice_aave_vault.balanceOf(address(alice_aave_vault)), COLLATERAL_AMOUNT);

        // borrower holds Twyne/EVK debt
        assertEq(
            alice_aave_vault.maxRelease(),
            BORROW_ETH_AMOUNT,
            "EVK debt not correct amount"
        );
        assertEq(aaveEthVault.totalAssets(), CREDIT_LP_AMOUNT);

        // collateral vault holds borrowed aWETHWrapper from intermediate vault
        assertApproxEqRel(
            IERC20(address(aWETHWrapper)).balanceOf(address(alice_aave_vault)),
            COLLATERAL_AMOUNT + BORROW_ETH_AMOUNT,
            1e5,
            "Collateral vault not holding correct aWETHWrapper balance"
        );
        // intermediate vault holds credit LP's aWETHWrapper minus the borrowed amount
        assertApproxEqRel(
            IERC20(address(aWETHWrapper)).balanceOf(address(aaveEthVault)),
            CREDIT_LP_AMOUNT - BORROW_ETH_AMOUNT,
            1e5,
            "Intermediate vault not holding correct aWETHWrapper balance"
        );

        (uint256 collateralValue, uint256 liabilityValue) = aaveEthVault.accountLiquidity(address(alice_aave_vault), true);
        EulerRouter aaveOracleRouter = EulerRouter(aaveEthVault.oracle());
        uint256 aWrapWETH_quote = aaveOracleRouter.getQuote(1e28, address(aWETHWrapper), USD);
        assertApproxEqRel(
            collateralValue,
            COLLATERAL_AMOUNT * aWrapWETH_quote/1e28,
            1e5,
            "Wrong intermediate vault collateralValue before time warp"
        ); // this is deposited collateral * liquidation LTV
        assertApproxEqRel(
            liabilityValue,
            BORROW_ETH_AMOUNT * aWrapWETH_quote/1e28,
            1e5,
            "Wrong intermediate vault liabilityValue before time warp"
        );
    }

    // // There are different ways to trigger a liquidation on Twyne:
    // // 1. Interest accrual over time
    // // 2. A price decrease of the collateral asset
    // // 3. A price increase of the borrowed asset
    // // 4. Safety buffer change on Twyne
    // // 5. Liquidation LTV change in the underlying protocol
    // // 6. User changing their liquidation LTV (actually this reverts, but confirm the revert case)

    // This accrues interest only for low safety buffers, otherwise it triggers liquidation by price movement of mock oracle
    function test_aave_setupLiquidationAccrueInterest(uint16 liqLTV) public noGasMetering {
        test_aave_preLiquidationSetup(liqLTV);
        address collateralAsset = address(aWETHWrapper);
        // Put the vault into a liquidatable state
        if (twyneVaultManager.externalLiqBuffers(collateralAsset) < 0.975e4) {
            // If safety buffer is not very high, can warp forward a small amount to achieve a liquidatable position
            vm.warp(block.timestamp + 600); // accrue interest
        } else {
            // If safety buffer is very high, set price with mockOracle
            address feed = getAaveOracleFeed(WETH);
            uint initPrice = uint(MockAaveFeed(feed).latestAnswer());

            MockAaveFeed mockFeed = new MockAaveFeed();

            vm.etch(feed, address(mockFeed).code);
            mockFeed = MockAaveFeed(feed);
            mockFeed.setPrice(initPrice*95/100);
        }

        // Verify debt to intermediate vault increased IF there was a non-zero BORROW_ETH_AMOUNT amount reserved
        (, uint liabilityValue) = aaveEthVault.accountLiquidity(address(alice_aave_vault), true);
        if (BORROW_ETH_AMOUNT != 0) {
            assertGt(liabilityValue, BORROW_ETH_AMOUNT, "alice debt to intermediate vault did not increase");
        }

        // confirm vault can be liquidated now that there is more collateral
        assertTrue(alice_aave_vault.canLiquidate(), "Vault should be unhealthy but it cannot be liquidated!");

        vm.startPrank(liquidator);
        IERC20(USDC).approve(address(alice_aave_vault), type(uint256).max);
        IERC20(address(aWETHWrapper)).approve(address(alice_aave_vault), type(uint256).max);

        vm.stopPrank();
    }

    function test_aave_setupLiquidationFromSafetyBufferChange(uint16 liqLTV) public noGasMetering {
        test_aave_preLiquidationSetup(liqLTV);

        // To put the vault into a liquidatable state, don't warp, but alter the safety buffer
        vm.startPrank(admin);
        twyneVaultManager.setExternalLiqBuffer(address(aWETHWrapper), 0.8e4);
        vm.stopPrank();

        // Verify debt to intermediate vault increased
        (, uint liabilityValue) = aaveEthVault.accountLiquidity(address(alice_aave_vault), true);
        if (BORROW_ETH_AMOUNT != 0) {
            assertGt(liabilityValue, BORROW_ETH_AMOUNT, "alice debt to intermediate vault did not increase");
        }

        // confirm vault can be liquidated now that there is more collateral
        assertTrue(alice_aave_vault.canLiquidate(), "Vault should be unhealthy but it cannot be liquidated!");

        vm.startPrank(liquidator);
        IERC20(USDC).approve(address(alice_aave_vault), type(uint256).max);
        IERC20(address(aWETHWrapper)).approve(address(alice_aave_vault), type(uint256).max);

        vm.stopPrank();
    }


    function test_aave_setupLiquidationFromExternalLTVChange(uint16 liqLTV) public noGasMetering {
        test_aave_preLiquidationSetup(liqLTV);

        // To put the vault into a liquidatable state, don't warp, but lower the external LTV
        setAaveLTV(address(aWETHWrapper), 0.6e4);

        // to ensure vaults are out of liquidation cool off period
        vm.warp(block.timestamp + 2);

        // Verify debt to intermediate vault increased
        (, uint liabilityValue) = aaveEthVault.accountLiquidity(address(alice_aave_vault), true);
        if (BORROW_ETH_AMOUNT != 0) {
            assertGt(liabilityValue, BORROW_ETH_AMOUNT, "alice debt to intermediate vault did not increase");
        }

        // confirm vault can be liquidated now that there is more collateral
        assertTrue(alice_aave_vault.canLiquidate(), "Vault should be unhealthy but it cannot be liquidated!");

        // Confirm external liquidation is possible from Aave USDC perspective


        (, uint totalDebtBase, ,, ,) = IAaveV3Pool(aavePool).getUserAccountData(address(alice_aave_vault));
        assertGt(totalDebtBase, 0, "Vault cannot be externally liquidated");

        vm.startPrank(liquidator);
        IERC20(USDC).approve(address(alice_aave_vault), type(uint256).max);
        IERC20(address(aWETHWrapper)).approve(address(alice_aave_vault), type(uint256).max);

        vm.stopPrank();
    }


    function test_aave_cannotSetupLiquidationFromTwyneLTVChange() public noGasMetering {
        test_aave_preLiquidationSetup(twyneLiqLTV);

        // To put the vault into a liquidatable state, user sets a dumb LTV
        // But it encounters an error
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_aave_vault.setTwyneLiqLTV(0.95e4);
        vm.stopPrank();
    }

    function test_aave_setupCompleteExternalLiquidation() public noGasMetering {
        test_aave_preLiquidationSetup(twyneLiqLTV);
        address collateralAsset = address(aWETHWrapper);
        // Borrow using the exact amounts of an older test setup
        vm.startPrank(alice);
        IERC20(collateralAsset).approve(address(alice_aave_vault), type(uint).max);
        IERC20(USDC).approve(address(alice_aave_vault), type(uint).max);
        alice_aave_vault.deposit(5 ether);
        alice_aave_vault.borrow(6983982500, alice);
        vm.stopPrank();

                // Put the vault into a liquidatable state
        if (twyneVaultManager.externalLiqBuffers(collateralAsset) < 0.975e4) {
            // If safety buffer is not very high, can warp forward a small amount to achieve a liquidatable position
            vm.warp(block.timestamp + 600); // accrue interest
        } else {
            // If safety buffer is very high, set price with mockOracle
            address feed = getAaveOracleFeed(WETH);
            uint initPrice = uint(MockAaveFeed(feed).latestAnswer());

            MockAaveFeed mockFeed = new MockAaveFeed();

            vm.etch(feed, address(mockFeed).code);
            mockFeed = MockAaveFeed(feed);
            mockFeed.setPrice(initPrice*3/10);
        }
    }

    function test_aave_handleCompleteExternalLiquidation() public noGasMetering {
        test_aave_setupCompleteExternalLiquidation();
        address collateralAsset = address(aWETHWrapper);

        // Verify debt to intermediate vault increased
        (, uint liabilityValue) = aaveEthVault.accountLiquidity(address(alice_aave_vault), true);
        if (BORROW_ETH_AMOUNT != 0) {
            assertGt(liabilityValue, BORROW_ETH_AMOUNT, "alice debt to intermediate vault did not increase");
        }

        // confirm vault can be liquidated now that there is more collateral
        assertTrue(alice_aave_vault.canLiquidate(), "Vault should be unhealthy but it cannot be liquidated!");

        vm.warp(block.timestamp + 1);

        // Ensure liquidator has enough aWETHWrapper to be a valid liquidator
        dealWrapperToken(collateralAsset, liquidator, 100 ether);

        vm.startPrank(liquidator);
        IERC20(USDC).approve(aavePool, type(uint).max);
        IEVC(alice_aave_vault.EVC()).enableCollateral(liquidator, collateralAsset);

        assertFalse(alice_aave_vault.isExternallyLiquidated());
        // liquidate alice_aave_vault via Aave USDC
        assertGt(alice_aave_vault.maxRepay(), 0);

        // This decreases the entire debt and collateral amount to 0.
        // Hence, this test only tests a subset of possibilities.
        IAaveV3Pool(aavePool).liquidationCall({
            collateralAsset: WETH,
            debtAsset: USDC,
            borrower: address(alice_aave_vault),
            debtToCover: type(uint).max,
            receiveAToken: false
        });
        vm.stopPrank();

        assertTrue(alice_aave_vault.isExternallyLiquidated(), "collateral vault was not externally liquidated");

        // Since the external liquidation reduced the debt and its collateral amount to 0,
        // there is no collateral that is collateralizing the intermediate vault debt.
        assertEq(alice_aave_vault.maxRepay(), 0, "collateral vault debt to euler USDC vault is not zero");
        assertEq(alice_aave_vault.balanceOf(address(alice_aave_vault)), 0, "wrapper WETH in collateral vault is not zero");
        assertGt(alice_aave_vault.maxRelease(), 0, "collateral vault maxRelease is zero");
        uint initialMaxRelease = alice_aave_vault.maxRelease();

        // Check that you can't do operations on collateral vault
        // after external liquidation.
        vm.startPrank(alice);

        vm.expectRevert(TwyneErrors.ExternallyLiquidated.selector);
        alice_aave_vault.liquidate();

        vm.expectRevert(TwyneErrors.ExternallyLiquidated.selector);
        alice_aave_vault.rebalance();

        vm.expectRevert(TwyneErrors.ExternallyLiquidated.selector);
        alice_aave_vault.deposit(1);

        vm.expectRevert(TwyneErrors.ExternallyLiquidated.selector);
        alice_aave_vault.depositUnderlying(1);

        vm.expectRevert(TwyneErrors.ExternallyLiquidated.selector);
        alice_aave_vault.withdraw(1, alice);

        vm.expectRevert(TwyneErrors.ExternallyLiquidated.selector);
        alice_aave_vault.redeemUnderlying(1, alice);

        vm.expectRevert(TwyneErrors.ExternallyLiquidated.selector);
        alice_aave_vault.skim();

        vm.stopPrank();

        address newLiquidator = makeAddr("newLiquidator");
        vm.startPrank(newLiquidator);

        evc.enableController(newLiquidator, address(alice_aave_vault.intermediateVault()));

        // Calling just handleExternalLiquidation should fail.
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            onBehalfOfAccount: newLiquidator,
            targetContract: address(alice_aave_vault),
            value: 0,
            data: abi.encodeCall(alice_aave_vault.handleExternalLiquidation, ())
        });

        vm.expectRevert(TwyneErrors.BadDebtNotSettled.selector);
        evc.batch(items);

        // Need to call liquidate() on intermediate vault in the same batch as handleExternalLiquidation() to settle accounting
        IEVC.BatchItem[] memory items1 = new IEVC.BatchItem[](2);
        items1[0] = items[0];
        items1[1] = IEVC.BatchItem({
            onBehalfOfAccount: newLiquidator,
            targetContract: address(alice_aave_vault.intermediateVault()),
            value: 0,
            data: abi.encodeCall(aaveEthVault.liquidate, (address(alice_aave_vault), address(alice_aave_vault), 0, 0))
        });

        vm.expectEmit(false, false, true, true);
        emit Events.DebtSocialized(address(alice_aave_vault), initialMaxRelease);
        evc.batch(items1);

        // Confirm collateral vault is empty
        assertEq(IERC20(collateralAsset).balanceOf(address(alice_aave_vault)), 0, "collateral vault is not empty");

        vm.stopPrank();

        assertEq(alice_aave_vault.balanceOf(address(alice_aave_vault)), 0, "collateral vault is not empty");
        assertEq(alice_aave_vault.borrower(), address(0));
        assertEq(IERC20(IAaveV3ATokenWrapper(collateralAsset).aToken()).balanceOf(address(alice_aave_vault)), 0, "AToken balance is non zero");
        assertEq(alice_aave_vault.balanceOf(address(alice_aave_vault)), 0);
        assertEq(alice_aave_vault.maxRelease(), 0);

        // Confirm that the collateral vault is no longer usable
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_aave_vault.deposit(1);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_aave_vault.depositUnderlying(1);
    }

    function test_aave_handleExternalLiquidationWithZeroMaxRelease() public noGasMetering {
        // Calculate minimum LTV so the collateral vault mimics a position on the underlying protocol
        address collateralAsset = address(aWETHWrapper);
        uint16 minimumLTV = uint16(getLiqLTV(collateralAsset) * uint(twyneVaultManager.externalLiqBuffers(collateralAsset)) / MAXFACTOR);
        test_aave_preLiquidationSetup(minimumLTV);

        // Put the vault into a liquidatable state
        if (twyneVaultManager.externalLiqBuffers(collateralAsset) < 0.975e4) {
            // If safety buffer is not very high, can warp forward a small amount to achieve a liquidatable position
            vm.warp(block.timestamp + 600); // accrue interest
        } else {
            // If safety buffer is very high, set price with mockOracle
            address feed = getAaveOracleFeed(WETH);
            uint initPrice = uint(MockAaveFeed(feed).latestAnswer());

            MockAaveFeed mockFeed = new MockAaveFeed();

            vm.etch(feed, address(mockFeed).code);
            mockFeed = MockAaveFeed(feed);
            mockFeed.setPrice(initPrice*95/100);
        }

        // confirm vault can be liquidated now that there is more collateral
        assertTrue(alice_aave_vault.canLiquidate(), "Vault should be unhealthy but it cannot be liquidated!");

        vm.warp(block.timestamp + 1);

        // Ensure liquidator has enough aWETHWrapper to be a valid liquidator
        dealWrapperToken(collateralAsset, liquidator, 100 ether);

        vm.startPrank(liquidator);
        IERC20(USDC).approve(aavePool, type(uint).max);
        IEVC(alice_aave_vault.EVC()).enableCollateral(liquidator, collateralAsset);

        // Assert initial state, the reverse will be true after external liquidation
        assertFalse(alice_aave_vault.isExternallyLiquidated());
        assertGt(IERC20(collateralAsset).balanceOf(address(alice_aave_vault)), 0, "before: aave WETH wrapper in collateral vault is not zero");

        // liquidate alice_aave_vault via Aave USDC
        assertGt(alice_aave_vault.maxRepay(), 0);
        uint debtPending = alice_aave_vault.maxRepay();
        // This decreases the entire debt to 0, but leaves some collateral.

        IAaveV3Pool(aavePool).liquidationCall({
            collateralAsset: WETH,
            debtAsset: USDC,
            borrower: address(alice_aave_vault),
            debtToCover: type(uint).max,
            receiveAToken: false
        });

        vm.stopPrank();

        assertTrue(alice_aave_vault.isExternallyLiquidated(), "collateral vault was not externally liquidated");

        assertApproxEqAbs(alice_aave_vault.maxRepay(), debtPending/2, 2, "collateral vault debt to aave USDC vault is not halved");
        assertGt(IERC20(collateralAsset).balanceOf(address(alice_aave_vault)), 0, "after: aave WETH in collateral vault is not zero");
        assertEq(alice_aave_vault.maxRelease(), 0, "collateral vault maxRelease is zero");

        address newLiquidator = makeAddr("newLiquidator");
        vm.startPrank(newLiquidator);

        evc.enableController(newLiquidator, address(alice_aave_vault.intermediateVault()));

        // Only borrower can call this function since reserved credit is 0.
        vm.expectRevert(TwyneErrors.NoLiquidationForZeroReserve.selector);
        alice_aave_vault.handleExternalLiquidation();
        vm.stopPrank();

        vm.startPrank(alice);
        IERC20(USDC).approve(address(alice_aave_vault), type(uint).max);
        alice_aave_vault.handleExternalLiquidation();
        vm.stopPrank();

        // Confirm collateral vault is empty
        assertEq(IERC20(collateralAsset).balanceOf(address(alice_aave_vault)), 0, "collateral vault is not empty");
        assertEq(IERC20(IAaveV3ATokenWrapper(collateralAsset).aToken()).balanceOf(address(alice_aave_vault)), 0, "AToken balance is non zero");
        assertEq(alice_aave_vault.borrower(), address(0));
        assertEq(alice_aave_vault.balanceOf(address(alice_aave_vault)), 0);
        assertEq(alice_aave_vault.maxRelease(), 0);
    }

    function test_aave_handlePartialExternalLiquidation() public noGasMetering {
        address collateralAsset = address(aWETHWrapper);
        test_aave_setupLiquidationFromExternalLTVChange(twyneLiqLTV);
        vm.warp(block.timestamp + 1);

        // Ensure liquidator has enough aWETHWrapper to be a valid liquidator
        dealWrapperToken(collateralAsset, liquidator, 100 ether);

        vm.startPrank(liquidator);
        IERC20(USDC).approve(aavePool, type(uint).max);
        IEVC(alice_aave_vault.EVC()).enableCollateral(liquidator, collateralAsset);

        IEVC(alice_aave_vault.EVC()).enableCollateral(liquidator, address(alice_aave_vault));
        IEVC(alice_aave_vault.EVC()).enableController(liquidator, address(alice_aave_vault.intermediateVault()));

        assertFalse(alice_aave_vault.isExternallyLiquidated());
        // liquidate alice_aave_vault via Aave USDC
        assertGt(alice_aave_vault.maxRepay(), 0);

        // Cache the amount to repay to fully settle the liquidation
        uint maxrepay = alice_aave_vault.maxRepay();


        IAaveV3Pool(aavePool).liquidationCall({
            collateralAsset: WETH,
            debtAsset: USDC,
            borrower: address(alice_aave_vault),
            debtToCover: maxrepay,
            receiveAToken: false
        });


        assertTrue(alice_aave_vault.isExternallyLiquidated());

        // Need to call handleExternalLiquidation, and then in the same batch, liquidate on intermediate vault
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            onBehalfOfAccount: liquidator,
            targetContract: address(alice_aave_vault),
            value: 0,
            data: abi.encodeCall(alice_aave_vault.handleExternalLiquidation, ())
        });
        items[1] = IEVC.BatchItem({
            onBehalfOfAccount: liquidator,
            targetContract: address(alice_aave_vault.intermediateVault()),
            value: 0,
            data: abi.encodeCall(aaveEthVault.liquidate, (address(alice_aave_vault), address(alice_aave_vault), 0, 0))
        });

        evc.batch(items);

        vm.stopPrank();

        // Check that you can't do operations on collateral vault
        // after external liquidation.
        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_aave_vault.withdraw(1, alice);
        vm.stopPrank();

        assertEq(alice_aave_vault.borrower(), address(0), "borrower NEQ address(0)");
        assertEq(IERC20(IAaveV3ATokenWrapper(collateralAsset).aToken()).balanceOf(address(alice_aave_vault)), 0, "AToken balance is non zero");
        assertEq(alice_aave_vault.balanceOf(address(alice_aave_vault)), 0, "balanceOf alice NEQ 0");
        assertEq(alice_aave_vault.maxRelease(), 0, "maxRelease NEQ 0");
    }

    function test_aave_handleExternalLiquidationOnUnhealthyAavePosition() public noGasMetering {
        test_aave_setupCompleteExternalLiquidation();
        address collateralAsset = address(aWETHWrapper);
        // confirm vault can be liquidated now that there is more collateral
        assertTrue(alice_aave_vault.canLiquidate(), "Vault should be unhealthy but it cannot be liquidated!");

        vm.warp(block.timestamp + 1);

        // Ensure liquidator has enough aWETHWrapper to be a valid liquidator
        dealWrapperToken(collateralAsset, liquidator, 100 ether);

        vm.startPrank(liquidator);
        IERC20(USDC).approve(aavePool, type(uint).max);
        IEVC(alice_aave_vault.EVC()).enableCollateral(liquidator, collateralAsset);
        IEVC(alice_aave_vault.EVC()).enableController(liquidator, address(alice_aave_vault.intermediateVault()));

        assertFalse(alice_aave_vault.isExternallyLiquidated());
        // liquidate alice_aave_vault via Aave USDC
        assertGt(alice_aave_vault.maxRepay(), 0);

        IAaveV3Pool(aavePool).liquidationCall({
            collateralAsset: WETH,
            debtAsset: USDC,
            borrower: address(alice_aave_vault),
            debtToCover: 2,
            receiveAToken: false
        });


        vm.stopPrank();

        assertTrue(alice_aave_vault.isExternallyLiquidated(), "collateral vault was not externally liquidated");
        (,,,,,uint hf) = IAaveV3Pool(aavePool).getUserAccountData(address(alice_aave_vault));
        assertTrue(hf < 1e18, "Aave position should be unhealthy");

        address newLiquidator = makeAddr("newLiquidator");
        vm.startPrank(newLiquidator);

        evc.enableController(newLiquidator, address(alice_aave_vault.intermediateVault()));

        vm.expectRevert(TwyneErrors.ExternalPositionUnhealthy.selector);
        alice_aave_vault.handleExternalLiquidation();
    }

    function test_aave_externalLiquidationDetectionConsidersCollateralAirdrop() public noGasMetering {
        test_aave_setupLiquidationFromExternalLTVChange(twyneLiqLTV);
        vm.warp(block.timestamp + 1);
        address collateralAsset = address(aWETHWrapper);
        // Ensure liquidator has enough aWETHWrapper to be a valid liquidator
        dealWrapperToken(collateralAsset, liquidator, 100 ether);

        vm.startPrank(liquidator);
        IERC20(USDC).approve(aavePool, type(uint).max);
        IEVC(alice_aave_vault.EVC()).enableCollateral(liquidator, collateralAsset);

        assertFalse(alice_aave_vault.isExternallyLiquidated());
        // liquidate alice_aave_vault via Aave USDC
        assertGt(alice_aave_vault.maxRepay(), 0);

        // Cache the amount to repay to fully settle the liquidation
        uint maxrepay = alice_aave_vault.maxRepay();

        // Test for non-zero debt and collateral amount after external liquidation.

        IAaveV3Pool(aavePool).liquidationCall({
            collateralAsset: WETH,
            debtAsset: USDC,
            borrower: address(alice_aave_vault),
            debtToCover: maxrepay/2,
            receiveAToken: false
        });


        assertTrue(alice_aave_vault.isExternallyLiquidated());

        address aToken = IAaveV3ATokenWrapper(collateralAsset).aToken();

        uint256 aTokenScaledBalance = IAaveV3AToken(aToken).scaledBalanceOf(address(alice_aave_vault));

        uint collateralToDeposit = alice_aave_vault.totalAssetsDepositedOrReserved() - aTokenScaledBalance;

        IAaveV3ATokenWrapper(collateralAsset).redeemATokens(collateralToDeposit - 1, address(alice_aave_vault), liquidator);
        assertTrue(alice_aave_vault.isExternallyLiquidated());
        IAaveV3ATokenWrapper(collateralAsset).redeemATokens(1, address(alice_aave_vault), liquidator);
        assertFalse(alice_aave_vault.isExternallyLiquidated());
        IAaveV3ATokenWrapper(collateralAsset).redeemATokens(1, address(alice_aave_vault), liquidator);
        assertFalse(alice_aave_vault.isExternallyLiquidated());
        vm.stopPrank();

        // Check that Aavesees the correct collateral amount

        uint256 newScaledBalance = IAaveV3AToken(aToken).scaledBalanceOf(address(alice_aave_vault));
        assertGt(
            newScaledBalance,
            aTokenScaledBalance,
            "Aave collateral amount doesn't consider airdrop"
        );
    }

    // Edge case where a batch attempts to force an external liquidation
    // This should not be possible
    function test_aave_verifyBatchCannotForceExtLiquidation() public noGasMetering {
        test_aave_setupLiquidationFromExternalLTVChange(twyneLiqLTV);

        // to ensure vaults are out of liquidation cool off period
        vm.warp(block.timestamp + 2);

        vm.startPrank(alice);

        // Confirm Twyne liquidation can happen
        assertTrue(alice_aave_vault.canLiquidate(), "Vault cannot be liquidated!");
        // Confirm external liquidation can happen
        uint maxrepay = alice_aave_vault.maxRepay();
        assertGt(maxrepay, 0, "Vault cannot be externally liquidated");
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](4);

        IERC20(USDC).approve(address(evc), type(uint).max);
        items[0] = IEVC.BatchItem({
            targetContract: USDC,
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(IERC20(USDC).transferFrom, (alice, address(evc), maxrepay))
        });

        items[1] = IEVC.BatchItem({
            targetContract: USDC,
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(IERC20(USDC).approve, (aavePool, type(uint).max))
        });

        items[2] = IEVC.BatchItem({
            targetContract: aavePool,
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(IAaveV3Pool(aavePool).liquidationCall, (WETH, USDC, address(alice_aave_vault), maxrepay, false))
        });

        items[3] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.handleExternalLiquidation, ())
        });

        // cannot make a position unhealthy and liquidate in the same tx.
        // this reverts in items[2] tx.
        evc.batch(items);
        vm.stopPrank();
    }

    // There are 3 cases where a liquidation can be triggered:
    // Case 1: Debt accumulation only from Aave triggers liquidation
    // Case 2: Debt accumulation only from internal intermediate vault borrow triggers liquidation
    // Case 3: Debt accumulation combined from BOTH Aave and internal intermediate vault borrow triggers liquidation (this should be the "normal" case for users)

    // passing tests to write
    // 1. liquidator who liquidates and doesn't make the position healthy can immediately get liquidated by someone else. Verify original borrower LTV and first liquidator LTV is zero
    // 2. liquidator who liquidates and makes the position healthy with some extra collateral cannot get liquidated by someone else (and has expected LTV). Verify original borrower LTV is zero
    // 3. liquidator who liquidates and makes the position healthy by repaying some debt cannot get liquidated by someone else (and has expected LTV). Verify original borrower LTV is zero
    // 4. liquidator who liquidates and makes the position healthy by repaying ALL debt ends up with LTV of 0 (no debt)
    // 5: liquidator who liquidates and makes the position healthy by repaying all debt ends up with LTV of 0 (no debt at all)
    // 6. liquidator who liquidates worthless collateral doesn't need to repay anything (what is the reasoning for adding code to this case? Maybe for memecoins?)
    // 7. test liquidation case when position is unhealthy on Aave (can test extreme bad debt case, with very low or zero collateral value)
    // 8. what happens if the Twyne reserved assets borrow becomes liquidatable on the intermediate vault before the Twyne liquidation is triggered?
    //   NOTE: the above case cannot happen if intermediate vault liquidation LTV = 1
    // 9. test tokens with other decimals
    // 10. test bad debt socialization (or lack thereof)
    // 11. Test liquidation when governance changes LTV (this simulates a response to Aave parameters changing. Test LTV ramping if implemented)
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
    function test_aave_liquidate_without_making_healthy_accrue_interest() public noGasMetering {
        test_aave_setupLiquidationAccrueInterest(twyneLiqLTV);

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.VaultStatusLiquidatable.selector);
        alice_aave_vault.liquidate();
        vm.stopPrank();
    }

    // Test 2: liquidator who liquidates and makes the position healthy with some extra collateral cannot get liquidated by someone else (and has expected LTV). Verify original borrower LTV is zero
    function test_aave_liquidate_make_healthy_more_collateral_accrue_interest() public noGasMetering {
        test_aave_setupLiquidationAccrueInterest(twyneLiqLTV);

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(liquidator);

        // first, assume that the liquidator is already a Twyne user
        // This confirms that a user with an existing vault can ALSO liquidate other vaults
        AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _asset: address(aWETHWrapper),
                _targetVault: aavePool,
                _liqLTV: twyneLiqLTV,
                _targetAsset: USDC
            })
        );

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // repay debt in Aave
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.liquidate, ())
        });

        // and now add collateral to make position more healthy
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.deposit, (COLLATERAL_AMOUNT))
        });

        evc.batch(items);

        // confirm vault owner is liquidator
        assertEq(alice_aave_vault.borrower(), liquidator, "Wrong collateral vault owner after liquidation");
        assertEq(collateralVaultFactory.getCollateralVaults(liquidator)[1], address(alice_aave_vault));
        assertEq(collateralVaultFactory.getCollateralVaults(alice)[0], address(alice_aave_vault));
        // confirm vault can NOT be liquidated now that there is more collateral
        // This tests scenario F3
        assertFalse(alice_aave_vault.canLiquidate(), "Vault should be healthy but it can be liquidated!");

        vm.stopPrank();
    }

    // Test 3: liquidator who liquidates and makes the position healthy by repaying some debt cannot get liquidated by someone else (and has expected LTV). Verify original borrower LTV is zero
    function test_aave_liquidate_make_healthy_reduce_debt_accrue_interest() public noGasMetering {
        test_aave_setupLiquidationAccrueInterest(twyneLiqLTV);

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(liquidator);

        // Save Aave xternal debt amount
        uint256 previousAaveDebt = alice_aave_vault.maxRepay();

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // repay debt in Aave
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.liquidate, ())
        });

        // and now add collateral to make position more healthy
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.repay, (BORROW_USD_AMOUNT/2))
        });

        evc.batch(items);
        // confirm vault owner is liquidator
        assertEq(alice_aave_vault.borrower(), liquidator, "Wrong collateral vault owner after liquidation");
        // confirm vault can NOT be liquidated now that there is more collateral
        bool canLiq = alice_aave_vault.canLiquidate();
        assertFalse(canLiq, "Vault should be healthy but it can be liquidated!");
        // confirm vault debt to Aave is lower than before
        uint256 latestAaveDebt = alice_aave_vault.maxRepay();
        assertLt(latestAaveDebt, previousAaveDebt, "Aave current debt is wrong");

        // This tests scenario F3
        canLiq = alice_aave_vault.canLiquidate();
        assertFalse(canLiq, "Vault should be healthy but it can be liquidated!");

        // intermediate vault debt is unchanged
        assertApproxEqRel(
            alice_aave_vault.maxRelease(),
            BORROW_ETH_AMOUNT,
            1e15,
            "EVK debt not correct amount after liquidation"
        );

        vm.stopPrank();

        // alice can't withdraw from collateral vault now
        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_aave_vault.withdraw(1, alice);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_aave_vault.withdraw(1, liquidator);
        vm.stopPrank();
    }

    // Test 4: liquidator who liquidates and makes the position healthy by repaying Aave debt ends up with LTV of 0 to Aave (no USDC debt)
    function test_aave_liquidate_make_healthy_zero_aave_debt_accrue_interest() public noGasMetering {
        test_aave_setupLiquidationAccrueInterest(twyneLiqLTV);
        // Verify all asset balances before liquidation process
        assertApproxEqRel(
            alice_aave_vault.maxRelease(),
            BORROW_ETH_AMOUNT,
            1e14,
            "Aave debt not correct amount before liquidation"
        );
        uint256 aaveCurrentDebt = alice_aave_vault.maxRepay();
        assertApproxEqRel(aaveCurrentDebt, BORROW_USD_AMOUNT, 1e12, "Aave current debt is wrong"); // original debt was BORROW_USD_AMOUNT
        // Verify that liquidator has no collateral vault shares and no intermediate vault debt before the liquidation
        assertEq(alice_aave_vault.balanceOf(liquidator), 0, "Liquidator should have zero collateral vault shares 1");
        assertEq(aaveEthVault.debtOf(liquidator), 0, "Liquidator should have zero intermediate vault debt 1");

        // Avoid liquidation cooloff
        vm.warp(block.timestamp + 12);

        // Verify that the internal borrow from the intermediate vault cannot be liquidated currently
        vm.startPrank(liquidator);

        (uint256 repay, uint256 yield) = aaveEthVault.checkLiquidation(liquidator, address(alice_aave_vault), address(alice_aave_vault));
        if (repay != 0 || yield != 0) {
            // either repay or yield is NOT zero, means internal borrow can be liquidated
            console2.log("Repay or yield is not zero!", repay);
        }

        // Use the checkLiquidation() function to verify that the position can be liquidated
        bool canLiq = alice_aave_vault.canLiquidate();
        assertTrue(canLiq, "Vault should be unhealthy, but cannot be liquidated!");

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // repay debt in Euler
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.liquidate, ())
        });

        // and now add collateral to make position more healthy
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.repay, (alice_aave_vault.maxRepay()))
        });

        evc.batch(items);

        // confirm vault ownership changed to liquidator
        assertEq(alice_aave_vault.borrower(), liquidator, "Wrong collateral vault owner after liquidation");

        // intermediate vault debt is unchanged
        assertApproxEqRel(
            alice_aave_vault.maxRelease(),
            BORROW_ETH_AMOUNT,
            1e15,
            "EVK debt not correct amount after liquidation"
        );

        // confirm no Aave debt remains
        aaveCurrentDebt = alice_aave_vault.maxRepay();
        assertEq(aaveCurrentDebt, 0, "Debt to Aave is not zero!");

        vm.stopPrank();
    }


    // Test 5: liquidator who liquidates and makes the position healthy by repaying all debt ends up with LTV of 0 (no debt at all)
    function test_aave_liquidate_make_healthy_zero_debt_accrue_interest() public noGasMetering {
        test_aave_setupLiquidationAccrueInterest(twyneLiqLTV);
        // Verify all asset balances before liquidation process
        // Verify that Alice holds collateral vault shares and intermediate vault debt
        assertApproxEqRel(alice_aave_vault.maxRelease(), BORROW_ETH_AMOUNT, 1e14, "EVK debt not correct amount before liquidation");
        uint256 aaveCurrentDebt = alice_aave_vault.maxRepay();
        assertApproxEqRel(aaveCurrentDebt, BORROW_USD_AMOUNT, 1e12, "Aave current debt is wrong"); // original debt was BORROW_USD_AMOUNT
        // Verify that liquidator has no collateral vault shares and no intermediate vault debt before the liquidation
        assertEq(alice_aave_vault.balanceOf(liquidator), 0, "Liquidator should have zero collateral vault shares 1");
        assertEq(aaveEthVault.debtOf(liquidator), 0, "Liquidator should have zero intermediate vault debt 1");

        // Avoid liquidation cooloff
        vm.warp(block.timestamp + 12);

        // Verify that the internal borrow from the intermediate vault cannot be liquidated currently
        vm.startPrank(liquidator);

        (uint256 repay, uint256 yield) = aaveEthVault.checkLiquidation(liquidator, address(alice_aave_vault), address(alice_aave_vault));
        if (repay != 0 || yield != 0) {
            // either repay or yield is NOT zero, means internal borrow can be liquidated
            console2.log("Repay or yield is not zero!", repay);
        }

        // Use the checkLiquidation() function to verify that the position can be liquidated
        bool canLiq = alice_aave_vault.canLiquidate();
        assertTrue(canLiq, "Vault should be unhealthy, but cannot be liquidated!");

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);

        uint maxWithdraw = alice_aave_vault.totalAssetsDepositedOrReserved() - alice_aave_vault.maxRelease();
        // repay debt in Euler
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.liquidate, ())
        });

        // and now add collateral to make position more healthy
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.repay, (alice_aave_vault.maxRepay()))
        });

        items[2] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.withdraw, (maxWithdraw - 2, alice)) // when we add back credit risk manager, change -2 to -1.
        });


        evc.batch(items);

        // make full utilisation of intermediate vault so that intereset accrued increase intermediate vault debt
        uint amountToWithdraw = aWETHWrapper.balanceOf(address(aaveEthVault));
        vm.startPrank(bob);
        aaveEthVault.withdraw(amountToWithdraw, bob, bob);
        vm.stopPrank();
        assertEq(aWETHWrapper.balanceOf(address(aaveEthVault)), 0, "Not at full utilisation");

        assertEq(aaveEthVault.debtOf(address(alice_aave_vault)), 1, "Intermediate vault debt is not correct");
        assertEq(alice_aave_vault.totalAssetsDepositedOrReserved(), 3, "Total assets deposited or reserved is not correct");
        assertEq(alice_aave_vault.balanceOf(address(alice_aave_vault)), 2, "Balance is not greater than 0");

        vm.warp(block.timestamp + 1000 days);
        // Rebalance to make sure excess credit is released back to intermediate vault
        alice_aave_vault.rebalance();

        // confirm vault ownership changed to liquidator
        assertEq(alice_aave_vault.borrower(), liquidator, "Wrong collateral vault owner after liquidation");

        // confirm no Aave xternal borrow debt remains
        uint256 externalCurrentDebt = alice_aave_vault.maxRepay();
        assertEq(externalCurrentDebt, 0, "Debt to Aave is not zero!");
        // Verify that Alice holds no collateral vault shares and no intermediate vault debt
        assertEq(alice_aave_vault.maxRelease(), 0, "Alice intermediate vault debt not zero");

        // now collateral vault is empty
        assertEq(IERC20(address(aWETHWrapper)).balanceOf(address(alice_aave_vault)), 0, "Incorrect aweth wrapper balance remaining in vault");

        vm.stopPrank();
    }

    // Test 6: liquidator who liquidates worthless collateral doesn't need to repay anything
    // TODO not sure how to handle this case, because if collateral value is insufficient, liquidating means you have to supply some collateral to make it healthy
    function test_aave_liquidate_worthless_collateral_accrue_interest() public noGasMetering {
        test_aave_setupLiquidationAccrueInterest(twyneLiqLTV);
        address collateralAsset = address(aWETHWrapper);
        // skip this test with high safety buffers
        if (twyneVaultManager.externalLiqBuffers(collateralAsset) < 0.975e4) {
            // make the collateral value worthless

            // If safety buffer is very high, set price with mockOracle
            address feed = getAaveOracleFeed(WETH);

            MockAaveFeed mockFeed = new MockAaveFeed();

            vm.etch(feed, address(mockFeed).code);
            mockFeed = MockAaveFeed(feed);
            mockFeed.setPrice(1);

            // Check vault owner changes before/after liquidation happens
            assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
            vm.startPrank(liquidator);

            IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

            // repay debt in Euler
            items[0] = IEVC.BatchItem({
                targetContract: address(alice_aave_vault),
                onBehalfOfAccount: liquidator,
                value: 0,
                data: abi.encodeCall(alice_aave_vault.liquidate, ())
            });

            // and now add collateral to make position more healthy
            items[1] = IEVC.BatchItem({
                targetContract: address(alice_aave_vault),
                onBehalfOfAccount: liquidator,
                value: 0,
                data: abi.encodeCall(alice_aave_vault.repay, (alice_aave_vault.maxRepay()))
            });

            evc.batch(items);

            vm.stopPrank();

            assertEq(alice_aave_vault.borrower(), liquidator, "Wrong collateral vault owner after liquidation");

            // intermediate vault debt is unchanged
            assertApproxEqRel(
                alice_aave_vault.maxRelease(),
                BORROW_ETH_AMOUNT,
                1e15,
                "Aave debt not correct amount after liquidation"
            );

            vm.stopPrank();
        }
    }

    // Test 8: what happens if the Twyne reserved assets borrow becomes liquidatable on the intermediate vault before the Twyne liquidation is triggered?
    // We have disabled EVK vault liquidation (BridgeHookTarget is called on EVK liquidation which reverts).
    function test_aave_liquidate_bad_evk_debt_accrue_interest() public noGasMetering {
        // Set max twyneLiqLTV value
        address collateralAsset = address(aWETHWrapper);
        twyneLiqLTV = twyneVaultManager.maxTwyneLTVs(collateralAsset);
        test_aave_setupLiquidationAccrueInterest(twyneLiqLTV);

        // lower the liquidation LTV on the EVK vault to below the current borrow LTV to make it instantly liquidatable
        vm.startPrank(address(twyneVaultManager.owner()));
        twyneVaultManager.setLTV(aaveEthVault, address(alice_aave_vault), 0.1e3, 0.15e3, 0);
        vm.stopPrank();

        // Confirm that Twyne collateral vault can be liquidated
        assertTrue(alice_aave_vault.canLiquidate(), "Vault should be unhealthy but it cannot be liquidated!");

        // setLiquidationCoolOffTime(1) is called when intermediate vault is created, so warp forward by 1 block timestamp
        vm.warp(block.timestamp + 12);

        (uint256 collateralValue, uint256 liabilityValue) =
            aaveEthVault.accountLiquidity(address(alice_aave_vault), true);
        if (BORROW_ETH_AMOUNT != 0) {
            assertGt(liabilityValue, collateralValue, "liability is not greater than collateral, EVK liquidation is not possible");
        }

        // Confirm that the intermediate vault's liquidation of the Twyne vault is possible
        // checkLiquidate() returns (0, 0) if the account is healthy (no liquidation possible)
        (uint256 maxRepay, uint256 maxYield) = aaveEthVault.checkLiquidation(liquidator, address(alice_aave_vault), address(alice_aave_vault));
        assertGt(maxRepay, 0, "maxRepay is zero!");
        assertGt(maxYield, 0, "maxYield is zero!");

        vm.deal(liquidator, 10 ether);
        deal(address(USDC), liquidator, 10e20);
        dealWrapperToken(collateralAsset, liquidator, 10 * COLLATERAL_AMOUNT);

        IEVC(alice_aave_vault.EVC()).enableController(address(this), address(aaveEthVault));
        IEVC(alice_aave_vault.EVC()).enableCollateral(address(this), address(alice_aave_vault));

        // first: liquidate() call on the intermediate vault reverts due to custom Twyne hook
        vm.expectRevert(TwyneErrors.NotExternallyLiquidated.selector);
        aaveEthVault.liquidate(address(alice_aave_vault), address(alice_aave_vault), type(uint256).max, 0);

        // second: try evc batch call, observe same revert
        IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](1);
        batchItems[0] = IEVC.BatchItem({
            targetContract: address(aaveEthVault),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeCall(
                ILiquidation.liquidate,
                (address(alice_aave_vault), address(alice_aave_vault), type(uint256).max, 0)
            )
        });

        vm.expectRevert(TwyneErrors.NotExternallyLiquidated.selector);
        evc.batch(batchItems);
        assertGt(alice_aave_vault.maxRelease(), 0, "EVK debt after EVK liq should be non-zero");
    }

    // Test F1: liquidation reverts when borrower position is healthy
    function test_aave_liquidate_fails_healthy_cant_liquidate_accrue_interest() public noGasMetering {
        test_aave_setupLiquidationAccrueInterest(twyneLiqLTV);

        vm.startPrank(alice);
        IERC20(USDC).approve(address(alice_aave_vault), type(uint).max);
        alice_aave_vault.repay(BORROW_USD_AMOUNT/2);
        vm.stopPrank();

        // move the chain to current timestamp and block + 1 days (not the +365 days of normal liquidation flow)
        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 12);

        bool canLiq = alice_aave_vault.canLiquidate();
        assertFalse(canLiq, "Vault should be healthy but it can be liquidated!");
        vm.startPrank(liquidator);
        // try to liquidate, but it will revert
        vm.expectRevert(TwyneErrors.HealthyNotLiquidatable.selector);
        alice_aave_vault.liquidate();
        vm.stopPrank();
    }


    // Test F2: if liquidator attempts to repay with more than maxRepay, liquidate call reverts
    function test_aave_liquidate_fails_excess_repay_accrue_interest() public noGasMetering {
        test_aave_setupLiquidationAccrueInterest(twyneLiqLTV);


        // Check vault owner changes before/after liquidation happens
        assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(liquidator);

        vm.expectRevert(TwyneErrors.VaultStatusLiquidatable.selector);
        alice_aave_vault.liquidate();

        vm.stopPrank();
    }

    // // Test F3: liquidator who liquidates and makes the position healthy cannot be liquidated immediately
    // // This test case is covered by previous test cases

    // // Test F3.1: liquidator who liquidates and doesn't handle the debt but tries to withdraw collateral should not be able to (subcase of above, no need to test)

    // Test F4: borrower who has LTV at the liquidation threshold cannot be liquidated (LTV must be worse than threshold)
    function test_aave_liquidate_fails_at_threshold_accrue_interest() public noGasMetering {
        test_aave_setupLiquidationAccrueInterest(twyneLiqLTV);
        address collateralAsset = address(aWETHWrapper);
        // Skip this test with high safety buffers
        // Undo the process of putting the vault into a liquidatable state
        if (twyneVaultManager.externalLiqBuffers(collateralAsset) < 0.975e4) {
            // If safety buffer is not very high, can warp forward a small amount to achieve a liquidatable position
            vm.warp(block.timestamp - 600);  // reverse the accrual of 10 minutes of interest

            vm.startPrank(alice);
            IERC20(USDC).approve(address(alice_aave_vault), type(uint256).max);
            alice_aave_vault.repay(1);
            alice_aave_vault.borrow(1, alice);
            vm.expectRevert(TwyneErrors.VaultStatusLiquidatable.selector);
            alice_aave_vault.borrow(1, alice);
            vm.stopPrank();

            vm.startPrank(liquidator);
            vm.expectRevert(TwyneErrors.HealthyNotLiquidatable.selector);
            alice_aave_vault.liquidate();
            vm.stopPrank();
        }
    }

    // Test F5: self-liquidation should revert
    function test_aave_liquidate_fails_self_liquidate_accrue_interest() public noGasMetering {
        test_aave_setupLiquidationAccrueInterest(twyneLiqLTV);

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(alice);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // repay debt in Euler
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.liquidate, ())
        });

        // and now add collateral to make position more healthy
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.deposit, (COLLATERAL_AMOUNT))
        });

        // Expect SelfLiquidation() error
        vm.expectRevert(TwyneErrors.SelfLiquidation.selector);
        evc.batch(items);

        // confirm vault owner is still alice
        assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner after liquidation");

        vm.stopPrank();
    }

    // // There are 3 cases where a liquidation can be triggered:
    // // Case 1: Debt accumulation only from Aave triggers liquidation
    // // Case 2: Debt accumulation only from internal intermediate vault borrow triggers liquidation
    // // Case 3: Debt accumulation combined from BOTH Aave and internal intermediate vault borrow triggers liquidation (this should be the "normal" case for users)

    // // passing tests to write
    // // 1. liquidator who liquidates and doesn't make the position healthy can immediately get liquidated by someone else. Verify original borrower LTV and first liquidator LTV is zero
    // // 2. liquidator who liquidates and makes the position healthy with some extra collateral cannot get liquidated by someone else (and has expected LTV). Verify original borrower LTV is zero
    // // 3. liquidator who liquidates and makes the position healthy by repaying some debt cannot get liquidated by someone else (and has expected LTV). Verify original borrower LTV is zero
    // // 4. liquidator who liquidates and makes the position healthy by repaying ALL debt ends up with LTV of 0 (no debt)
    // // 5: liquidator who liquidates and makes the position healthy by repaying all debt ends up with LTV of 0 (no debt at all)
    // // 6. liquidator who liquidates worthless collateral doesn't need to repay anything (what is the reasoning for adding code to this case? Maybe for memecoins?)
    // // 7. test liquidation case when position is unhealthy on Aave (can test extreme bad debt case, with very low or zero collateral value)
    // // 8. what happens if the Twyne reserved assets borrow becomes liquidatable on the intermediate vault before the Twyne liquidation is triggered?
    // //   NOTE: the above case cannot happen if intermediate vault liquidation LTV = 1
    // // 9. test tokens with other decimals
    // // 10. test bad debt socialization (or lack thereof)
    // // 11. Test liquidation when governance changes LTV (this simulates a response to Aave parameters changing. Test LTV ramping if implemented)
    // // 12. Test liquidation flow using a flashloan (relevant for liquidation bot repo)

    // // failing tests to write
    // // F1. liquidation reverts when borrower position is healthy
    // // F2. if liquidator attempts to repay with more than maxRepay, liquidate call reverts
    // // F3. liquidator who liquidates and makes the position healthy cannot be liquidated immediately
    // // F3.1 liquidator who liquidates and doesn't handle the debt but tries to withdraw collateral should not be able to (subcase of above, no need to test)
    // // F4. borrower who has LTV at the liquidation threshold cannot be liquidated (LTV must be below threshold)
    // // F5. self-liquidation should revert
    // // F6. if vault is not set up yet (i.e. no price oracle), liquidation should not be possible
    // // F7. Test repaying aave twice in 1 block (or tx) to confirm this revert case need documenting
    // // F8. Test that governance cannot set liquidation LTV below borrowing LTV on Collateral vault
    // //
    // // TODO Questions
    // // if liquidator liquidates and position is not made healthy in the same block, should the liquidation revert?
    // // How to handle bad debt - socialize it or not?
    // // Do we want to set some cooloff like Euler, or does it not make sense?

    // Test 1: liquidator who liquidates and doesn't make the position healthy cannot liquidate.
    // Verify original borrower LTV and first liquidator LTV is zero
    function test_aave_liquidate_without_making_healthy_safetybuffer() public noGasMetering {
        test_aave_setupLiquidationFromSafetyBufferChange(twyneLiqLTV);

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.VaultStatusLiquidatable.selector);
        alice_aave_vault.liquidate();
        vm.stopPrank();
    }

    // Test 2: liquidator who liquidates and makes the position healthy with some extra collateral cannot get liquidated by someone else (and has expected LTV). Verify original borrower LTV is zero
    function test_aave_liquidate_make_healthy_more_collateral_safetybuffer() public noGasMetering {
        test_aave_setupLiquidationFromSafetyBufferChange(twyneLiqLTV);

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(liquidator);

        // first, assume that the liquidator is already a Twyne user
        // This confirms that a user with an existing vault can ALSO liquidate other vaults
        AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _asset: address(aWETHWrapper),
                _targetVault: aavePool,
                _liqLTV: twyneLiqLTV,
                _targetAsset: USDC
            })
        );

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // repay debt in Aave
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.liquidate, ())
        });

        // and now add collateral to make position more healthy
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.deposit, (COLLATERAL_AMOUNT))
        });

        evc.batch(items);

        // confirm vault owner is liquidator
        assertEq(alice_aave_vault.borrower(), liquidator, "Wrong collateral vault owner after liquidation");
        assertEq(collateralVaultFactory.getCollateralVaults(liquidator)[1], address(alice_aave_vault));
        assertEq(collateralVaultFactory.getCollateralVaults(alice)[0], address(alice_aave_vault));
        // confirm vault can NOT be liquidated now that there is more collateral
        // This tests scenario F3
        assertFalse(alice_aave_vault.canLiquidate(), "Vault should be healthy but it can be liquidated!");

        vm.stopPrank();
    }

    // Test 3: liquidator who liquidates and makes the position healthy by repaying some debt cannot get liquidated by someone else (and has expected LTV). Verify original borrower LTV is zero
    function test_aave_liquidate_make_healthy_reduce_debt_safetybuffer() public noGasMetering {
        test_aave_setupLiquidationFromSafetyBufferChange(twyneLiqLTV);

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(liquidator);

        // Save Aave external debt amount
        uint256 previousAaveDebt = alice_aave_vault.maxRepay();

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // repay debt in Aave
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.liquidate, ())
        });

        // and now add collateral to make position more healthy
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.repay, (BORROW_USD_AMOUNT/2))
        });

        evc.batch(items);
        // confirm vault owner is liquidator
        assertEq(alice_aave_vault.borrower(), liquidator, "Wrong collateral vault owner after liquidation");
        // confirm vault can NOT be liquidated now that there is more collateral
        bool canLiq = alice_aave_vault.canLiquidate();
        assertFalse(canLiq, "Vault should be healthy but it can be liquidated!");
        // confirm vault debt to Aave is lower than before
        uint256 latestAaveDebt = alice_aave_vault.maxRepay();
        assertLt(latestAaveDebt, previousAaveDebt, "Aave current debt is wrong");

        // This tests scenario F3
        canLiq = alice_aave_vault.canLiquidate();
        assertFalse(canLiq, "Vault should be healthy but it can be liquidated!");

        vm.stopPrank();

        // alice can't withdraw from collateral vault now
        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_aave_vault.withdraw(1, alice);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_aave_vault.withdraw(1, liquidator);
        vm.stopPrank();
    }

    // Test 4: liquidator who liquidates and makes the position healthy by repaying Aave debt ends up with LTV of 0 to Aave(no vUSDC debt)
    function test_aave_liquidate_make_healthy_zero_aave_debt_safetybuffer() public noGasMetering {
        test_aave_setupLiquidationFromSafetyBufferChange(twyneLiqLTV);
        // Verify all asset balances before liquidation process
        uint256 aaveCurrentDebt = alice_aave_vault.maxRepay();
        assertApproxEqRel(aaveCurrentDebt, BORROW_USD_AMOUNT, 1e12, "Aave current debt is wrong"); // original debt was BORROW_USD_AMOUNT
        // Verify that liquidator has no collateral vault shares and no intermediate vault debt before the liquidation
        assertEq(alice_aave_vault.balanceOf(liquidator), 0, "Liquidator should have zero collateral vault shares 1");
        assertEq(aaveEthVault.debtOf(liquidator), 0, "Liquidator should have zero intermediate vault debt 1");

        // Avoid liquidation cooloff
        vm.warp(block.timestamp + 12);

        // Verify that the internal borrow from the intermediate vault cannot be liquidated currently
        vm.startPrank(liquidator);

        (uint256 repay, uint256 yield) = aaveEthVault.checkLiquidation(liquidator, address(alice_aave_vault), address(alice_aave_vault));
        if (repay != 0 || yield != 0) {
            // either repay or yield is NOT zero, means internal borrow can be liquidated
            console2.log("Repay or yield is not zero!", repay);
        }

        // Use the checkLiquidation() function to verify that the position can be liquidated
        bool canLiq = alice_aave_vault.canLiquidate();
        assertTrue(canLiq, "Vault should be unhealthy, but cannot be liquidated!");

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // repay debt in Euler
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.liquidate, ())
        });

        // and now add collateral to make position more healthy
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.repay, (alice_aave_vault.maxRepay()))
        });

        evc.batch(items);

        // confirm vault ownership changed to liquidator
        assertEq(alice_aave_vault.borrower(), liquidator, "Wrong collateral vault owner after liquidation");

        // confirm no Aave debt remains
        aaveCurrentDebt = alice_aave_vault.maxRepay();
        assertEq(aaveCurrentDebt, 0, "Debt to Aave is not zero!");
        vm.stopPrank();
    }


    // Test 5: liquidator who liquidates and makes the position healthy by repaying all debt ends up with LTV of 0 (no debt at all)
    function test_aave_liquidate_make_healthy_zero_debt_safetybuffer() public noGasMetering {
        test_aave_setupLiquidationFromSafetyBufferChange(twyneLiqLTV);
        // Verify all asset balances before liquidation process
        uint256 aaveCurrentDebt = alice_aave_vault.maxRepay();
        assertApproxEqRel(aaveCurrentDebt, BORROW_USD_AMOUNT, 1e12, "Aave current debt is wrong"); // original debt was BORROW_USD_AMOUNT
        // Verify that liquidator has no collateral vault shares and no intermediate vault debt before the liquidation
        assertEq(alice_aave_vault.balanceOf(liquidator), 0, "Liquidator should have zero collateral vault shares 1");
        assertEq(aaveEthVault.debtOf(liquidator), 0, "Liquidator should have zero intermediate vault debt 1");

        // Avoid liquidation cooloff
        vm.warp(block.timestamp + 12);

        // Verify that the internal borrow from the intermediate vault cannot be liquidated currently
        vm.startPrank(liquidator);

        (uint256 repay, uint256 yield) = aaveEthVault.checkLiquidation(liquidator, address(alice_aave_vault), address(alice_aave_vault));
        if (repay != 0 || yield != 0) {
            // either repay or yield is NOT zero, means internal borrow can be liquidated
            console2.log("Repay or yield is not zero!", repay);
        }

        // Use the checkLiquidation() function to verify that the position can be liquidated
        bool canLiq = alice_aave_vault.canLiquidate();
        assertTrue(canLiq, "Vault should be unhealthy, but cannot be liquidated!");

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);

        uint maxWithdraw = alice_aave_vault.totalAssetsDepositedOrReserved() - alice_aave_vault.maxRelease();
        // repay debt in Euler
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.liquidate, ())
        });

        // and now add collateral to make position more healthy
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.repay, (alice_aave_vault.maxRepay()))
        });

        items[2] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.withdraw, (maxWithdraw, alice))
        });

        evc.batch(items);

        // confirm vault ownership changed to liquidator
        assertEq(alice_aave_vault.borrower(), liquidator, "Wrong collateral vault owner after liquidation");

        // confirm no Aave external borrow debt remains
        uint256 externalCurrentDebt = alice_aave_vault.maxRepay();
        assertEq(externalCurrentDebt, 0, "Debt to Aave is not zero!");
        // Verify that Alice holds no collateral vault shares and no intermediate vault debt
        assertEq(alice_aave_vault.maxRelease(), 0, "Alice intermediate vault debt not zero");

        // now collateral vault is empty
        assertEq(IERC20(address(aWETHWrapper)).balanceOf(address(alice_aave_vault)), 0, "Incorrect aWETHWrapper balance remaining in vault");

        vm.stopPrank();
    }

    // Test 6: liquidator who liquidates worthless collateral doesn't need to repay anything (what is the reasoning for adding code to this case? Maybe for memecoins?)
    // TODO not sure how to handle this case, because if collateral value is insufficient, liquidating means you have to supply some collateral to make it healthy
    function test_aave_liquidate_worthless_collateral_safetybuffer() public noGasMetering {
        test_aave_setupLiquidationFromSafetyBufferChange(twyneLiqLTV);
        // If safety buffer is very high, set price with mockOracle
        address feed = getAaveOracleFeed(WETH);

        MockAaveFeed mockFeed = new MockAaveFeed();

        vm.etch(feed, address(mockFeed).code);
        mockFeed = MockAaveFeed(feed);
        mockFeed.setPrice(1);

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(liquidator);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // repay debt in Euler
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.liquidate, ())
        });

        // and now add collateral to make position more healthy
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.repay, (alice_aave_vault.maxRepay()))
        });

        evc.batch(items);

        vm.stopPrank();

        assertEq(alice_aave_vault.borrower(), liquidator, "Wrong collateral vault owner after liquidation");

        vm.stopPrank();
    }

    // Test 8: what happens if the Twyne reserved assets borrow becomes liquidatable on the intermediate vault before the Twyne liquidation is triggered?
    // We have disabled EVK vault liquidation (BridgeHookTarget is called on EVK liquidation which reverts).
    function test_aave_liquidate_bad_evk_debt_safetybuffer() public noGasMetering {
        // Set max twyneLiqLTV value
        address collateralAsset = address(aWETHWrapper);
        twyneLiqLTV = twyneVaultManager.maxTwyneLTVs(collateralAsset);
        test_aave_setupLiquidationFromSafetyBufferChange(twyneLiqLTV);

        // lower the liquidation LTV on the EVK vault to below the current borrow LTV to make it instantly liquidatable
        vm.startPrank(address(twyneVaultManager.owner()));
        twyneVaultManager.setLTV(aaveEthVault, address(alice_aave_vault), 0.1e3, 0.15e3, 0);
        vm.stopPrank();

        // Confirm that Twyne collateral vault can be liquidated
        assertTrue(alice_aave_vault.canLiquidate(), "Vault should be unhealthy but it cannot be liquidated!");

        // setLiquidationCoolOffTime(1) is called when intermediate vault is created, so warp forward by 1 block timestamp
        vm.warp(block.timestamp + 12);

        (uint256 collateralValue, uint256 liabilityValue) =
            aaveEthVault.accountLiquidity(address(alice_aave_vault), true);
        if (BORROW_ETH_AMOUNT != 0) {
            assertGt(liabilityValue, collateralValue, "liability is not greater than collateral, EVK liquidation is not possible");
        }

        // Confirm that the intermediate vault's liquidation of the Twyne vault is possible
        // checkLiquidate() returns (0, 0) if the account is healthy (no liquidation possible)
        (uint256 maxRepay, uint256 maxYield) = aaveEthVault.checkLiquidation(liquidator, address(alice_aave_vault), address(alice_aave_vault));
        assertGt(maxRepay, 0, "maxRepay is zero!");
        assertGt(maxYield, 0, "maxYield is zero!");

        vm.deal(liquidator, 10 ether);
        deal(address(USDC), liquidator, 10e20);
        dealWrapperToken(collateralAsset, liquidator, 10 * COLLATERAL_AMOUNT);

        IEVC(aaveEthVault.EVC()).enableController(address(this), address(aaveEthVault));
        IEVC(aaveEthVault.EVC()).enableCollateral(address(this), address(alice_aave_vault));

        // first: liquidate() call on the intermediate vault reverts due to custom Twyne hook
        vm.expectRevert(TwyneErrors.NotExternallyLiquidated.selector);
        aaveEthVault.liquidate(address(alice_aave_vault), address(alice_aave_vault), type(uint256).max, 0);

        // second: try evc batch call, observe same revert
        IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](1);
        batchItems[0] = IEVC.BatchItem({
            targetContract: address(aaveEthVault),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeCall(
                ILiquidation.liquidate,
                (address(alice_aave_vault), address(alice_aave_vault), type(uint256).max, 0)
            )
        });

        vm.expectRevert(TwyneErrors.NotExternallyLiquidated.selector);
        evc.batch(batchItems);
        assertGt(alice_aave_vault.maxRelease(), 0, "EVK debt after EVK liq should be non-zero");
    }

    // Test F1: liquidation reverts when borrower position is healthy
    function test_aave_liquidate_fails_healthy_cant_liquidate_safetybuffer() public noGasMetering {
        test_aave_setupLiquidationFromSafetyBufferChange(twyneLiqLTV);

        vm.startPrank(alice);
        IERC20(USDC).approve(address(alice_aave_vault), type(uint).max);
        alice_aave_vault.repay(BORROW_USD_AMOUNT/2);
        vm.stopPrank();

        // move the chain to current timestamp and block + 1 days (not the +365 days of normal liquidation flow)
        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 12);

        bool canLiq = alice_aave_vault.canLiquidate();
        assertFalse(canLiq, "Vault should be healthy but it can be liquidated!");
        vm.startPrank(liquidator);
        // try to liquidate, but it will revert
        vm.expectRevert(TwyneErrors.HealthyNotLiquidatable.selector);
        alice_aave_vault.liquidate();
        vm.stopPrank();
    }


    // Test F2: if liquidator attempts to repay with more than maxRepay, liquidate call reverts
    function test_aave_liquidate_fails_excess_repay_safetybuffer() public noGasMetering {
        test_aave_setupLiquidationFromSafetyBufferChange(twyneLiqLTV);


        // Check vault owner changes before/after liquidation happens
        assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(liquidator);

        vm.expectRevert(TwyneErrors.VaultStatusLiquidatable.selector);
        alice_aave_vault.liquidate();

        vm.stopPrank();
    }

    // Test F3: liquidator who liquidates and makes the position healthy cannot be liquidated immediately
    // This test case is covered by previous test cases

    // Test F3.1: liquidator who liquidates and doesn't handle the debt but tries to withdraw collateral should not be able to (subcase of above, no need to test)

    // Test F4: borrower who has LTV at the liquidation threshold cannot be liquidated (LTV must be worse than threshold)
    function test_aave_liquidate_fails_at_threshold_safetybuffer() public noGasMetering {
        test_aave_setupLiquidationFromSafetyBufferChange(twyneLiqLTV);
        address collateralAsset = address(aWETHWrapper);
        // reverse the liquidation condition
        vm.startPrank(admin);
        twyneVaultManager.setExternalLiqBuffer(collateralAsset, externalLiqBufferInitial);
        vm.stopPrank();

        vm.startPrank(alice);
        IERC20(USDC).approve(address(alice_aave_vault), type(uint256).max);
        alice_aave_vault.repay(2);
        alice_aave_vault.borrow(1, alice);
        vm.stopPrank();

        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.HealthyNotLiquidatable.selector);
        alice_aave_vault.liquidate();
        vm.stopPrank();
    }

    // Test F5: self-liquidation should revert
    function test_aave_liquidate_fails_self_liquidate_safetybuffer() public noGasMetering {
        test_aave_setupLiquidationFromSafetyBufferChange(twyneLiqLTV);

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(alice);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // repay debt in Euler
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.liquidate, ())
        });

        // and now add collateral to make position more healthy
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.deposit, (COLLATERAL_AMOUNT))
        });

        // Expect SelfLiquidation() error
        vm.expectRevert(TwyneErrors.SelfLiquidation.selector);
        evc.batch(items);

        // confirm vault owner is still alice
        assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner after liquidation");

        vm.stopPrank();
    }

    // There are 3 cases where a liquidation can be triggered:
    // Case 1: Debt accumulation only from Aave triggers liquidation
    // Case 2: Debt accumulation only from internal intermediate vault borrow triggers liquidation
    // Case 3: Debt accumulation combined from BOTH Aave and internal intermediate vault borrow triggers liquidation (this should be the "normal" case for users)

    // passing tests to write
    // 1. liquidator who liquidates and doesn't make the position healthy can immediately get liquidated by someone else. Verify original borrower LTV and first liquidator LTV is zero
    // 2. liquidator who liquidates and makes the position healthy with some extra collateral cannot get liquidated by someone else (and has expected LTV). Verify original borrower LTV is zero
    // 3. liquidator who liquidates and makes the position healthy by repaying some debt cannot get liquidated by someone else (and has expected LTV). Verify original borrower LTV is zero
    // 4. liquidator who liquidates and makes the position healthy by repaying ALL debt ends up with LTV of 0 (no debt)
    // 5: liquidator who liquidates and makes the position healthy by repaying all debt ends up with LTV of 0 (no debt at all)
    // 6. liquidator who liquidates worthless collateral doesn't need to repay anything (what is the reasoning for adding code to this case? Maybe for memecoins?)
    // 7. test liquidation case when position is unhealthy on Aave (can test extreme bad debt case, with very low or zero collateral value)
    // 8. what happens if the Twyne reserved assets borrow becomes liquidatable on the intermediate vault before the Twyne liquidation is triggered?
    //   NOTE: the above case cannot happen if intermediate vault liquidation LTV = 1
    // 9. test tokens with other decimals
    // 10. test bad debt socialization (or lack thereof)
    // 11. Test liquidation when governance changes LTV (this simulates a response to Aave parameters changing. Test LTV ramping if implemented)
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
    function test_aave_liquidate_without_making_healthy_externalLTV() public noGasMetering {
        test_aave_setupLiquidationFromExternalLTVChange(twyneLiqLTV);

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.VaultStatusLiquidatable.selector);
        alice_aave_vault.liquidate();
        vm.stopPrank();
    }

    // Test 2: liquidator who liquidates and makes the position healthy with some extra collateral cannot get liquidated by someone else (and has expected LTV). Verify original borrower LTV is zero
    function test_aave_liquidate_make_healthy_more_collateral_externalLTV() public noGasMetering {
        test_aave_setupLiquidationFromExternalLTVChange(twyneLiqLTV);

        dealWrapperToken(address(aWETHWrapper), liquidator, 10 * COLLATERAL_AMOUNT);

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(liquidator);

        // first, assume that the liquidator is already a Twyne user
        // This confirms that a user with an existing vault can ALSO liquidate other vaults
        AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _asset: address(aWETHWrapper),
                _targetVault: aavePool,
                _liqLTV: twyneLiqLTV,
                _targetAsset: USDC
            })
        );

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // repay debt in Aave
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.liquidate, ())
        });

        // and now add collateral to make position more healthy
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.deposit, (COLLATERAL_AMOUNT))
        });

        evc.batch(items);

        // confirm vault owner is liquidator
        assertEq(alice_aave_vault.borrower(), liquidator, "Wrong collateral vault owner after liquidation");
        assertEq(collateralVaultFactory.getCollateralVaults(liquidator)[1], address(alice_aave_vault));
        assertEq(collateralVaultFactory.getCollateralVaults(alice)[0], address(alice_aave_vault));
        // confirm vault can NOT be liquidated now that there is more collateral
        // This tests scenario F3
        assertFalse(alice_aave_vault.canLiquidate(), "Vault should be healthy but it can be liquidated!");

        vm.stopPrank();
    }

    // Test 3: liquidator who liquidates and makes the position healthy by repaying some debt cannot get liquidated by someone else (and has expected LTV). Verify original borrower LTV is zero
    function test_aave_liquidate_make_healthy_reduce_debt_externalLTV() public noGasMetering {
        test_aave_setupLiquidationFromExternalLTVChange(twyneLiqLTV);

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(liquidator);

        // Save Aave external debt amount
        uint256 previousAaveDebt = alice_aave_vault.maxRepay();

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // repay debt in Aave
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.liquidate, ())
        });

        // and now add collateral to make position more healthy
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.repay, (BORROW_USD_AMOUNT/2))
        });

        evc.batch(items);
        // confirm vault owner is liquidator
        assertEq(alice_aave_vault.borrower(), liquidator, "Wrong collateral vault owner after liquidation");
        // confirm vault can NOT be liquidated now that there is more collateral
        bool canLiq = alice_aave_vault.canLiquidate();
        assertFalse(canLiq, "Vault should be healthy but it can be liquidated!");
        // confirm vault debt to Aave is lower than before
        uint256 latestAaveDebt = alice_aave_vault.maxRepay();
        assertLt(latestAaveDebt, previousAaveDebt, "Aave current debt is wrong");

        // This tests scenario F3
        canLiq = alice_aave_vault.canLiquidate();
        assertFalse(canLiq, "Vault should be healthy but it can be liquidated!");

        vm.stopPrank();

        // alice can't withdraw from collateral vault now
        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_aave_vault.withdraw(1, alice);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_aave_vault.withdraw(1, liquidator);
        vm.stopPrank();
    }

    // Test 4: liquidator who liquidates and makes the position healthy by repaying Aave debt ends up with LTV of 0 to Aave (no vUSDC debt)
    function test_aave_liquidate_make_healthy_zero_aave_debt_externalLTV() public noGasMetering {
        test_aave_setupLiquidationFromExternalLTVChange(twyneLiqLTV);
        // Verify all asset balances before liquidation process
        assertApproxEqRel(
            alice_aave_vault.maxRelease(),
            BORROW_ETH_AMOUNT,
            1e14,
            "EVK debt not correct amount before liquidation"
        );
        uint256 aaveCurrentDebt = alice_aave_vault.maxRepay();
        assertApproxEqRel(aaveCurrentDebt, BORROW_USD_AMOUNT, 1e12, "Aave current debt is wrong"); // original debt was BORROW_USD_AMOUNT
        // Verify that liquidator has no collateral vault shares and no intermediate vault debt before the liquidation
        assertEq(alice_aave_vault.balanceOf(liquidator), 0, "Liquidator should have zero collateral vault shares 1");
        assertEq(aaveEthVault.debtOf(liquidator), 0, "Liquidator should have zero intermediate vault debt 1");

        // Avoid liquidation cooloff
        vm.warp(block.timestamp + 12);

        // Verify that the internal borrow from the intermediate vault cannot be liquidated currently
        vm.startPrank(liquidator);

        (uint256 repay, uint256 yield) = aaveEthVault.checkLiquidation(liquidator, address(alice_aave_vault), address(alice_aave_vault));
        if (repay != 0 || yield != 0) {
            // either repay or yield is NOT zero, means internal borrow can be liquidated
            console2.log("Repay or yield is not zero!", repay);
        }

        // Use the checkLiquidation() function to verify that the position can be liquidated
        bool canLiq = alice_aave_vault.canLiquidate();
        assertTrue(canLiq, "Vault should be unhealthy, but cannot be liquidated!");

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // repay debt in Euler
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.liquidate, ())
        });

        // and now add collateral to make position more healthy
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.repay, (alice_aave_vault.maxRepay()))
        });

        evc.batch(items);

        // confirm vault ownership changed to liquidator
        assertEq(alice_aave_vault.borrower(), liquidator, "Wrong collateral vault owner after liquidation");

        // confirm no Aave debt remains
        aaveCurrentDebt = alice_aave_vault.maxRepay();
        assertEq(aaveCurrentDebt, 0, "Debt to Aave is not zero!");
        vm.stopPrank();
    }


    // Test 5: liquidator who liquidates and makes the position healthy by repaying all debt ends up with LTV of 0 (no debt at all)
    function test_aave_liquidate_make_healthy_zero_debt_externalLTV() public noGasMetering {
        test_aave_setupLiquidationFromExternalLTVChange(twyneLiqLTV);
        // Verify all asset balances before liquidation process
        // Verify that Alice holds collateral vault shares and intermediate vault debt
        assertApproxEqRel(alice_aave_vault.maxRelease(), BORROW_ETH_AMOUNT, 1e14, "EVK debt not correct amount before liquidation");
        uint256 aaveCurrentDebt = alice_aave_vault.maxRepay();
        assertApproxEqRel(aaveCurrentDebt, BORROW_USD_AMOUNT, 1e12, "Aave current debt is wrong"); // original debt was BORROW_USD_AMOUNT
        // Verify that liquidator has no collateral vault shares and no intermediate vault debt before the liquidation
        assertEq(alice_aave_vault.balanceOf(liquidator), 0, "Liquidator should have zero collateral vault shares 1");
        assertEq(aaveEthVault.debtOf(liquidator), 0, "Liquidator should have zero intermediate vault debt 1");

        // Avoid liquidation cooloff
        vm.warp(block.timestamp + 12);

        // Verify that the internal borrow from the intermediate vault cannot be liquidated currently
        vm.startPrank(liquidator);

        (uint256 repay, uint256 yield) = aaveEthVault.checkLiquidation(liquidator, address(alice_aave_vault), address(alice_aave_vault));
        if (repay != 0 || yield != 0) {
            // either repay or yield is NOT zero, means internal borrow can be liquidated
            console2.log("Repay or yield is not zero!", repay);
        }

        // Use the checkLiquidation() function to verify that the position can be liquidated
        bool canLiq = alice_aave_vault.canLiquidate();
        assertTrue(canLiq, "Vault should be unhealthy, but cannot be liquidated!");

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);

        uint maxWithdraw = alice_aave_vault.totalAssetsDepositedOrReserved() - alice_aave_vault.maxRelease();
        // repay debt in Euler
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.liquidate, ())
        });

        // and now add collateral to make position more healthy
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.repay, (alice_aave_vault.maxRepay()))
        });

        items[2] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.withdraw, (maxWithdraw, alice))
        });


        evc.batch(items);

        // confirm vault ownership changed to liquidator
        assertEq(alice_aave_vault.borrower(), liquidator, "Wrong collateral vault owner after liquidation");

        // confirm no Aave external borrow debt remains
        uint256 externalCurrentDebt = alice_aave_vault.maxRepay();
        assertEq(externalCurrentDebt, 0, "Debt to Aave is not zero!");
        // Verify that Alice holds no collateral vault shares and no intermediate vault debt
        assertEq(alice_aave_vault.maxRelease(), 0, "Alice intermediate vault debt not zero");

        // now collateral vault is empty
        assertEq(IERC20(address(aWETHWrapper)).balanceOf(address(alice_aave_vault)), 0, "Incorrect aWETHWrapper balance remaining in vault");

        vm.stopPrank();
    }

    // Test 6: liquidator who liquidates worthless collateral doesn't need to repay anything (what is the reasoning for adding code to this case? Maybe for memecoins?)
    // TODO not sure how to handle this case, because if collateral value is insufficient, liquidating means you have to supply some collateral to make it healthy
    function test_aave_liquidate_worthless_collateral_externalLTV() public noGasMetering {
        test_aave_setupLiquidationFromExternalLTVChange(twyneLiqLTV);

        // make the collateral value worthless
        address feed = getAaveOracleFeed(WETH);

        MockAaveFeed mockFeed = new MockAaveFeed();

        vm.etch(feed, address(mockFeed).code);
        mockFeed = MockAaveFeed(feed);
        mockFeed.setPrice(1);

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(liquidator);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // repay debt in Euler
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.liquidate, ())
        });

        // and now add collateral to make position more healthy
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.repay, (alice_aave_vault.maxRepay()))
        });

        evc.batch(items);

        vm.stopPrank();

        assertEq(alice_aave_vault.borrower(), liquidator, "Wrong collateral vault owner after liquidation");

        vm.stopPrank();
    }

    // Test 8: what happens if the Twyne reserved assets borrow becomes liquidatable on the intermediate vault before the Twyne liquidation is triggered?
    // We have disabled EVK vault liquidation (BridgeHookTarget is called on EVK liquidation which reverts).
    function test_aave_liquidate_bad_evk_debt_externalLTV() public noGasMetering {
        test_aave_setupLiquidationFromExternalLTVChange(twyneLiqLTV);

        // lower the liquidation LTV on the EVK vault to below the current borrow LTV to make it instantly liquidatable
        vm.startPrank(address(twyneVaultManager.owner()));
        twyneVaultManager.setLTV(aaveEthVault, address(alice_aave_vault), 0.1e3, 0.15e3, 0);
        vm.stopPrank();

        // Confirm that Twyne collateral vault can be liquidated
        assertTrue(alice_aave_vault.canLiquidate(), "Vault should be unhealthy but it cannot be liquidated!");

        // setLiquidationCoolOffTime(1) is called when intermediate vault is created, so warp forward by 1 block timestamp
        vm.warp(block.timestamp + 12);

        (uint256 collateralValue, uint256 liabilityValue) =
            aaveEthVault.accountLiquidity(address(alice_aave_vault), true);
        if (BORROW_ETH_AMOUNT != 0) {
            assertGt(liabilityValue, collateralValue, "liability is not greater than collateral, EVK liquidation is not possible");
        }

        // Confirm that the intermediate vault's liquidation of the Twyne vault is possible
        // checkLiquidate() returns (0, 0) if the account is healthy (no liquidation possible)
        (uint256 maxRepay, uint256 maxYield) = aaveEthVault.checkLiquidation(liquidator, address(alice_aave_vault), address(alice_aave_vault));
        assertGt(maxRepay, 0, "maxRepay is zero!");
        assertGt(maxYield, 0, "maxYield is zero!");

        vm.deal(liquidator, 10 ether);
        deal(address(USDC), liquidator, 10e20);
        dealWrapperToken(address(aWETHWrapper), liquidator, 10 * COLLATERAL_AMOUNT);

        IEVC(aaveEthVault.EVC()).enableController(address(this), address(aaveEthVault));
        IEVC(aaveEthVault.EVC()).enableCollateral(address(this), address(alice_aave_vault));

        // first: liquidate() call on the intermediate vault reverts due to custom Twyne hook
        vm.expectRevert(TwyneErrors.NotExternallyLiquidated.selector);
        aaveEthVault.liquidate(address(alice_aave_vault), address(alice_aave_vault), type(uint256).max, 0);

        // second: try evc batch call, observe same revert
        IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](1);
        batchItems[0] = IEVC.BatchItem({
            targetContract: address(aaveEthVault),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeCall(
                ILiquidation.liquidate,
                (address(alice_aave_vault), address(alice_aave_vault), type(uint256).max, 0)
            )
        });

        vm.expectRevert(TwyneErrors.NotExternallyLiquidated.selector);
        evc.batch(batchItems);
        assertGt(alice_aave_vault.maxRelease(), 0, "EVK debt after EVK liq should be non-zero");
    }

    // Test F1: liquidation reverts when borrower position is healthy
    function test_aave_liquidate_fails_healthy_cant_liquidate_externalLTV() public noGasMetering {
        test_aave_setupLiquidationFromExternalLTVChange(twyneLiqLTV);

        vm.startPrank(alice);
        IERC20(USDC).approve(address(alice_aave_vault), type(uint).max);
        alice_aave_vault.repay(BORROW_USD_AMOUNT/2);
        vm.stopPrank();

        // move the chain to current timestamp and block + 1 days (not the +365 days of normal liquidation flow)
        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 12);

        bool canLiq = alice_aave_vault.canLiquidate();
        assertFalse(canLiq, "Vault should be healthy but it can be liquidated!");
        vm.startPrank(liquidator);
        // try to liquidate, but it will revert
        vm.expectRevert(TwyneErrors.HealthyNotLiquidatable.selector);
        alice_aave_vault.liquidate();
        vm.stopPrank();
    }


    // Test F2: if liquidator attempts to repay with more than maxRepay, liquidate call reverts
    function test_aave_liquidate_fails_excess_repay_externalLTV() public noGasMetering {
        test_aave_setupLiquidationFromExternalLTVChange(twyneLiqLTV);


        // Check vault owner changes before/after liquidation happens
        assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(liquidator);

        vm.expectRevert(TwyneErrors.VaultStatusLiquidatable.selector);
        alice_aave_vault.liquidate();

        vm.stopPrank();
    }

    // Test F3: liquidator who liquidates and makes the position healthy cannot be liquidated immediately
    // This test case is covered by previous test cases

    // Test F3.1: liquidator who liquidates and doesn't handle the debt but tries to withdraw collateral should not be able to (subcase of above, no need to test)

    // Test F4: borrower who has LTV at the liquidation threshold cannot be liquidated (LTV must be worse than threshold)
    function test_aave_liquidate_fails_at_threshold_externalLTV() public noGasMetering {
        test_aave_setupLiquidationFromExternalLTVChange(twyneLiqLTV);

        // go back to the starting time
        vm.warp(block.timestamp - 2);

        setAaveLTV(address(aWETHWrapper), 8300);

        (,,uint availableBorrowsBase,,,) = IAaveV3Pool(aavePool).getUserAccountData(address(alice_aave_vault));
        uint usdcPrice = getAavePrice(USDC);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(alice_aave_vault), type(uint256).max);
        alice_aave_vault.repay(2);
        alice_aave_vault.borrow((availableBorrowsBase/1e2)*1e8/usdcPrice, alice);
        vm.expectRevert();
        alice_aave_vault.borrow(2, alice);
        vm.stopPrank();

        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.HealthyNotLiquidatable.selector);
        alice_aave_vault.liquidate();
        // Warp forward few seconds and confirm that this vault was on the edge of liquidation
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 10);
        // assertTrue(alice_aave_vault.canLiquidate()); // TODO uncomment this line
        vm.stopPrank();
    }

    // Test F5: self-liquidation should revert
    function test_aave_liquidate_fails_self_liquidate_externalLTV() public noGasMetering {
        test_aave_setupLiquidationFromExternalLTVChange(twyneLiqLTV);

        // Check vault owner changes before/after liquidation happens
        assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner before liquidation");
        vm.startPrank(alice);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // repay debt in Euler
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.liquidate, ())
        });

        // and now add collateral to make position more healthy
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.deposit, (COLLATERAL_AMOUNT))
        });

        // Expect SelfLiquidation() error
        vm.expectRevert(TwyneErrors.SelfLiquidation.selector);
        evc.batch(items);

        // confirm vault owner is still alice
        assertEq(alice_aave_vault.borrower(), alice, "Wrong collateral vault owner after liquidation");

        vm.stopPrank();
    }
}
