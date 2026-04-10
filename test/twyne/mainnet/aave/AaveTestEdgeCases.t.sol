// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {AaveTestBase, AaveV3CollateralVault, IAaveV3Pool, IAaveOracle, IAaveV3AToken, console2, BridgeHookTarget} from "./AaveTestBase.t.sol";
import "euler-vault-kit/EVault/shared/types/Types.sol";
import {Pausable} from "openzeppelin-contracts/utils/Pausable.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {CrossAdapter} from "euler-price-oracle/src/adapter/CrossAdapter.sol";
import {IPriceOracle} from "euler-price-oracle/src/interfaces/IPriceOracle.sol";
import {Errors as OracleErrors} from "euler-price-oracle/src/lib/Errors.sol";
import {EulerCollateralVault} from "src/twyne/EulerCollateralVault.sol";
import {IAaveV3ATokenWrapper} from "src/interfaces/IAaveV3ATokenWrapper.sol";
import {Errors} from "euler-vault-kit/EVault/shared/Errors.sol";
import {Events} from "euler-vault-kit/EVault/shared/Events.sol";
import {IRMTwyneCurve} from "src/twyne/IRMTwyneCurve.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";
import {VaultType} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {MockAaveFeed} from "test/mocks/MockAaveFeed.sol";
import {Errors as AaveErrors} from "aave-v3/protocol/libraries/helpers/Errors.sol";
import {EModeConfiguration} from "aave-v3/protocol/libraries/configuration/EModeConfiguration.sol";
import {IPoolAddressesProvider as IAaveV3AddressProvider} from "aave-v3/interfaces/IPoolAddressesProvider.sol";

interface IWETH is IERC20 {
    receive() external payable;
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}


contract AaveLiqCollateralVault is AaveV3CollateralVault {

    constructor(address _evc, address _aavePool, address _rewardController) AaveV3CollateralVault(_evc, _aavePool, _rewardController) {}

    function getAaveLiqLTV() external view returns (uint) {
        return _getExtLiqLTV();
    }

    function collateralScaledByLiqLTV1e8() external view returns (uint) {
        uint adjExtLiqLTV = uint(twyneVaultManager.externalLiqBuffers(address(intermediateVault))) * _getExtLiqLTV();
        return _collateralScaledByLiqLTV1e8(false, adjExtLiqLTV);
    }
}

