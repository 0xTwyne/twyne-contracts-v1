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
        return _getExtLiqLTV(address(0));
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
        uint16 extLiqBuffer = twyneVaultManager.externalLiqBuffers(collateral);
        vm.assume(uint(minLTV) * uint(extLiqBuffer) <= uint256(liqLTV) * MAXFACTOR);
        vm.assume(liqLTV <= twyneVaultManager.maxTwyneLTVs(collateral));
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
                _asset: collateral,
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

        // Assume the user max borrows to arrive at the extreme limit of what is possible without liquidation
        vm.startPrank(alice);

        // Use the first liquidation condition in _canLiquidate

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
        alice_aave_vault.borrow(BORROW_USD_AMOUNT, alice);

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
        address collateralAsset = address(aWETHWrapper);
        // Borrow using the exact amounts of an older test setup
        vm.startPrank(alice);
        // IERC20(collateralAsset).approve(address(alice_aave_vault), type(uint).max);
        // IERC20(USDC).approve(address(alice_aave_vault), type(uint).max);
        // alice_aave_vault.deposit(5 ether);

        // alice_aave_vault.borrow(6983982500, alice);
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
                _asset: address(aWETHWrapper),
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
                _asset: address(aUSDCWrapper),
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
                _asset: address(aWETHWrapper),
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
        collateralVaultFactory.pause(true);
        vm.stopPrank();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _asset: collateralAsset,
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
        collateralVaultFactory.pause(false);
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
                _asset: collateralAsset,
                _targetVault: aavePool,
                _liqLTV: 0.94e4,
                _targetAsset: WETH
            })
        );

        AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _asset: collateralAsset,
                _targetVault: aavePool,
                _liqLTV: 0.95e4,
                _targetAsset: WETH
            })
        );

    }

    // Test that non-collateral vault accounts are blocked by BridgeHookTarget (not CreditRiskManager)
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
                _asset: address(aWETHWrapper),
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
        uint userCollateral = targetAssetPrice * (_maxRepay * MAXFACTOR / twyneVaultManager.maxTwyneLTVs(address(__asset)))
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

}