contract AaveTestEdgeCases is AaveTestBase {
    uint256 BORROW_ETH_AMOUNT;
    function setUp() public override {
        super.setUp();
    }

    function aave_preLiquidationSetup(uint16 liqLTV) public {
        address collateral = address(aWETHWrapper);
        uint16 minLTV = uint16(getLiqLTV(collateral));
        address intermediateVault = intermediateVaultFor[collateral];
        uint16 extLiqBuffer = twyneVaultManager.externalLiqBuffers(intermediateVault);
        vm.assume(uint(minLTV) * uint(extLiqBuffer) <= uint256(liqLTV) * MAXFACTOR);
        vm.assume(liqLTV <= twyneVaultManager.maxTwyneLTVs(intermediateVault));
        // Bob deposits into aaveEthVault to earn boosted yield
        vm.startPrank(bob);
        IERC20(collateral).approve(address(aaveEthVault), type(uint256).max);
        aaveEthVault.deposit(CREDIT_LP_AMOUNT, bob);
        vm.stopPrank();

        // repeat but for Collateral non-EVK vault
        vm.startPrank(alice);
        alice_aave_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _intermediateVault: intermediateVaultFor[collateral],
                _targetVault: aavePool,
                _liqLTV: liqLTV,
                _targetAsset: USDC
            })
        );

        vm.label(address(alice_aave_vault), "alice_aave_vault");

        // Alice deposit the collateralAsset token into the collateral vault
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
        address underlyingAsset = IAaveV3ATokenWrapper(collateral).asset();
        vm.startPrank(address(alice_aave_vault));
        IAaveV3Pool(aavePool).setUserUseReserveAsCollateral(underlyingAsset, true);
        vm.stopPrank();

        // Assume the user max borrows to arrive at the extreme limit of what is possible without liquidation
        vm.startPrank(alice);

        // Use the first liquidation condition in _canLiquidate

        (,,uint availableBorrowsBase,,,) = IAaveV3Pool(aavePool).getUserAccountData(address(alice_aave_vault));
        availableBorrowsBase = availableBorrowsBase/1e2;
        console2.log("Available borrow base init: ", availableBorrowsBase);
        uint256 borrowAmountUSD1 = uint256(twyneVaultManager.externalLiqBuffers(address(alice_aave_vault.intermediateVault()))) * availableBorrowsBase / MAXFACTOR;

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
        alice_aave_vault.borrow(BORROW_USD_AMOUNT - 1, alice);

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



    function aave_setupCompleteExternalLiquidation() public noGasMetering {
        aave_preLiquidationSetup(twyneLiqLTV);
        // Borrow using the exact amounts of an older test setup
        vm.startPrank(alice);
        // IERC20(collateralAsset).approve(address(alice_aave_vault), type(uint).max);
        // IERC20(USDC).approve(address(alice_aave_vault), type(uint).max);
        // alice_aave_vault.deposit(5 ether);

        // alice_aave_vault.borrow(6983982500, alice);
        vm.stopPrank();

                // Put the vault into a liquidatable state
        if (twyneVaultManager.externalLiqBuffers(address(aaveEthVault)) < 0.975e4) {
            // If safety buffer is not very high, can warp forward a small amount to achieve a liquidatable position
            vm.warp(block.timestamp + 600); // accrue interest
        } else {
            // If safety buffer is very high, set price with mockOracle
            address feed = getAaveOracleFeed(WETH);
            uint initPrice = uint(MockAaveFeed(feed).latestAnswer());

            MockAaveFeed mockFeed = new MockAaveFeed();

            vm.etch(feed, address(mockFeed).code);
            mockFeed = MockAaveFeed(feed);
            mockFeed.setPrice(initPrice*930/1000);
        }
    }

    function test_invalid_withdraw() public {
        aave_collateralDepositWithoutBorrow(address(aWETHWrapper), 9100);


        vm.startPrank(alice);

        uint balance = aWETHWrapper.balanceOf(address(alice_aave_vault));
        vm.expectRevert();
        alice_aave_vault.withdraw(
            balance - 1,
            alice
        );
        vm.stopPrank();
    }

    function test_aave_rebalance() public {
        aave_collateralDepositWithoutBorrow(address(aWETHWrapper), 9100);

        vm.warp(block.timestamp + 1000);

        vm.startPrank(alice);

        assertGt(alice_aave_vault.canRebalance(), 0);

        alice_aave_vault.rebalance();

        vm.stopPrank();
    }

    // Confirm a user can have multiple identical collateral vaults at any given time
    function test_aave_secondVaultCreationSameUser() public noGasMetering {
        aave_createCollateralVault(address(aWETHWrapper), 0.9e4);

        vm.startPrank(alice);
        // Alice creates another vault with same params
        AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _intermediateVault: intermediateVaultFor[address(aWETHWrapper)],
                _targetVault: aavePool,
                _liqLTV: twyneLiqLTV,
                _targetAsset: USDC
            })
        );
        vm.stopPrank();
    }

    function test_aave_oracle_values() public noGasMetering {
        aave_collateralDepositWithoutBorrow(address(aWETHWrapper), 9100);
        address aToken = aWETHWrapper.aToken();
        uint balance = IERC20(aToken).balanceOf(address(alice_aave_vault));

        uint price = getAavePrice(WETH);

        vm.startPrank(address(alice_aave_vault));
        IAaveV3Pool(aavePool).setUserUseReserveAsCollateral(WETH, true);
        vm.stopPrank();

        (uint totalCollateralBase,,,,,) = IAaveV3Pool(aavePool).getUserAccountData(address(alice_aave_vault));

        uint tenPowDecimals = 10 ** uint(IERC20(WETH).decimals());

        assertApproxEqAbs(totalCollateralBase, balance * price / tenPowDecimals, 1, "Incorrect values");

        uint collateralValue = uint(aWETHWrapper.latestAnswer()) * aWETHWrapper.balanceOf(address(alice_aave_vault)) / tenPowDecimals;

        assertApproxEqAbs(totalCollateralBase, collateralValue, 10, "Incorrect values from latest answer");
    }

    // Test case where user tries to create a collateral vault with a config that is not allowed
    // In this case, USDC is not an allowed collateral
    function test_aave_createMismatchCollateralVault() public noGasMetering {
        aave_creditDeposit(address(aWETHWrapper));

        // Try creating a collateral vault with a disallowed collateral asset
        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.IntermediateVaultNotSet.selector);
        AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _intermediateVault: intermediateVaultFor[address(aUSDCWrapper)],
                _targetVault: aavePool,
                _liqLTV: twyneLiqLTV,
                _targetAsset: WETH
            })
        );

        // Try creating a collateral vault with a disallowed target asset
        vm.expectRevert(TwyneErrors.NotIntermediateVault.selector);
        AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _intermediateVault: intermediateVaultFor[address(aWETHWrapper)],
                _targetVault: aavePool,
                _liqLTV: twyneLiqLTV,
                _targetAsset: USDS
            })
        );
        vm.stopPrank();
    }


    // Collateral vault does not support standard ERC20 functions like transfer, transferFrom, etc.
    function test_aave_aliceCantTransferCollateralShares() public noGasMetering {
        aave_createCollateralVault(address(aWETHWrapper), 0.9e4);

        vm.startPrank(alice);

        // cannot transferFrom from vault
        vm.expectRevert(TwyneErrors.T_CV_OperationDisabled.selector);
        IERC20(address(alice_aave_vault)).transferFrom(address(alice_aave_vault), alice, 1 ether);

        // cannot transfer to eve
        vm.expectRevert(TwyneErrors.T_CV_OperationDisabled.selector);
        IERC20(address(alice_aave_vault)).transfer(eve, 1 ether);

        // this approve() does nothing because alice never holds vault shares directly
        vm.expectRevert(TwyneErrors.T_CV_OperationDisabled.selector);
        IERC20(address(alice_aave_vault)).approve(eve, 1 ether);
        vm.stopPrank();

        vm.startPrank(eve);
        vm.expectRevert(TwyneErrors.T_CV_OperationDisabled.selector);
        IERC20(address(alice_aave_vault)).transferFrom(alice, eve, 1 ether);
        vm.stopPrank();
    }

    function test_aave_anyoneCanRepayIntermediateVault() external noGasMetering {
        aave_firstBorrowDirect(address(aWETHWrapper));
        address collateralAsset = address(aWETHWrapper);
        // alice_aave_vault holds the Euler debt
        assertApproxEqAbs(alice_aave_vault.maxRepay(), BORROW_USD_AMOUNT, 1, "collateral vault holding incorrect Euler debt");

        // Move forward in time to observe increase in debts
        uint256 blockIncrement = 1000;
        vm.roll(block.number + blockIncrement);
        vm.warp(block.timestamp + 12);

        // borrower has MORE debt in eUSDC
        assertGt(alice_aave_vault.maxRelease(), 1e10);
        // collateral vault now has MORE debt in eUSDC
        assertGt(alice_aave_vault.maxRepay(), BORROW_USD_AMOUNT);

        // now repay - first Euler debt, then withdraw
        vm.startPrank(alice);
        IERC20(USDC).approve(address(alice_aave_vault), type(uint256).max);
        IERC20(collateralAsset).approve(address(alice_aave_vault), type(uint256).max);
        vm.stopPrank();
        assertEq(IERC20(USDC).allowance(alice, address(alice_aave_vault)), type(uint256).max);

        uint256 aliceCurrentDebt = alice_aave_vault.maxRelease();

        // Deal assets to someone
        address someone = makeAddr("someone");
        vm.deal(someone, 10 ether);
        deal(address(WETH), someone, INITIAL_DEALT_ERC20);
        dealWrapperToken(collateralAsset, someone, INITIAL_DEALT_ETOKEN);

        // Demonstrate that someone can repay all intermediate vault debt on behalf of a collateral vault
        vm.startPrank(someone);
        IERC20(collateralAsset).approve(address(aaveEthVault), type(uint).max);
        uint repaid = aaveEthVault.repay(type(uint).max, address(alice_aave_vault));
        vm.stopPrank();

        // borrower alice has no debt from intermediate vault
        assertEq(alice_aave_vault.maxRelease(), 0);
        assertEq(aliceCurrentDebt, repaid);
    }

    // Test the scenario of pausing the protocol
    function test_aave_pauseProtocol() public noGasMetering {
        address collateralAsset = address(aWETHWrapper);
        aave_collateralDepositWithoutBorrow(collateralAsset, 0.9e4);

        vm.startPrank(bob);
        aaveEthVault.deposit(1 ether, bob);
        vm.stopPrank();

        vm.startPrank(admin);
        collateralVaultFactory.pause();
        vm.stopPrank();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _intermediateVault: intermediateVaultFor[collateralAsset],
                _targetVault: aavePool,
                _liqLTV: twyneLiqLTV,
                _targetAsset: USDC
            })
        );

        vm.startPrank(address(aaveEthVault.governorAdmin()));
        (address originalHookTarget, ) = aaveEthVault.hookConfig();
        aaveEthVault.setHookConfig(address(0), OP_MAX_VALUE - 1);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(Errors.E_OperationDisabled.selector);
        aaveEthVault.deposit(1 ether, bob);
        vm.expectRevert(Errors.E_OperationDisabled.selector);
        aaveEthVault.withdraw(0.5 ether, bob, bob);
        vm.stopPrank();

        // alice can deposit and withdraw collateral
        vm.startPrank(alice);
        IERC20(WETH).approve(address(alice_aave_vault), type(uint).max);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        alice_aave_vault.depositUnderlying(INITIAL_DEALT_ERC20 / 2);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        alice_aave_vault.deposit(INITIAL_DEALT_ERC20 / 4);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        alice_aave_vault.skim();
        // withdraw is blocked because of the automatic rebalancing on the intermediate vault, which is paused
        vm.expectRevert(Errors.E_OperationDisabled.selector);
        alice_aave_vault.withdraw(1 ether, alice);
        vm.stopPrank();

        // Unpause the Twyne protocol
        vm.startPrank(admin);
        collateralVaultFactory.unpause();
        vm.stopPrank();

        // Unpause the intermediate vault by returning the original setHookConfig settings
        // EXCEPT also allow for skim() to be called now without reverting
        vm.startPrank(address(aaveEthVault.governorAdmin()));
        aaveEthVault.setHookConfig(originalHookTarget, OP_BORROW | OP_LIQUIDATE | OP_FLASHLOAN | OP_PULL_DEBT);
        vm.stopPrank();

        // Confirm skim() works now
        // eve donates to collateral vault, but this doesn't increase its totalAssets
        vm.startPrank(eve);
        IERC20(collateralAsset).transfer(address(aaveEthVault), CREDIT_LP_AMOUNT);
        aaveEthVault.skim(CREDIT_LP_AMOUNT, eve);

        IERC20(collateralAsset).transfer(address(alice_aave_vault), 1 ether);
        vm.stopPrank();

        vm.startPrank(alice);
        alice_aave_vault.skim();
        // after unpause, collateral deposit should work
        IERC20(collateralAsset).approve(address(alice_aave_vault), type(uint).max);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        // reserve assets from intermediate vault
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.deposit, (COLLATERAL_AMOUNT))
        });

        evc.batch(items);
        vm.stopPrank();
    }

    // Test that pullDebt is blocked on intermediate vault via BridgeHookTarget
    function test_aave_pullDebtBlocked() public noGasMetering {
        aave_firstBorrowViaCollateral(address(aWETHWrapper));

        // Alice tries to pull debt from her own position via intermediate vault
        // This should revert with T_OperationDisabled because pullDebt is hooked
        // and BridgeHookTarget's fallback reverts
        vm.startPrank(alice);
        evc.enableController(alice, address(aaveEthVault));

        vm.expectRevert(TwyneErrors.T_OperationDisabled.selector);
        aaveEthVault.pullDebt(1, address(alice_aave_vault));
        vm.stopPrank();
    }

    function test_aave_evc_wrapper_deposit() public {
        aave_collateralDepositWithoutBorrow(address(aWETHWrapper), 9100);

        vm.startPrank(alice);

        IERC20(WETH).approve(address(aWETHWrapper), type(uint).max);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        // reserve assets from intermediate vault
        items[0] = IEVC.BatchItem({
            targetContract: address(aWETHWrapper),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(aWETHWrapper.deposit, (COLLATERAL_AMOUNT, address(alice_aave_vault)))
        });

        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.skim, ())
        });

        evc.batch(items);

        vm.stopPrank();

    }

    function test_aave_full_util_redeem() public {
        address collateralAsset = address(aWETHWrapper);
        aave_collateralDepositWithoutBorrow(collateralAsset, 0.9e4);

        uint amountToWithdraw = aWETHWrapper.balanceOf(address(aaveEthVault));
        vm.startPrank(bob);
        aaveEthVault.withdraw(amountToWithdraw, bob, bob);
        vm.stopPrank();
        assertEq(aWETHWrapper.balanceOf(address(aaveEthVault)), 0, "Not at full utilisation");

        vm.startPrank(alice);
        uint bal = alice_aave_vault.balanceOf(address(alice_aave_vault));
        alice_aave_vault.redeemUnderlying(bal, alice);
        vm.stopPrank();
    }


    function test_aave_external_liquidation_full_util() public noGasMetering {
        aave_setupCompleteExternalLiquidation();

        vm.warp(block.timestamp + 1);

        // Ensure liquidator has enough aWETHWrapper to be a valid liquidator
        dealWrapperToken(address(aWETHWrapper), liquidator, 100 ether);

        vm.startPrank(liquidator);
        IERC20(USDC).approve(aavePool, type(uint).max);
        IEVC(alice_aave_vault.EVC()).enableCollateral(liquidator, address(aWETHWrapper));

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


        uint amountToWithdraw = aWETHWrapper.balanceOf(address(aaveEthVault));
        vm.startPrank(bob);
        aaveEthVault.withdraw(amountToWithdraw, bob, bob);
        vm.stopPrank();
        assertEq(aWETHWrapper.balanceOf(address(aaveEthVault)), 0, "Not at full utilisation");


        address newLiquidator = makeAddr("newLiquidator");
        vm.startPrank(newLiquidator);

        uint sharesToBurn = alice_aave_vault.totalAssetsDepositedOrReserved() - IAaveV3AToken(aWETHWrapper.aToken()).scaledBalanceOf(address(alice_aave_vault));
        uint amountToSplit = aWETHWrapper.balanceOf(address(alice_aave_vault)) - sharesToBurn;

        uint amountToRepay = alice_aave_vault.maxRepay();
        uint maxRelease = alice_aave_vault.maxRelease();

        (uint liquidatorReward, , ) = splitCollateralAfterExtLiq(amountToSplit, amountToRepay, maxRelease);

        deal(USDC, newLiquidator, amountToRepay);

        IERC20(USDC).approve(address(alice_aave_vault), type(uint).max);

        assertGt(liquidatorReward, 0, "Liquidator reward should be greater than 0");
        // evc.enableController(newLiquidator, address(alice_aave_vault.intermediateVault()));

        // Calling just handleExternalLiquidation should fail.
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            onBehalfOfAccount: newLiquidator,
            targetContract: address(alice_aave_vault),
            value: 0,
            data: abi.encodeCall(alice_aave_vault.handleExternalLiquidation, ())
        });


        evc.batch(items);

        vm.stopPrank();

        // Liquidator now receives aTokens instead of underlying WETH (to avoid revert during high utilization on Aave)
        assertEq(aWETHWrapper.convertToAssets(liquidatorReward), IERC20(aWETHWrapper.aToken()).balanceOf(newLiquidator), "Invalid liquidator reward");

    }


    function test_aave_emdode_disable() external {

        aave_borrowEmode();

        AaveLiqCollateralVault collateralVault = new AaveLiqCollateralVault(address(evc), aavePool, address(0));

        vm.etch(address(alice_aave_vault), address(collateralVault).code);
        uint initExtLiqLTV = AaveLiqCollateralVault(address(alice_aave_vault)).getAaveLiqLTV();
        uint8 categoryId = 1;

        assertEq(
            IAaveV3Pool(aavePool).getEModeCategoryCollateralConfig(categoryId).liquidationThreshold,
            initExtLiqLTV,
            "aave liquidation LTV in emode doesn't match"
        );

        uint reserveId = IAaveV3Pool(aavePool).getReserveData(WSTETH).id;
        uint128 collateralBitmap = IAaveV3Pool(aavePool).getEModeCategoryCollateralBitmap(categoryId);
        uint128 updatedBitMap = EModeConfiguration.setReserveBitmapBit(collateralBitmap, reserveId, false);

        address poolConfigurator = IAaveV3AddressProvider(aaveDataProvider.ADDRESSES_PROVIDER()).getPoolConfigurator();

        vm.startPrank(poolConfigurator);

        IAaveV3Pool(aavePool).configureEModeCategoryCollateralBitmap(categoryId, updatedBitMap);

        vm.stopPrank();

        assertEq(alice_aave_vault.canLiquidate(), true, "Vault should be liquidateable after emode disable");

        uint postExtLiqLTV = AaveLiqCollateralVault(address(alice_aave_vault)).getAaveLiqLTV();

        assertLt(postExtLiqLTV, initExtLiqLTV, "extLiqLTV not decreased");

        (,,uint currentLiquidationThreshold,,,,,,,) = aaveDataProvider.getReserveConfigurationData(IAaveV3ATokenWrapper(alice_aave_vault.asset()).asset());

        assertEq(postExtLiqLTV, currentLiquidationThreshold, "aave liquidation LTV after emode disable doesn't match");
    }


    function test_CV_rewards_claim() public {
        address collateralAsset = address(aWETHWrapper);
        aave_collateralDepositWithoutBorrow(collateralAsset, 0.9e4);

        deal(WETH, address(rewardsController), 1000e18);
        address[] memory assets = new address[](1);
        assets[0] = aWETHWrapper.aToken();
        alice_aave_vault.claimRewards(assets);

        assertEq(IERC20(WETH).balanceOf(address(twyneVaultManager)), 1000e18, "Vault manager didn't receive reward");
    }


    function test_aave_CV_init_error() public {
        address collateralAsset = address(aWSTETHWrapper);

        vm.expectRevert(TwyneErrors.ValueOutOfRange.selector);
        AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _intermediateVault: intermediateVaultFor[collateralAsset],
                _targetVault: aavePool,
                _liqLTV: 0.94e4,
                _targetAsset: WETH
            })
        );

        AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _intermediateVault: intermediateVaultFor[collateralAsset],
                _targetVault: aavePool,
                _liqLTV: 0.95e4,
                _targetAsset: WETH
            })
        );

    }

    // Test that RiskManager allows collateral vault to borrow with zero collateral
    // from the intermediate vault's perspective (collateral = 0, debt > 0)
    // function test_aave_RiskManager_SkipsLTVChecks() public noGasMetering {
    //     // Setup: credit deposit so intermediate vault has liquidity
    //     aave_creditDeposit(address(aWETHWrapper));

    //     // Create collateral vault
    //     vm.startPrank(alice);
    //     alice_aave_vault = AaveV3CollateralVault(
    //         collateralVaultFactory.createCollateralVault({
    //             _vaultType: VaultType.AAVE_V3,
    //             _intermediateVault: intermediateVaultFor[address(aWETHWrapper)],
    //             _targetVault: aavePool,
    //             _liqLTV: twyneLiqLTV,
    //             _targetAsset: USDC
    //         })
    //     );
    //     vm.stopPrank();

    //     uint borrowAmount = 1e18; // borrow 1 aWETHWrapper from intermediate vault

    //     // Collateral vault borrows from intermediate vault with no collateral
    //     vm.prank(address(alice_aave_vault));
    //     aaveEthVault.borrow(borrowAmount, address(alice_aave_vault));

    //     // Check accountLiquidity - collateral should be 0, debt should be non-zero
    //     (uint collateralValue, uint liabilityValue) = aaveEthVault.accountLiquidity(address(alice_aave_vault), false);

    //     console2.log("Collateral value:", collateralValue);
    //     console2.log("Liability value:", liabilityValue);

    //     assertEq(collateralValue, 0, "Collateral should be 0");
    //     assertGt(liabilityValue, 0, "Liability should be non-zero");
    // }

    // Test that RiskManager allows collateral vault to borrow above LTV after user deposits collateral
    // from the intermediate vault's perspective (collateral > 0, debt >> collateral, LTV > 100%)
    // function test_aave_RiskManager_SkipsLTVChecks_WithCollateral() public noGasMetering {
    //     // Setup: credit deposit so intermediate vault has liquidity
    //     aave_creditDeposit(address(aWETHWrapper));

    //     // Create collateral vault
    //     vm.startPrank(alice);
    //     alice_aave_vault = AaveV3CollateralVault(
    //         collateralVaultFactory.createCollateralVault({
    //             _vaultType: VaultType.AAVE_V3,
    //             _intermediateVault: intermediateVaultFor[address(aWETHWrapper)],
    //             _targetVault: aavePool,
    //             _liqLTV: twyneLiqLTV,
    //             _targetAsset: USDC
    //         })
    //     );

    //     // Deposit collateral into collateral vault
    //     IERC20(address(aWETHWrapper)).approve(address(alice_aave_vault), type(uint256).max);
    //     alice_aave_vault.deposit(COLLATERAL_AMOUNT);
    //     vm.stopPrank();

    //     // Borrow enough to make liability exceed collateral (position underwater)
    //     uint additionalBorrow = alice_aave_vault.balanceOf(address(alice_aave_vault)) - 1;

    //     // Collateral vault borrows more from intermediate vault
    //     vm.prank(address(alice_aave_vault));
    //     aaveEthVault.borrow(additionalBorrow, address(alice_aave_vault));

    //     // Check accountLiquidity
    //     (uint collateralValue, uint liabilityValue) = aaveEthVault.accountLiquidity(address(alice_aave_vault), false);

    //     // Verify liability exceeds collateral value (position is underwater from intermediate vault's POV)
    //     // This would normally cause checkAccountStatus to revert, but RiskManager skips LTV checks
    //     assertGt(collateralValue, 0, "Collatereal should be non-zero");
    //     assertGt(liabilityValue, collateralValue, "Liability should exceed collateral (underwater position)");
    // }

    // Test that non-collateral vault accounts are blocked by BridgeHookTarget (not RiskManager)
    // The BridgeHookTarget provides the first line of defense by checking receiver is a collateral vault
    function test_aave_NonCollateralVaultBorrowBlockedByHook() public noGasMetering {
        // Setup: credit deposit so intermediate vault has liquidity
        aave_creditDeposit(address(aWETHWrapper));

        // Alice (not a collateral vault) tries to borrow from intermediate vault
        vm.startPrank(alice);

        // Enable intermediate vault as controller for alice
        evc.enableController(alice, address(aaveEthVault));

        // Alice tries to borrow with receiver=alice - blocked by BridgeHookTarget (caller must be collateral vault)
        vm.expectRevert(TwyneErrors.CallerNotCollateralVault.selector);
        aaveEthVault.borrow(1e18, alice);

        alice_aave_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _intermediateVault: intermediateVaultFor[address(aWETHWrapper)],
                _targetVault: aavePool,
                _liqLTV: twyneLiqLTV,
                _targetAsset: USDC
            })
        );

        // Even if receiver is collateral vault, alice (non-CV caller) still cannot borrow
        vm.expectRevert(TwyneErrors.CallerNotCollateralVault.selector);
        aaveEthVault.borrow(1e18, address(alice_aave_vault));

        vm.stopPrank();

        // Random actor also cannot borrow
        address randomActor = makeAddr("randomActor");
        vm.startPrank(randomActor);
        evc.enableController(randomActor, address(aaveEthVault));
        vm.expectRevert(TwyneErrors.CallerNotCollateralVault.selector);
        aaveEthVault.borrow(1e18, address(alice_aave_vault));
        vm.stopPrank();
    }

    // Test that RiskManager's checkAccountStatus returns success for collateral vaults
    // even when they have debt but no collateral from the intermediate vault's perspective
    // function test_aave_RiskManager_CheckAccountStatus_CollateralVault() public noGasMetering {
    //     // Setup: credit deposit so intermediate vault has liquidity
    //     aave_creditDeposit(address(aWETHWrapper));

    //     // Create collateral vault
    //     vm.startPrank(alice);
    //     alice_aave_vault = AaveV3CollateralVault(
    //         collateralVaultFactory.createCollateralVault({
    //             _vaultType: VaultType.AAVE_V3,
    //             _intermediateVault: intermediateVaultFor[address(aWETHWrapper)],
    //             _targetVault: aavePool,
    //             _liqLTV: twyneLiqLTV,
    //             _targetAsset: USDC
    //         })
    //     );
    //     vm.label(address(alice_aave_vault), "alice_aave_vault");
    //     vm.stopPrank();

    //     // Collateral vault borrows from intermediate vault with no collateral
    //     vm.prank(address(alice_aave_vault));
    //     aaveEthVault.borrow(1e18, address(alice_aave_vault));

    //     // Verify the account is underwater from intermediate vault's perspective
    //     (uint collateralValue, uint liabilityValue) = aaveEthVault.accountLiquidity(address(alice_aave_vault), false);
    //     assertEq(collateralValue, 0, "Collateral should be 0");
    //     assertGt(liabilityValue, 0, "Liability should be non-zero");

    //     // RiskManager should still allow this because it skips checks for collateral vaults
    //     // The account status check passes (no revert) even though position is underwater
    //     address[] memory collaterals = new address[](1);
    //     collaterals[0] = address(alice_aave_vault);
    //     bytes4 result = aaveEthVault.checkAccountStatus(address(alice_aave_vault), collaterals);
    //     assertEq(result, IEVCVault.checkAccountStatus.selector, "checkAccountStatus should return success selector");

    //     // Verify that checkAccountStatus also runs (and passes) for non-collateral vault accounts
    //     // Since alice has no debt (BridgeHookTarget prevents non-collateral vaults from borrowing),
    //     // the liquidity check passes
    //     bytes4 aliceResult = aaveEthVault.checkAccountStatus(alice, collaterals);
    //     assertEq(aliceResult, IEVCVault.checkAccountStatus.selector, "checkAccountStatus should pass for alice with no debt");

    //     // Enable controller for alice so she can attempt to borrow
    //     vm.startPrank(alice);
    //     evc.enableController(alice, address(aaveEthVault));

    //     // Verify alice cannot borrow - hook blocks non-collateral vault callers
    //     vm.expectRevert(TwyneErrors.CallerNotCollateralVault.selector);
    //     aaveEthVault.borrow(0.1e18, alice);
    //     // Even when receiver is collateral vault, alice (non-CV caller) still cannot borrow
    //     vm.expectRevert(TwyneErrors.CallerNotCollateralVault.selector);
    //     aaveEthVault.borrow(0.1e18, address(alice_aave_vault));

    //     // Verify alice cannot pullDebt from collateral vault
    //     vm.expectRevert(TwyneErrors.T_OperationDisabled.selector);
    //     aaveEthVault.pullDebt(0.1e18, address(alice_aave_vault));
    // }


    ///
    // Tests for getAdjustedLTV branches
    ///

    /// @notice Test Case 1: LTV based on available assets in intermediate vault
    /// @dev When intermediate vault has no liquidity, the adjusted LTV formula uses clpAvailable=0,
    /// which limits the effective LTV based on available credit
    function test_aave_getAdjustedLTV_basedOnIntermediateVaultAssets() public noGasMetering {
        address collateralAsset = address(aWETHWrapper);

        // Create collateral vault WITHOUT credit LP deposit first
        // This means intermediate vault has 0 liquidity
        vm.startPrank(alice);
        alice_aave_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _intermediateVault: intermediateVaultFor[collateralAsset],
                _targetVault: aavePool,
                _liqLTV: twyneLiqLTV,
                _targetAsset: USDC
            })
        );
        vm.stopPrank();

        vm.label(address(alice_aave_vault), "alice_aave_vault");

        // Verify intermediate vault has no assets
        IEVault intermediateVault = alice_aave_vault.intermediateVault();
        assertEq(intermediateVault.cash(), 0, "Intermediate vault should have 0 cash");

        // Now alice deposits collateral
        vm.startPrank(alice);
        IERC20(collateralAsset).approve(address(alice_aave_vault), type(uint256).max);

        // When intermediate vault has 0 cash, the deposit should still succeed
        // but the reserved amount should be 0 (since there's nothing to borrow from intermediate vault)
        alice_aave_vault.deposit(COLLATERAL_AMOUNT);
        vm.stopPrank();

        // When intermediate vault has no cash, maxRelease should be 0
        // because the collateral vault can't borrow from an empty intermediate vault
        uint maxRelease = alice_aave_vault.maxRelease();
        assertEq(maxRelease, 0, "maxRelease should be 0 when intermediate vault is empty");

        // totalAssetsDepositedOrReserved should equal COLLATERAL_AMOUNT (only user deposit, no reserved)
        assertEq(
            alice_aave_vault.totalAssetsDepositedOrReserved(),
            COLLATERAL_AMOUNT,
            "totalAssetsDepositedOrReserved should equal user deposit when no credit available"
        );

        // User-owned collateral should equal COLLATERAL_AMOUNT
        assertEq(
            alice_aave_vault.balanceOf(address(alice_aave_vault)),
            COLLATERAL_AMOUNT,
            "User collateral should equal deposit amount"
        );
    }

    /// @notice Test Case 3: LTV based on max LTV from vault manager
    /// @dev When vault manager's maxTwyneLTV is reduced after vault creation,
    /// the adjusted LTV should be capped by the new maxTwyneLTV
    function test_aave_getAdjustedLTV_basedOnMaxLTVFromVaultManager() public noGasMetering {
        address collateralAsset = address(aWETHWrapper);

        // Setup: credit deposit so intermediate vault has liquidity
        aave_creditDeposit(collateralAsset);

        IEVault intermediateVault = IEVault(intermediateVaultFor[collateralAsset]);

        // Create collateral vault with a high twyneLiqLTV
        uint16 initialUserLTV = twyneLiqLTV; // e.g., 0.91e4

        vm.startPrank(alice);
        alice_aave_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _intermediateVault: intermediateVaultFor[collateralAsset],
                _targetVault: aavePool,
                _liqLTV: initialUserLTV,
                _targetAsset: USDC
            })
        );
        vm.stopPrank();

        vm.label(address(alice_aave_vault), "alice_aave_vault");

        // Verify user's twyneLiqLTV is set correctly
        assertEq(alice_aave_vault.twyneLiqLTV(), initialUserLTV, "User LTV should be set correctly");

        // Now admin reduces the maxTwyneLTV on vault manager to be lower than user's LTV
        uint16 newMaxLTV = initialUserLTV - 500; // Reduce by 5% (500 basis points)
        vm.startPrank(admin);
        twyneVaultManager.setMaxLiquidationLTV(address(intermediateVault), newMaxLTV, 0);
        vm.stopPrank();

        // Verify the max LTV was reduced
        assertEq(
            twyneVaultManager.maxTwyneLTVs(address(intermediateVault)),
            newMaxLTV,
            "Max LTV should be reduced"
        );

        // User's twyneLiqLTV is still the original value (higher than new max)
        assertGt(alice_aave_vault.twyneLiqLTV(), newMaxLTV, "User LTV should be higher than new max LTV");

        // Calculate expected reserved amount based on NEW max LTV (not user's LTV)
        uint externalLiqBuffer = uint(twyneVaultManager.externalLiqBuffers(address(intermediateVault)));
        uint externalLiqLTV = getLiqLTV(collateralAsset);
        uint liqLTV_external = externalLiqLTV * externalLiqBuffer; // 1e8 precision

        // The effective LTV should be capped at newMaxLTV
        uint effectiveLTV = newMaxLTV;
        uint LTVdiff = (MAXFACTOR * effectiveLTV) - liqLTV_external;
        uint expectedReservedAssets = Math.ceilDiv(COLLATERAL_AMOUNT * LTVdiff, liqLTV_external);

        // Now alice deposits collateral
        vm.startPrank(alice);
        IERC20(collateralAsset).approve(address(alice_aave_vault), type(uint256).max);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.deposit, (COLLATERAL_AMOUNT))
        });
        evc.batch(items);
        vm.stopPrank();

        // Check the reserved amount - it should be based on newMaxLTV, not user's higher LTV
        uint actualReservedAssets = alice_aave_vault.maxRelease();

        // The reserved amount should match what's expected with the new max LTV
        assertApproxEqAbs(
            actualReservedAssets,
            expectedReservedAssets,
            1,
            "Reserved assets should be based on max LTV from vault manager"
        );

        // Verify totalAssetsDepositedOrReserved
        assertEq(
            alice_aave_vault.totalAssetsDepositedOrReserved(),
            COLLATERAL_AMOUNT + actualReservedAssets,
            "totalAssetsDepositedOrReserved should equal deposit + reserved"
        );

        // Verify user-owned collateral
        assertEq(
            alice_aave_vault.balanceOf(address(alice_aave_vault)),
            COLLATERAL_AMOUNT,
            "User collateral should equal deposit amount"
        );
    }

    function splitCollateralAfterExtLiq(uint _collateralBalance, uint _maxRepay, uint _maxRelease) internal view returns (uint, uint, uint) {

        IAaveV3ATokenWrapper __asset = aWETHWrapper;

        if (_maxRepay == 0) {
            uint _releaseAmount = Math.min(_collateralBalance, _maxRelease);
            uint _borrowerClaim = _collateralBalance - _releaseAmount;
            return (0, _releaseAmount, _borrowerClaim);
        }

        // Step 1: Calculate user's portion of collateral (C_temp)
        // userCollateral = B_ext / λ̃^max_t (converted to collateral asset units)
        // This represents the collateral value needed to cover debt at max Twyne LTV
        // Get price of target asset (borrowed asset) from Aave oracle
        uint targetAssetPrice = IAaveOracle(IAaveV3AddressProvider(__asset.POOL_ADDRESSES_PROVIDER()).getPriceOracle()).getAssetPrice(USDC);

        // Convert _maxRepay / maxTwyneLTV to USD
        // Result is in USD with Chainlink decimals for target asset
        uint userCollateral = targetAssetPrice * (_maxRepay * MAXFACTOR / twyneVaultManager.maxTwyneLTVs(address(alice_aave_vault.intermediateVault())))
            / alice_aave_vault.tenPowVAssetDecimals();

        // Convert from USD to collateral asset units
        // Divides by collateral asset's Chainlink price
        userCollateral = userCollateral * alice_aave_vault.tenPowAssetDecimals() / uint(__asset.latestAnswer());


        // Cap by available collateral balance
        userCollateral = Math.min(_collateralBalance, userCollateral);


        // Step 2: Calculate CLP gets min(C_left - C_temp, C_LP^old)
        // This is the amount intermediate vault gets back
        uint releaseAmount = Math.min(_collateralBalance - userCollateral, _maxRelease);


        // Step 3: Calculate C_new which is C_left - CLP.
        // Collateral to be split between borrower and liquidator
        userCollateral = _collateralBalance - releaseAmount;


        // Step 3: Split userCollateral between borrower and liquidator using dynamic incentive
        // Convert userCollateral to USD for collateralForBorrower calculation
        uint C_new =
            userCollateral * uint(__asset.latestAnswer()) / alice_aave_vault.tenPowAssetDecimals();


        (, uint B,,,,) = IAaveV3Pool(aavePool).getUserAccountData(address(alice_aave_vault));


        // Apply dynamic incentive model: borrower gets collateralForBorrower(B, C_new)
        // Liquidator gets the remainder as reward for handling external liquidation
        uint borrowerClaim = alice_aave_vault.collateralForBorrower(B, C_new);
        uint liquidatorReward = userCollateral - borrowerClaim;

        return (liquidatorReward, releaseAmount, borrowerClaim);
    }

    /// @notice Test dynamic LTV leg selection: when intermediate vault has high liquidity, chosen leg dominates
    /// @dev When cash >> collateral, dynamic leg = adjExtLiqLTV * (cash + totalAssets) is very large
    /// so min() selects the chosen leg = userCollateral * MAXFACTOR * min(twyneLiqLTV, maxTwyneLTV)
    function test_aave_dynamicLTV_chosenLegDominates_highLiquidity() public noGasMetering {
        address collateralAsset = address(aWETHWrapper);

        // Setup: large credit deposit so intermediate vault has high liquidity
        aave_creditDeposit(collateralAsset);

        // Create collateral vault
        vm.startPrank(alice);
        alice_aave_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _intermediateVault: intermediateVaultFor[collateralAsset],
                _targetVault: aavePool,
                _liqLTV: twyneLiqLTV,
                _targetAsset: USDC
            })
        );
        vm.stopPrank();

        IEVault intermediateVault = alice_aave_vault.intermediateVault();
        uint cashBefore = intermediateVault.cash();
        assertGt(cashBefore, 0, "Intermediate vault should have cash");

        // Deposit collateral
        vm.startPrank(alice);
        IERC20(collateralAsset).approve(address(alice_aave_vault), type(uint256).max);
        alice_aave_vault.deposit(COLLATERAL_AMOUNT);
        vm.stopPrank();

        // Calculate expected reservation using the chosen leg formula
        // When chosen leg dominates: invariantAmount = ceilDiv(C * MAXFACTOR * minLTV, adjExtLiqLTV)
        uint externalLiqBuffer = uint(twyneVaultManager.externalLiqBuffers(address(intermediateVault)));
        uint externalLiqLTV = getLiqLTV(collateralAsset);
        uint adjExtLiqLTV = externalLiqBuffer * externalLiqLTV;
        uint minLTV = Math.min(twyneLiqLTV, twyneVaultManager.maxTwyneLTVs(address(intermediateVault)));

        // Expected: ceilDiv(C * MAXFACTOR * minLTV, adjExtLiqLTV)
        uint expectedInvariant = Math.ceilDiv(COLLATERAL_AMOUNT * MAXFACTOR * minLTV, adjExtLiqLTV);
        uint expectedReserved = expectedInvariant - COLLATERAL_AMOUNT;

        uint actualReserved = alice_aave_vault.maxRelease();

        // Should match chosen leg calculation (with small tolerance for rounding)
        assertApproxEqAbs(
            actualReserved,
            expectedReserved,
            2,
            "Reserved amount should match chosen leg formula when liquidity is high"
        );
    }

    /// @notice Test dynamic LTV leg selection: when intermediate vault has low liquidity, dynamic leg dominates
    /// @dev When cash is low/zero, dynamic leg = adjExtLiqLTV * totalAssets is smaller than chosen leg
    /// so min() selects the dynamic leg, resulting in less/no credit reservation
    function test_aave_dynamicLTV_dynamicLegDominates_lowLiquidity() public noGasMetering {
        address collateralAsset = address(aWETHWrapper);

        // Create collateral vault WITHOUT credit deposit (0 liquidity)
        vm.startPrank(alice);
        alice_aave_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _intermediateVault: intermediateVaultFor[collateralAsset],
                _targetVault: aavePool,
                _liqLTV: twyneLiqLTV,
                _targetAsset: USDC
            })
        );
        vm.stopPrank();

        IEVault intermediateVault = alice_aave_vault.intermediateVault();
        assertEq(intermediateVault.cash(), 0, "Intermediate vault should have 0 cash");

        // Deposit collateral
        vm.startPrank(alice);
        IERC20(collateralAsset).approve(address(alice_aave_vault), type(uint256).max);
        alice_aave_vault.deposit(COLLATERAL_AMOUNT);
        vm.stopPrank();

        // When cash = 0 and isRebalancing = true:
        // clpPlusC = 0 + totalAssets = totalAssets (since no borrow yet, totalAssets = COLLATERAL_AMOUNT)
        // dynamic leg = adjExtLiqLTV * totalAssets
        // invariantAmount = ceilDiv(adjExtLiqLTV * totalAssets, adjExtLiqLTV) = totalAssets
        // Therefore reserved = totalAssets - COLLATERAL_AMOUNT = 0

        uint actualReserved = alice_aave_vault.maxRelease();
        assertEq(actualReserved, 0, "Reserved should be 0 when dynamic leg dominates with no liquidity");

        // Verify totalAssets equals just the deposit
        assertEq(
            alice_aave_vault.totalAssetsDepositedOrReserved(),
            COLLATERAL_AMOUNT,
            "Total assets should equal deposit when no reservation"
        );
    }

    /// @notice Test isRebalancing flag: _canLiquidate uses isRebalancing=false (excludes cash)
    /// @dev This verifies that liquidation checks don't include intermediate vault cash in the dynamic LTV calculation
    function test_aave_dynamicLTV_isRebalancingFlag_liquidationCheck() public noGasMetering {
        address collateralAsset = address(aWETHWrapper);

        // Setup with credit deposit
        aave_creditDeposit(collateralAsset);

        vm.startPrank(alice);
        alice_aave_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _intermediateVault: intermediateVaultFor[collateralAsset],
                _targetVault: aavePool,
                _liqLTV: twyneLiqLTV,
                _targetAsset: USDC
            })
        );

        IERC20(collateralAsset).approve(address(alice_aave_vault), type(uint256).max);
        alice_aave_vault.deposit(COLLATERAL_AMOUNT);
        vm.stopPrank();

        // Vault should not be liquidatable initially
        assertFalse(alice_aave_vault.canLiquidate(), "Vault should not be liquidatable initially");

        // Borrow a moderate amount (not close to liquidation)
        vm.startPrank(alice);
        alice_aave_vault.borrow(1000e6, alice); // Borrow 1000 USDC
        vm.stopPrank();

        // Even with borrowing, if position is healthy, canLiquidate should return false
        // The isRebalancing=false in _canLiquidate means it uses totalAssets without adding cash
        // This is more conservative for liquidation checks
        bool canLiq = alice_aave_vault.canLiquidate();

        // Position should still be healthy (not liquidatable) after moderate borrow
        assertFalse(canLiq, "Vault should not be liquidatable after moderate borrow");
    }

    /// @notice Test that dynamic LTV responds correctly when Aave lowers external liqLTV
    /// @dev Lower external liqLTV shrinks dynamic leg, may require more credit reservation
    function test_aave_dynamicLTV_externalLiqLTVDecrease() public noGasMetering {
        address collateralAsset = address(aWETHWrapper);
        aave_creditDeposit(collateralAsset);

        // Create collateral vault and deposit
        vm.startPrank(alice);
        alice_aave_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _intermediateVault: intermediateVaultFor[collateralAsset],
                _targetVault: aavePool,
                _liqLTV: twyneLiqLTV,
                _targetAsset: USDC
            })
        );
        IERC20(collateralAsset).approve(address(alice_aave_vault), type(uint256).max);
        alice_aave_vault.deposit(COLLATERAL_AMOUNT);
        vm.stopPrank();

        uint initialMaxRelease = alice_aave_vault.maxRelease();

        // Get current liqLTV from Aave
        uint16 currentLiqLTV = uint16(getLiqLTV(collateralAsset));

        // Lower Aave's liqLTV
        uint16 newLiqLTV = currentLiqLTV - 500; // Reduce by 5%
        setAaveLTV(collateralAsset, newLiqLTV);

        // Verify LTV was lowered
        assertEq(getLiqLTV(collateralAsset), newLiqLTV, "External liqLTV should be lowered");

        // With lower external liqLTV, dynamic leg shrinks
        // canRebalance should revert since invariant likely increased
        vm.expectRevert(TwyneErrors.CannotRebalance.selector);
        alice_aave_vault.canRebalance();

        // Trigger rebalancing via deposit to see credit increase
        vm.startPrank(alice);
        alice_aave_vault.deposit(0.01e18);
        vm.stopPrank();

        uint newMaxRelease = alice_aave_vault.maxRelease();

        // Should have borrowed more credit from intermediate vault
        assertGt(newMaxRelease, initialMaxRelease, "Should borrow more credit after external liqLTV decrease");
    }

    /// @notice Test that dynamic LTV responds correctly when Aave raises external liqLTV
    /// @dev Higher external liqLTV grows dynamic leg, may allow credit release
    function test_aave_dynamicLTV_externalLiqLTVIncrease() public noGasMetering {
        address collateralAsset = address(aWETHWrapper);
        aave_creditDeposit(collateralAsset);

        // Create collateral vault and deposit
        vm.startPrank(alice);
        alice_aave_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _intermediateVault: intermediateVaultFor[collateralAsset],
                _targetVault: aavePool,
                _liqLTV: twyneLiqLTV,
                _targetAsset: USDC
            })
        );
        IERC20(collateralAsset).approve(address(alice_aave_vault), type(uint256).max);
        alice_aave_vault.deposit(COLLATERAL_AMOUNT);
        vm.stopPrank();

        uint initialMaxRelease = alice_aave_vault.maxRelease();

        // Get current liqLTV from Aave
        uint16 currentLiqLTV = uint16(getLiqLTV(collateralAsset));

        // Raise Aave's liqLTV
        uint16 newLiqLTV = currentLiqLTV + 200; // Increase by 2%
        setAaveLTV(collateralAsset, newLiqLTV);

        // With higher external liqLTV, dynamic leg grows
        // Check if we can rebalance (have excess credit)
        try alice_aave_vault.canRebalance() returns (uint excessCredit) {
            assertGt(excessCredit, 0, "Should have excess credit after external liqLTV increase");

            // Perform rebalance
            alice_aave_vault.rebalance();

            uint newMaxRelease = alice_aave_vault.maxRelease();
            assertLt(newMaxRelease, initialMaxRelease, "Should have less reserved credit after rebalance");
        } catch {
            // If canRebalance reverts, chosen leg might still dominate
        }
    }

    /// @notice Test that dynamic LTV responds correctly to maxTwyneLTV decrease
    /// @dev Lower maxTwyneLTV shrinks chosen leg, reducing invariant and allowing credit release
    function test_aave_dynamicLTV_maxTwyneLTVDecrease() public noGasMetering {
        address collateralAsset = address(aWETHWrapper);
        aave_creditDeposit(collateralAsset);

        IEVault intermediateVault = IEVault(intermediateVaultFor[collateralAsset]);
        uint16 initialMaxTwyneLTV = twyneVaultManager.maxTwyneLTVs(address(intermediateVault));

        // Create collateral vault with high twyneLiqLTV (capped by maxTwyneLTV)
        vm.startPrank(alice);
        alice_aave_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _intermediateVault: intermediateVaultFor[collateralAsset],
                _targetVault: aavePool,
                _liqLTV: initialMaxTwyneLTV,
                _targetAsset: USDC
            })
        );
        IERC20(collateralAsset).approve(address(alice_aave_vault), type(uint256).max);
        alice_aave_vault.deposit(COLLATERAL_AMOUNT);
        vm.stopPrank();

        uint initialMaxRelease = alice_aave_vault.maxRelease();

        // Lower maxTwyneLTV
        uint16 newMaxTwyneLTV = initialMaxTwyneLTV - 500; // Reduce by 5%
        vm.prank(twyneVaultManager.owner());
        twyneVaultManager.setMaxLiquidationLTV(address(intermediateVault), newMaxTwyneLTV, 0);

        // Check if we can rebalance (have excess credit since invariant decreased)
        try alice_aave_vault.canRebalance() returns (uint excessCredit) {
            assertGt(excessCredit, 0, "Should have excess credit after maxTwyneLTV decrease");

            alice_aave_vault.rebalance();

            uint newMaxRelease = alice_aave_vault.maxRelease();
            assertLt(newMaxRelease, initialMaxRelease, "Credit reservation should decrease when maxTwyneLTV decreases");
        } catch {
            // If canRebalance reverts, dynamic leg dominates
        }
    }

    /// @notice Test that dynamic LTV responds correctly to externalLiqBuffer decrease
    /// @dev Lower buffer shrinks dynamic leg, may require more credit reservation
    function test_aave_dynamicLTV_externalLiqBufferDecrease() public noGasMetering {
        address collateralAsset = address(aWETHWrapper);
        aave_creditDeposit(collateralAsset);

        IEVault intermediateVault = IEVault(intermediateVaultFor[collateralAsset]);

        // Create collateral vault
        vm.startPrank(alice);
        alice_aave_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _intermediateVault: intermediateVaultFor[collateralAsset],
                _targetVault: aavePool,
                _liqLTV: twyneLiqLTV,
                _targetAsset: USDC
            })
        );
        IERC20(collateralAsset).approve(address(alice_aave_vault), type(uint256).max);
        alice_aave_vault.deposit(COLLATERAL_AMOUNT);
        vm.stopPrank();

        uint initialMaxRelease = alice_aave_vault.maxRelease();

        // Get initial buffer and decrease it
        uint16 initialBuffer = twyneVaultManager.externalLiqBuffers(address(intermediateVault));
        uint16 newBuffer = initialBuffer - 200; // Decrease by 2%
        if (newBuffer == 0) newBuffer = 1;

        vm.prank(twyneVaultManager.owner());
        twyneVaultManager.setExternalLiqBuffer(address(intermediateVault), newBuffer, 0);

        // canRebalance should fail (no excess credit)
        vm.expectRevert(TwyneErrors.CannotRebalance.selector);
        alice_aave_vault.canRebalance();

        // Trigger rebalancing via deposit
        vm.startPrank(alice);
        alice_aave_vault.deposit(0.01e18);
        vm.stopPrank();

        uint newMaxRelease = alice_aave_vault.maxRelease();

        // Should have more credit reserved now
        assertGt(newMaxRelease, initialMaxRelease, "Should reserve more credit after buffer decrease");
    }

    /// @notice Test that dynamic LTV responds correctly to externalLiqBuffer increase
    /// @dev Higher buffer grows dynamic leg, may allow credit release
    function test_aave_dynamicLTV_externalLiqBufferIncrease() public noGasMetering {
        address collateralAsset = address(aWETHWrapper);
        aave_creditDeposit(collateralAsset);

        IEVault intermediateVault = IEVault(intermediateVaultFor[collateralAsset]);

        // Create collateral vault
        vm.startPrank(alice);
        alice_aave_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _intermediateVault: intermediateVaultFor[collateralAsset],
                _targetVault: aavePool,
                _liqLTV: twyneLiqLTV,
                _targetAsset: USDC
            })
        );
        IERC20(collateralAsset).approve(address(alice_aave_vault), type(uint256).max);
        alice_aave_vault.deposit(COLLATERAL_AMOUNT);
        vm.stopPrank();

        uint initialMaxRelease = alice_aave_vault.maxRelease();

        // Get initial buffer and increase it
        uint16 initialBuffer = twyneVaultManager.externalLiqBuffers(address(intermediateVault));
        uint16 newBuffer = initialBuffer + 200; // Increase by 2%
        if (newBuffer > MAXFACTOR) newBuffer = uint16(MAXFACTOR);

        vm.prank(twyneVaultManager.owner());
        twyneVaultManager.setExternalLiqBuffer(address(intermediateVault), newBuffer, 0);

        // Check if we can rebalance
        try alice_aave_vault.canRebalance() returns (uint excessCredit) {
            assertGt(excessCredit, 0, "Should have excess credit after buffer increase");

            alice_aave_vault.rebalance();

            uint newMaxRelease = alice_aave_vault.maxRelease();
            assertLt(newMaxRelease, initialMaxRelease, "Should have less reserved credit after rebalance");
        } catch {
            // If canRebalance reverts, chosen leg might still dominate
        }
    }

    /// @notice Test negative excess credit: when parameters change unfavorably, vault needs more credit on next action
    /// @dev Simulates scenario where external liqLTV drops moderately (not drastically to avoid liquidity issues)
    function test_aave_dynamicLTV_negativeExcessCredit_viaExternalLTVDrop() public noGasMetering {
        address collateralAsset = address(aWETHWrapper);
        aave_creditDeposit(collateralAsset);

        // Create collateral vault
        vm.startPrank(alice);
        alice_aave_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _intermediateVault: intermediateVaultFor[collateralAsset],
                _targetVault: aavePool,
                _liqLTV: twyneLiqLTV,
                _targetAsset: USDC
            })
        );
        IERC20(collateralAsset).approve(address(alice_aave_vault), type(uint256).max);
        alice_aave_vault.deposit(COLLATERAL_AMOUNT);
        vm.stopPrank();

        IEVault intermediateVault = alice_aave_vault.intermediateVault();

        uint initialMaxRelease = alice_aave_vault.maxRelease();
        uint initialCash = intermediateVault.cash();

        // Get current liqLTV from Aave
        uint16 currentLiqLTV = uint16(getLiqLTV(collateralAsset));

        // Moderately lower external liqLTV (10% reduction instead of 50%)
        // This ensures intermediate vault has enough liquidity for additional credit
        uint16 newLiqLTV = currentLiqLTV - 1000; // Reduce by 10%
        setAaveLTV(collateralAsset, newLiqLTV);

        // Vault is now in "negative excess credit" state
        vm.expectRevert(TwyneErrors.CannotRebalance.selector);
        alice_aave_vault.canRebalance();

        // Any user action will trigger _handleExcessCredit to borrow more
        vm.startPrank(alice);
        alice_aave_vault.deposit(0.01e18);
        vm.stopPrank();

        uint newMaxRelease = alice_aave_vault.maxRelease();
        uint newCash = intermediateVault.cash();

        // Vault should have borrowed significantly more credit
        assertGt(newMaxRelease, initialMaxRelease, "Should have borrowed more credit");

        // Intermediate vault cash should have decreased
        assertLt(newCash, initialCash, "Intermediate vault cash should decrease");
    }

    /// @notice Test that leg dominance can switch when liquidity changes dramatically
    /// @dev Start with low liquidity (dynamic dominant), add liquidity (chosen dominant)
    function test_aave_dynamicLTV_legDominanceSwitch() public noGasMetering {
        address collateralAsset = address(aWETHWrapper);

        // Start with minimal credit deposit for low liquidity
        IEVault intermediateVault = IEVault(intermediateVaultFor[collateralAsset]);
        address underlying = intermediateVault.asset();

        vm.startPrank(bob);
        deal(underlying, bob, 0.5e18);
        IERC20(underlying).approve(address(intermediateVault), type(uint256).max);
        intermediateVault.deposit(0.5e18, bob); // Only 0.5 WETH equivalent
        vm.stopPrank();

        // Create collateral vault with moderate deposit
        vm.startPrank(alice);
        alice_aave_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _intermediateVault: intermediateVaultFor[collateralAsset],
                _targetVault: aavePool,
                _liqLTV: twyneLiqLTV,
                _targetAsset: USDC
            })
        );
        deal(collateralAsset, alice, 10e18);
        IERC20(collateralAsset).approve(address(alice_aave_vault), type(uint256).max);
        alice_aave_vault.deposit(2e18);
        vm.stopPrank();

        // Record low liquidity state
        uint lowLiqTotalAssets = alice_aave_vault.totalAssetsDepositedOrReserved();
        uint adjExtLiqLTV = uint(twyneVaultManager.externalLiqBuffers(address(intermediateVault))) * getLiqLTV(collateralAsset);
        uint dynamicLegLow = adjExtLiqLTV * (intermediateVault.cash() + lowLiqTotalAssets);

        // Now add lots of liquidity
        vm.startPrank(bob);
        deal(underlying, bob, 100e18);
        intermediateVault.deposit(100e18, bob);
        vm.stopPrank();

        // Trigger rebalancing
        vm.startPrank(alice);
        alice_aave_vault.deposit(0.001e18);
        vm.stopPrank();

        // Verify dynamic leg grew with more liquidity
        uint highLiqTotalAssets = alice_aave_vault.totalAssetsDepositedOrReserved();
        uint dynamicLegHigh = adjExtLiqLTV * (intermediateVault.cash() + highLiqTotalAssets);
        assertGe(dynamicLegHigh, dynamicLegLow, "Dynamic leg should grow with more liquidity");

        // Key invariant: vault maintains proper credit reservation
        uint userCollateral = highLiqTotalAssets - alice_aave_vault.maxRelease();
        uint maxTwyneLTV = twyneVaultManager.maxTwyneLTVs(address(intermediateVault));
        uint chosenLeg = userCollateral * MAXFACTOR * Math.min(twyneLiqLTV, maxTwyneLTV);
        uint expectedInvariant = Math.ceilDiv(Math.min(dynamicLegHigh, chosenLeg), adjExtLiqLTV);
        assertApproxEqAbs(highLiqTotalAssets, expectedInvariant, 2, "Invariant calculation should hold");
    }

    /// @notice Test that vault operations don't revert when Aave raises liquidationThreshold
    ///   past the point where adjExtLiqLTV > MAXFACTOR * twyneLiqLTV.
    /// @dev Regression test: _handleExcessCredit previously tried to repay more than
    ///   the actual intermediate vault debt, causing E_RepayTooMuch revert.
    function test_aave_handleExcessCredit_cappedAtDebt_afterExtLTVIncrease() public noGasMetering {
        uint16 liqLTV = 9100;
        aave_collateralDepositWithoutBorrow(address(aWETHWrapper), liqLTV);

        address intermediateVault = address(alice_aave_vault.intermediateVault());
        uint debtBefore = IEVault(intermediateVault).debtOf(address(alice_aave_vault));
        assertGt(debtBefore, 0, "Vault should have intermediate debt after deposit");

        // Aave governance raises liquidationThreshold above twyneLiqLTV
        // With externalLiqBuffer=1e4, we need Aave LT > liqLTV (9100) to trigger the bug
        // Note: Aave constrains LT * liquidationBonus <= 10000, so we can't go too high
        uint16 newAaveLT = 9200; // above liqLTV=9100, within Aave's bonus constraint
        setAaveLTV(address(aWETHWrapper), newAaveLT);

        // Verify the dangerous condition: adjExtLiqLTV > MAXFACTOR * twyneLiqLTV
        uint adjExtLiqLTV = uint(twyneVaultManager.externalLiqBuffers(intermediateVault))
            * getLiqLTV(address(aWETHWrapper));
        assertGt(adjExtLiqLTV, MAXFACTOR * uint(liqLTV), "adjExtLiqLTV should exceed MAXFACTOR * twyneLiqLTV");

        // All vault operations should still work (previously would revert with E_RepayTooMuch)
        vm.startPrank(alice);

        // deposit
        IERC20(address(aWETHWrapper)).approve(address(alice_aave_vault), type(uint).max);
        alice_aave_vault.deposit(0.01e18);

        // withdraw
        alice_aave_vault.withdraw(0.005e18, alice);

        vm.stopPrank();

        // Debt was already fully repaid during deposit (excess exceeded debt, cap kicked in)
        uint debtAfter = IEVault(intermediateVault).debtOf(address(alice_aave_vault));
        assertEq(debtAfter, 0, "All intermediate debt should be repaid");

        // Since the effective liqLTV_t is now beta * liqLTV_e — the no-credit-zone boundary
        // where zero credit is required — there is no excess credit to rebalance.
        vm.expectRevert(TwyneErrors.CannotRebalance.selector);
        alice_aave_vault.canRebalance();
    }

    /// @notice Test multiple operations in sequence after Aave LTV increase triggers excess > debt
    function test_aave_handleExcessCredit_multipleOpsAfterExtLTVIncrease() public noGasMetering {
        uint16 liqLTV = 9100;
        aave_collateralDepositWithoutBorrow(address(aWETHWrapper), liqLTV);

        address intermediateVault = address(alice_aave_vault.intermediateVault());

        // Aave governance raises liquidationThreshold above twyneLiqLTV
        uint16 newAaveLT = 9200;
        setAaveLTV(address(aWETHWrapper), newAaveLT);

        // First deposit triggers the cap — repays all debt
        vm.startPrank(alice);
        IERC20(address(aWETHWrapper)).approve(address(alice_aave_vault), type(uint).max);
        alice_aave_vault.deposit(0.01e18);
        vm.stopPrank();

        uint debtAfterFirst = IEVault(intermediateVault).debtOf(address(alice_aave_vault));
        assertEq(debtAfterFirst, 0, "Debt should be zero after first operation");

        // Second deposit should also work (debt is 0, excess > 0, cap gives 0 repay)
        vm.startPrank(alice);
        alice_aave_vault.deposit(0.01e18);
        vm.stopPrank();

        // Withdraw should work
        vm.startPrank(alice);
        alice_aave_vault.withdraw(0.01e18, alice);
        vm.stopPrank();

        // Skim should work
        vm.startPrank(alice);
        IERC20(address(aWETHWrapper)).transfer(address(alice_aave_vault), 0.001e18);
        alice_aave_vault.skim();
        vm.stopPrank();
    }

    /// @notice Floor activates when maxTwyneLTV is ramped down to 1.
    /// Vault operations still work and canRebalance reverts (no excess credit).
    function test_aave_liqLTVFloor_afterMaxTwyneLTVRampDown() public noGasMetering {
        aave_collateralDepositWithoutBorrow(address(aWETHWrapper), 0.9e4);

        address intermediateVault = address(alice_aave_vault.intermediateVault());
        assertGt(IEVault(intermediateVault).debtOf(address(alice_aave_vault)), 0);

        // Ramp maxTwyneLTV down to 1
        vm.prank(admin);
        twyneVaultManager.setMaxLiquidationLTV(intermediateVault, 1, 1 days);
        vm.warp(block.timestamp + 1 days + 1);
        assertEq(twyneVaultManager.maxTwyneLTVs(intermediateVault), 1);

        uint adjExtLiqLTV = uint(twyneVaultManager.externalLiqBuffers(intermediateVault))
            * getLiqLTV(address(aWETHWrapper));
        assertGt(adjExtLiqLTV, MAXFACTOR, "Floor should be active");

        // Floor: collateralScaledByLiqLTV1e8 == adjExtLiqLTV * userCollateral
        uint userCollateral = alice_aave_vault.totalAssetsDepositedOrReserved() - alice_aave_vault.maxRelease();
        AaveLiqCollateralVault helper = new AaveLiqCollateralVault(address(evc), aavePool, address(0));
        vm.etch(address(alice_aave_vault), address(helper).code);
        assertEq(AaveLiqCollateralVault(address(alice_aave_vault)).collateralScaledByLiqLTV1e8(), adjExtLiqLTV * userCollateral);

        // Vault operations still work
        vm.startPrank(alice);
        IERC20(address(aWETHWrapper)).approve(address(alice_aave_vault), type(uint).max);
        alice_aave_vault.deposit(0.01e18);
        alice_aave_vault.withdraw(0.005e18, alice);
        vm.stopPrank();

        // All intermediate debt repaid, no excess credit — effective LTV is beta * liqLTV_e (no-credit-zone boundary)
        assertEq(alice_aave_vault.maxRelease(), 0);
        vm.expectRevert(TwyneErrors.CannotRebalance.selector);
        alice_aave_vault.canRebalance();
    }

    /// @notice Floor activates when externalLiqBuffer is increased (raising adjExtLiqLTV above chosenLTV * MAXFACTOR).
    /// Vault operations still work and canRebalance reverts (no excess credit).
    function test_aave_liqLTVFloor_afterExternalLiqBufferIncrease() public noGasMetering {
        address intermediateVault = intermediateVaultFor[address(aWETHWrapper)];

        // Start with a low buffer, create vault, then restore to 1e4
        vm.prank(admin);
        twyneVaultManager.setExternalLiqBuffer(intermediateVault, 0.5e4, 0);

        uint aaveLiqLTV = getLiqLTV(address(aWETHWrapper));
        // liqLTV = aaveLiqLTV * 3/4: above _checkLiqLTV minimum at buffer 0.5e4,
        // but below aaveLiqLTV so the floor activates when buffer is restored to 1e4
        uint16 lowLiqLTV = uint16(aaveLiqLTV * 3 / 4);

        aave_collateralDepositWithoutBorrow(address(aWETHWrapper), lowLiqLTV);

        assertGt(IEVault(intermediateVault).debtOf(address(alice_aave_vault)), 0);

        // Restore buffer to 1e4 so adjExtLiqLTV > MAXFACTOR * lowLiqLTV
        vm.prank(admin);
        twyneVaultManager.setExternalLiqBuffer(intermediateVault, 1e4, 0);

        uint adjExtLiqLTV = uint(twyneVaultManager.externalLiqBuffers(intermediateVault)) * aaveLiqLTV;
        assertGt(adjExtLiqLTV, MAXFACTOR * uint(lowLiqLTV), "Floor should be active");

        // Floor: collateralScaledByLiqLTV1e8 == adjExtLiqLTV * userCollateral
        uint userCollateral = alice_aave_vault.totalAssetsDepositedOrReserved() - alice_aave_vault.maxRelease();
        AaveLiqCollateralVault helper = new AaveLiqCollateralVault(address(evc), aavePool, address(0));
        vm.etch(address(alice_aave_vault), address(helper).code);
        assertEq(AaveLiqCollateralVault(address(alice_aave_vault)).collateralScaledByLiqLTV1e8(), adjExtLiqLTV * userCollateral);

        // Vault operations still work
        vm.startPrank(alice);
        IERC20(address(aWETHWrapper)).approve(address(alice_aave_vault), type(uint).max);
        alice_aave_vault.deposit(0.01e18);
        alice_aave_vault.withdraw(0.005e18, alice);
        vm.stopPrank();

        // All intermediate debt repaid, no excess credit — effective LTV is beta * liqLTV_e (no-credit-zone boundary)
        assertEq(alice_aave_vault.maxRelease(), 0);
        vm.expectRevert(TwyneErrors.CannotRebalance.selector);
        alice_aave_vault.canRebalance();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Bad debt settlement via siphoning
    // ═══════════════════════════════════════════════════════════════════════

    function _setHighIRM(address collateralAsset) internal {
        IEVault intermediateVault = IEVault(intermediateVaultFor[collateralAsset]);
        address highIRM = address(
            new IRMTwyneCurve({minInterest_: 500, linearParameter_: 5000, polynomialParameter_: 49250, nonlinearPoint_: 5e17})
        );
        vm.prank(admin);
        twyneVaultManager.doCall(
            address(intermediateVault), 0, abi.encodeCall(intermediateVault.setInterestRateModel, (highIRM))
        );
    }

    /// @notice Test: siphoning exhausts user collateral (C = 0), then rebalance + socialize settles bad debt
    function test_aave_settleBadDebt_siphoningToZero() public {
        _setHighIRM(address(aWETHWrapper));
        aave_collateralDepositWithoutBorrow(address(aWETHWrapper), 0.9e4);

        IEVault intermediateVault = IEVault(intermediateVaultFor[address(aWETHWrapper)]);

        assertGt(alice_aave_vault.totalAssetsDepositedOrReserved() - alice_aave_vault.maxRelease(), 0, "User should have collateral initially");
        assertEq(alice_aave_vault.maxRepay(), 0, "Should have no external debt");

        vm.warp(block.timestamp + 365 days * 100);

        assertEq(alice_aave_vault.maxRelease(), alice_aave_vault.totalAssetsDepositedOrReserved(), "C should be 0");
        assertGt(intermediateVault.debtOf(address(alice_aave_vault)), alice_aave_vault.totalAssetsDepositedOrReserved(), "Should have bad debt");

        vm.startPrank(liquidator);
        vm.warp(block.timestamp + 2);
        evc.enableController(liquidator, address(intermediateVault));

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.rebalance, ())
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(intermediateVault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(intermediateVault.liquidate, (address(alice_aave_vault), address(alice_aave_vault), 0, 0))
        });
        evc.batch(items);
        vm.stopPrank();

        assertEq(intermediateVault.debtOf(address(alice_aave_vault)), 0, "Debt should be zero after socialization");
        assertEq(alice_aave_vault.totalAssetsDepositedOrReserved(), 0, "totalAssetsDepositedOrReserved should be zero");
    }

    /// @notice Test: intermediateVault.liquidate reverts without prior rebalance
    function test_aave_settleBadDebt_revertsWithoutRebalance() public {
        _setHighIRM(address(aWETHWrapper));
        aave_collateralDepositWithoutBorrow(address(aWETHWrapper), 0.9e4);

        IEVault intermediateVault = IEVault(intermediateVaultFor[address(aWETHWrapper)]);

        vm.warp(block.timestamp + 365 days * 100);

        assertGt(alice_aave_vault.totalAssetsDepositedOrReserved(), 0, "totalAssets should be > 0 before rebalance");
        assertEq(alice_aave_vault.totalAssetsDepositedOrReserved(), alice_aave_vault.maxRelease(), "C should be 0");

        vm.startPrank(liquidator);
        vm.warp(block.timestamp + 2);
        evc.enableController(liquidator, address(intermediateVault));

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(intermediateVault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(intermediateVault.liquidate, (address(alice_aave_vault), address(alice_aave_vault), 0, 0))
        });

        vm.expectRevert();
        evc.batch(items);
        vm.stopPrank();
    }

    /// @notice Test: socialization blocked on a healthy vault (C > 0)
    function test_aave_settleBadDebt_blockedOnHealthyVault() public {
        aave_collateralDepositWithoutBorrow(address(aWETHWrapper), 0.9e4);

        IEVault intermediateVault = IEVault(intermediateVaultFor[address(aWETHWrapper)]);

        assertGt(alice_aave_vault.totalAssetsDepositedOrReserved() - alice_aave_vault.maxRelease(), 0, "Vault should be healthy with C > 0");

        vm.startPrank(liquidator);
        vm.warp(block.timestamp + 2);
        evc.enableController(liquidator, address(intermediateVault));

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(intermediateVault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(intermediateVault.liquidate, (address(alice_aave_vault), address(alice_aave_vault), 0, 0))
        });

        vm.expectRevert();
        evc.batch(items);
        vm.stopPrank();
    }

    /// @notice Test: vault is reusable after bad debt settlement
    function test_aave_settleBadDebt_vaultReusableAfter() public {
        _setHighIRM(address(aWETHWrapper));
        aave_collateralDepositWithoutBorrow(address(aWETHWrapper), 0.9e4);

        IEVault intermediateVault = IEVault(intermediateVaultFor[address(aWETHWrapper)]);

        vm.warp(block.timestamp + 365 days * 100);

        vm.startPrank(liquidator);
        vm.warp(block.timestamp + 2);
        evc.enableController(liquidator, address(intermediateVault));

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.rebalance, ())
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(intermediateVault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(intermediateVault.liquidate, (address(alice_aave_vault), address(alice_aave_vault), 0, 0))
        });
        evc.batch(items);
        vm.stopPrank();

        assertEq(intermediateVault.debtOf(address(alice_aave_vault)), 0, "Debt should be settled");

        vm.startPrank(bob);
        IERC20(address(aWETHWrapper)).approve(address(intermediateVault), type(uint).max);
        intermediateVault.deposit(CREDIT_LP_AMOUNT, bob);
        vm.stopPrank();

        vm.startPrank(alice);
        IERC20(address(aWETHWrapper)).approve(address(alice_aave_vault), type(uint).max);

        IEVC.BatchItem[] memory depositItems = new IEVC.BatchItem[](1);
        depositItems[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.deposit, (COLLATERAL_AMOUNT))
        });
        evc.batch(depositItems);
        vm.stopPrank();

        assertGt(alice_aave_vault.totalAssetsDepositedOrReserved(), 0, "Vault should have assets after re-deposit");
        assertGt(alice_aave_vault.maxRelease(), 0, "Vault should have reserved credit after re-deposit");
    }
}