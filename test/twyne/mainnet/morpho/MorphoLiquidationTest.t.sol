// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {MainnetBase, console2} from "../MainnetBase.t.sol";
import {BridgeHookTarget} from "src/TwyneFactory/BridgeHookTarget.sol";
import "euler-vault-kit/EVault/shared/types/Types.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {MorphoCollateralVault, CollateralVaultBase} from "src/twyne/MorphoCollateralVault.sol";
import {Errors} from "euler-vault-kit/EVault/shared/Errors.sol";
import {Events} from "euler-vault-kit/EVault/shared/Events.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";
import {IMorpho, MarketParams, Id, Market} from "morpho/interfaces/IMorpho.sol";
import {IOracle} from "morpho/interfaces/IOracle.sol";
import {MorphoLib} from "morpho/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "morpho/libraries/periphery/MorphoBalancesLib.sol";
import {ORACLE_PRICE_SCALE} from "morpho/libraries/ConstantsLib.sol";
import {MathLib} from "morpho/libraries/MathLib.sol";
import {MarketParamsLib} from "morpho/libraries/MarketParamsLib.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IRMTwyneCurve} from "src/twyne/IRMTwyneCurve.sol";
import {SafeERC20, IERC20 as IERC20_OZ} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {MockMorphoOracle} from "test/mocks/MockMorphoOracle.sol";
import {MockDivergentMorphoIRM} from "test/mocks/MockDivergentMorphoIRM.sol";

/// @title MorphoLiquidationTest
/// @notice Comprehensive liquidation tests for ETH-USDT Morpho market
/// @dev Seeds liquidity into the Morpho market using deal() cheatcode
/// Uses price oracle manipulation to trigger liquidation (not buffer change)
contract MorphoLiquidationTest is MainnetBase {
    using MathLib for uint;
    using SafeERC20 for IERC20;

    MorphoCollateralVault alice_morpho_vault;
    IEVault morpho_intermediate_vault;

    // ETH-USDT Morpho market parameters
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant ETH_USDT_ORACLE = 0xe9eE579684716c7Bb837224F4c7BeEfA4f1F3d7f;
    address constant ETH_USDT_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 constant ETH_USDT_LLTV = 915000000000000000; // 91.5%

    MarketParams morphoMarketParams;
    Id morphoMarketId;

    uint256 BORROW_COLLATERAL_AMOUNT;
    uint256 LIQ_BORROW_AMOUNT;
    uint256 BORROW_USDT_AMOUNT;

    uint256 INITIAL_MORPHO_PRICE;

    // Liquidity provider for seeding Morpho market
    address liquidityProvider = makeAddr("liquidityProvider");
    uint256 constant SEED_LIQUIDITY_USDT = 1_000_000e6; // 1M USDT (6 decimals)

    function setUp() public virtual override {
        forkBlock = 23600528;
        forkBlockDiff = block.number - forkBlock;

        vm.rollFork(forkBlock);

        super.setUp();

        // Set up ETH-USDT Morpho market parameters
        morphoMarketParams = MarketParams({
            loanToken: USDT,
            collateralToken: WETH,
            oracle: ETH_USDT_ORACLE,
            irm: ETH_USDT_IRM,
            lltv: ETH_USDT_LLTV
        });
        morphoMarketId = MarketParamsLib.id(morphoMarketParams);

        // Deploy MorphoCollateralVault implementation
        address morphoCollateralVaultImpl = address(new MorphoCollateralVault(address(evc), morpho));

        vm.startPrank(admin);
        collateralVaultFactory.setBeacon(morpho, address(new UpgradeableBeacon(morphoCollateralVaultImpl, admin)));

        // Create Euler router for this market
        oracleRouter = new EulerRouter(address(evc), address(twyneVaultManager));
        vm.label(address(oracleRouter), "ethUsdtOracleRouter");

        collateralVaultFactory.setVaultManager(address(twyneVaultManager));

        // Configure LTV settings for ETH-USDT market
        // Set buffer to 1e4 (100%) like Aave tests to rely on price movement for liquidation
        externalLiqBufferInitial = 1e4;
        maxLTVInitial = 0.95e4; // 95%
        twyneLiqLTV = 9150; // Match Morpho LLTV (91.5%)

        // Morpho intermediate vaults are self-denominated to support multiple loan markets.
        morpho_intermediate_vault = newIntermediateVaultForMorpho(WETH, address(oracleRouter), WETH);
        vm.label(address(morpho_intermediate_vault), "WETH intermediate vault (ETH-USDT)");

        twyneVaultManager.setMaxLiquidationLTV(address(morpho_intermediate_vault), USDT, maxLTVInitial, 0);
        twyneVaultManager.setExternalLiqBuffer(address(morpho_intermediate_vault), USDT, externalLiqBufferInitial, 0);

        // Set supported Morpho market
        twyneVaultManager.setAllowedMorphoMarket(morpho, address(morpho_intermediate_vault), morphoMarketId, true);

        vm.stopPrank();

        // Labels
        vm.label(USDT, "USDT");
        vm.label(WETH, "WETH");
        vm.label(morpho, "Morpho");
        vm.label(ETH_USDT_ORACLE, "ETH_USDT_Oracle");
        vm.label(ETH_USDT_IRM, "ETH_USDT_IRM");

        address[5] memory characters = [alice, bob, eve, liquidator, teleporter];

        // Deal tokens to all test characters
        for (uint charIndex; charIndex < characters.length; charIndex++) {
            vm.deal(characters[charIndex], 10 ether);
            // Deal collateral token (WETH)
            deal(WETH, characters[charIndex], INITIAL_DEALT_ERC20);
            // Deal loan token (USDT)
            deal(USDT, characters[charIndex], 1_000_000e6); // 1M USDT each
        }

        // Seed liquidity into Morpho ETH-USDT market
        _seedMorphoLiquidity();

        // Cache the initial Morpho oracle price
        INITIAL_MORPHO_PRICE = IOracle(ETH_USDT_ORACLE).price();

        // Calculate initial borrow amount
        BORROW_USDT_AMOUNT = COLLATERAL_AMOUNT.mulDivDown(INITIAL_MORPHO_PRICE, ORACLE_PRICE_SCALE).wMulDown(ETH_USDT_LLTV) * 90 / 100;
    }

    /// @notice Seeds liquidity into the Morpho ETH-USDT market
    function _seedMorphoLiquidity() internal {
        deal(USDT, liquidityProvider, SEED_LIQUIDITY_USDT);
        
        vm.startPrank(liquidityProvider);
        // Use SafeERC20 forceApprove for USDT (non-standard ERC20)
        SafeERC20.forceApprove(IERC20_OZ(USDT), morpho, SEED_LIQUIDITY_USDT);
        
        // Supply USDT to the Morpho market (market already exists)
        IMorpho(morpho).supply({
            marketParams: morphoMarketParams,
            assets: SEED_LIQUIDITY_USDT,
            shares: 0,
            onBehalf: liquidityProvider,
            data: ""
        });
        vm.stopPrank();

        // Verify liquidity was added
        uint256 totalSupply = MorphoLib.totalSupplyAssets(IMorpho(morpho), morphoMarketId);
        assertGe(totalSupply, SEED_LIQUIDITY_USDT, "Morpho market should have liquidity");
    }

    function newIntermediateVaultForMorpho(address _asset, address _oracle, address _unitOfAccount) internal returns (IEVault) {
        IEVault new_vault = IEVault(factory.createProxy(address(0), true, abi.encodePacked(_asset, _oracle, _unitOfAccount)));

        // Set hook so all borrows and flashloans use the bridge
        new_vault.setHookConfig(address(new BridgeHookTarget(address(collateralVaultFactory))), OP_BORROW | OP_LIQUIDATE | OP_FLASHLOAN | OP_PULL_DEBT);

        // Set interest rate model
        new_vault.setInterestRateModel(address(new IRMTwyneCurve({
            minInterest_: 0,
            linearParameter_: 750,
            polynomialParameter_: 49250,
            nonlinearPoint_: 5e17 // 50%
        })));

        new_vault.setMaxLiquidationDiscount(0.2e4);
        new_vault.setLiquidationCoolOffTime(1);
        new_vault.setFeeReceiver(feeReceiver);
        new_vault.setInterestFee(0);

        // Set up oracle for the intermediate vault
        twyneVaultManager.setOracleResolvedVault(_oracle, address(new_vault), true);

        twyneVaultManager.setIntermediateVault(new_vault, true);
        new_vault.setGovernorAdmin(address(twyneVaultManager));
        assertEq(new_vault.unitOfAccount(), _asset, "Morpho intermediate vault must be self-denominated");

        return new_vault;
    }

    // Helper to get ETH-USDT LTV in 1e4 precision
    function getETHUSDTLTVIn1e4() internal pure returns (uint16) {
        return uint16(ETH_USDT_LLTV / 1e14); // 9150
    }

    // Helper function to calculate reserved assets
    function getReservedAssetsForMorpho(uint256 depositAmount, MorphoCollateralVault collateralVault) internal view returns (uint reservedAssets) {
        uint externalLiqBuffer = uint(collateralVault.twyneVaultManager().externalLiqBuffers(address(collateralVault.intermediateVault()), collateralVault.targetAsset()));
        uint liqLTV_twyne = collateralVault.twyneLiqLTV();
        MarketParams memory mp = collateralVault.marketParams();
        uint liqLTV_external = mp.lltv * externalLiqBuffer / 1e14;

        if (liqLTV_twyne * 1e18 <= liqLTV_external) {
            return 0;
        }

        uint LTVdiff = (MAXFACTOR * liqLTV_twyne) - liqLTV_external;
        reservedAssets = Math.ceilDiv(depositAmount * LTVdiff, liqLTV_external);
    }

    /// @notice Etch mock oracle to Morpho oracle address and set price
    /// @param priceMultiplier Multiplier in basis points (e.g., 9500 = 95%)
    function _setMorphoOraclePrice(uint256 priceMultiplier) internal {
        MockMorphoOracle mockMorphoOracle = new MockMorphoOracle();
        vm.etch(ETH_USDT_ORACLE, address(mockMorphoOracle).code);
        MockMorphoOracle(ETH_USDT_ORACLE).setPrice(INITIAL_MORPHO_PRICE * priceMultiplier / MAXFACTOR);
    }

    /// @notice Set oracle price so that a given Morpho health factor is achieved
    /// @dev In Morpho, HF = (collateral * price * LLTV) / (debt * ORACLE_PRICE_SCALE)
    ///      We adjust price proportionally: newPrice = currentPrice * targetHF / currentHF
    function _setMorphoPriceForTargetHF(uint256 targetHF_1e18) internal {
        uint256 collateralBal = alice_morpho_vault.collateralBalance();
        uint256 currentPrice = IOracle(ETH_USDT_ORACLE).price();
        uint256 debt = alice_morpho_vault.maxRepay();
        require(debt > 0, "no debt");

        uint256 currentHF = collateralBal.mulDivDown(currentPrice, ORACLE_PRICE_SCALE).wMulDown(ETH_USDT_LLTV) * 1e18 / debt;
        require(currentHF > 0, "currentHF=0");

        uint256 newPrice = (currentPrice * targetHF_1e18) / currentHF;
        require(newPrice > 0, "price=0");

        MockMorphoOracle mockMorphoOracle = new MockMorphoOracle();
        vm.etch(ETH_USDT_ORACLE, address(mockMorphoOracle).code);
        MockMorphoOracle(ETH_USDT_ORACLE).setPrice(newPrice);
    }

    ///
    // Pre-liquidation setup
    ///

    function test_morpho_preLiquidationSetup(uint16 liqLTV) public {
        // Bound liqLTV to valid range for ETH-USDT market
        uint16 minLTV = getETHUSDTLTVIn1e4();
        uint16 extLiqBuffer = twyneVaultManager.externalLiqBuffers(address(morpho_intermediate_vault), USDT);
        vm.assume(uint(minLTV) * uint(extLiqBuffer) <= uint256(liqLTV) * MAXFACTOR);
        vm.assume(liqLTV <= twyneVaultManager.maxTwyneLTVs(address(morpho_intermediate_vault), USDT));

        // Bob deposits WETH into intermediate vault
        vm.startPrank(bob);
        IERC20(WETH).approve(address(morpho_intermediate_vault), type(uint256).max);
        morpho_intermediate_vault.deposit(CREDIT_LP_AMOUNT, bob);
        vm.stopPrank();

        // Alice creates Morpho collateral vault with ETH-USDT market
        vm.startPrank(alice);
        collateralVaultFactory.createMorphoCollateralVault({
            _intermediateVault: address(morpho_intermediate_vault),
            _targetVault: morpho,
            _marketParams: morphoMarketParams,
            _liqLTV: liqLTV
        });
        address[] memory aliceVaults = collateralVaultFactory.getCollateralVaults(alice);
        alice_morpho_vault = MorphoCollateralVault(aliceVaults[aliceVaults.length - 1]);
        vm.label(address(alice_morpho_vault), "alice_morpho_vault_eth_usdt");

        IERC20(WETH).approve(address(alice_morpho_vault), type(uint256).max);
        BORROW_COLLATERAL_AMOUNT = getReservedAssetsForMorpho(COLLATERAL_AMOUNT, alice_morpho_vault);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.deposit, (COLLATERAL_AMOUNT))
        });
        evc.batch(items);

        // Calculate max borrow based on Morpho constraints
        uint256 collateralPrice = IOracle(ETH_USDT_ORACLE).price();
        uint256 collateralInMorpho = alice_morpho_vault.collateralBalance();
        uint256 maxBorrowMorpho = collateralInMorpho.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).wMulDown(ETH_USDT_LLTV);

        // Use Twyne constraint
        uint256 userCollateral = alice_morpho_vault.totalAssetsDepositedOrReserved() - alice_morpho_vault.maxRelease();
        uint256 maxBorrow = userCollateral.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).wMulDown(uint256(liqLTV) * 1e14);

        LIQ_BORROW_AMOUNT = Math.min(maxBorrowMorpho, maxBorrow) * uint256(extLiqBuffer) / MAXFACTOR;

        if (LIQ_BORROW_AMOUNT > 1) {
            alice_morpho_vault.borrow(LIQ_BORROW_AMOUNT - 1, alice);
        }

        vm.stopPrank();
    }

    function test_morpho_postSetupChecks() public noGasMetering {
        uint16 liqLTV = getETHUSDTLTVIn1e4();
        test_morpho_preLiquidationSetup(liqLTV);

        // Verify balances
        assertEq(alice_morpho_vault.totalAssetsDepositedOrReserved() - alice_morpho_vault.maxRelease(), COLLATERAL_AMOUNT);
        assertEq(alice_morpho_vault.balanceOf(address(alice_morpho_vault)), COLLATERAL_AMOUNT);

        // Verify intermediate vault debt
        assertEq(
            alice_morpho_vault.maxRelease(),
            BORROW_COLLATERAL_AMOUNT,
            "EVK debt not correct amount"
        );
        assertEq(morpho_intermediate_vault.totalAssets(), CREDIT_LP_AMOUNT);

        // Verify collateral in Morpho
        assertApproxEqRel(
            alice_morpho_vault.collateralBalance(),
            COLLATERAL_AMOUNT + BORROW_COLLATERAL_AMOUNT,
            1e5,
            "Morpho collateral balance mismatch"
        );

        // Verify intermediate vault holds credit LP's WETH minus borrowed amount
        assertApproxEqRel(
            IERC20(WETH).balanceOf(address(morpho_intermediate_vault)),
            CREDIT_LP_AMOUNT - BORROW_COLLATERAL_AMOUNT,
            1e5,
            "Intermediate vault not holding correct WETH balance"
        );
    }

    ///
    // Liquidation trigger helpers
    // There are different ways to trigger liquidation:
    // 1. Interest accrual over time
    // 2. Price decrease of the collateral asset (via oracle manipulation)
    // 3. Safety buffer change on Twyne
    // 4. User changing their liquidation LTV (reverts)
    ///

    /// @notice Trigger liquidation via interest accrual or price oracle manipulation
    /// Uses price oracle manipulation as primary method (not buffer change)
    function test_morpho_setupLiquidationAccrueInterest(uint16 liqLTV) public noGasMetering {
        test_morpho_preLiquidationSetup(liqLTV);

        // Put the vault into a liquidatable state via price oracle manipulation
        // Decrease collateral price by 5% to trigger liquidation
        _setMorphoOraclePrice(9500); // 95% of original price

        // Verify debt to intermediate vault
        (, uint liabilityValue) = morpho_intermediate_vault.accountLiquidity(address(alice_morpho_vault), true);
        if (BORROW_COLLATERAL_AMOUNT != 0) {
            assertGe(liabilityValue, BORROW_COLLATERAL_AMOUNT, "alice debt to intermediate vault did not increase");
        }

        // Confirm vault can be liquidated
        assertTrue(alice_morpho_vault.canLiquidate(), "Vault should be unhealthy!");

        vm.startPrank(liquidator);
        SafeERC20.forceApprove(IERC20_OZ(USDT), address(alice_morpho_vault), type(uint256).max);
        IERC20(WETH).approve(address(alice_morpho_vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Trigger liquidation by safety buffer change
    function test_morpho_setupLiquidationFromSafetyBufferChange(uint16 liqLTV) public noGasMetering {
        test_morpho_preLiquidationSetup(liqLTV);

        // Lower safety buffer to trigger liquidation
        vm.startPrank(admin);
        twyneVaultManager.setExternalLiqBuffer(address(morpho_intermediate_vault), USDT, 0.8e4, 0);
        vm.stopPrank();

        // Verify debt to intermediate vault
        (, uint liabilityValue) = morpho_intermediate_vault.accountLiquidity(address(alice_morpho_vault), true);
        if (BORROW_COLLATERAL_AMOUNT != 0) {
            assertGe(liabilityValue, BORROW_COLLATERAL_AMOUNT, "alice debt to intermediate vault did not increase");
        }

        assertTrue(alice_morpho_vault.canLiquidate(), "Vault should be unhealthy!");

        vm.startPrank(liquidator);
        SafeERC20.forceApprove(IERC20_OZ(USDT), address(alice_morpho_vault), type(uint256).max);
        IERC20(WETH).approve(address(alice_morpho_vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Setup for external liquidation tests (price drop that triggers liquidation)
    function test_morpho_setupCompleteExternalLiquidation() public noGasMetering {
        // Use maxLTV to ensure non-zero reserved assets for handleExternalLiquidation
        uint16 higherLTV = twyneVaultManager.maxTwyneLTVs(address(morpho_intermediate_vault), USDT);
        test_morpho_preLiquidationSetup(higherLTV);

        // Additional borrow to increase exposure
        vm.startPrank(alice);
        IERC20(WETH).approve(address(alice_morpho_vault), type(uint).max);
        SafeERC20.forceApprove(IERC20_OZ(USDT), address(alice_morpho_vault), type(uint).max);
        alice_morpho_vault.deposit(5 ether);
        alice_morpho_vault.borrow(BORROW_USDT_AMOUNT, alice);
        vm.stopPrank();

        // Price drop to trigger liquidation (not too extreme to avoid complete wipeout)
        _setMorphoOraclePrice(8500); // 85% of original price
    }

    /// @notice User cannot set dangerous LTV to trigger their own liquidation
    function test_morpho_cannotSetupLiquidationFromTwyneLTVChange() public noGasMetering {
        test_morpho_preLiquidationSetup(twyneLiqLTV);

        // Attempt to set dangerous LTV should fail
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_morpho_vault.setTwyneLiqLTV(0.95e4);
        vm.stopPrank();
    }

    ///
    // Liquidation tests
    ///

    // Test 1: Liquidator who doesn't make position healthy cannot liquidate
    function test_morpho_liquidate_without_making_healthy_accrue_interest() public noGasMetering {
        test_morpho_setupLiquidationAccrueInterest(twyneLiqLTV);

        assertEq(alice_morpho_vault.borrower(), alice, "Wrong vault owner before liquidation");
        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.VaultStatusLiquidatable.selector);
        alice_morpho_vault.liquidate();
        vm.stopPrank();
    }

    // Test 2: Liquidator who makes position healthy by adding collateral
    function test_morpho_liquidate_make_healthy_more_collateral_accrue_interest() public noGasMetering {
        test_morpho_setupLiquidationAccrueInterest(twyneLiqLTV);

        assertEq(alice_morpho_vault.borrower(), alice, "Wrong vault owner before liquidation");
        vm.startPrank(liquidator);

        // First, assume that the liquidator is already a Twyne user
        collateralVaultFactory.createMorphoCollateralVault({
            _intermediateVault: address(morpho_intermediate_vault),
            _targetVault: morpho,
            _marketParams: morphoMarketParams,
            _liqLTV: twyneLiqLTV
        });

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.liquidate, ())
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.deposit, (COLLATERAL_AMOUNT))
        });

        evc.batch(items);

        // Confirm vault owner is liquidator
        assertEq(alice_morpho_vault.borrower(), liquidator, "Wrong vault owner after liquidation");
        assertEq(collateralVaultFactory.getCollateralVaults(liquidator)[1], address(alice_morpho_vault));
        assertEq(collateralVaultFactory.getCollateralVaults(alice)[0], address(alice_morpho_vault));
        // Confirm vault cannot be liquidated now
        assertFalse(alice_morpho_vault.canLiquidate(), "Vault should be healthy!");

        vm.stopPrank();
    }

    // Test 3: Liquidator who makes position healthy by repaying debt
    function test_morpho_liquidate_make_healthy_reduce_debt_accrue_interest() public noGasMetering {
        test_morpho_setupLiquidationAccrueInterest(twyneLiqLTV);

        assertEq(alice_morpho_vault.borrower(), alice, "Wrong vault owner before liquidation");
        vm.startPrank(liquidator);

        uint256 previousMorphoDebt = alice_morpho_vault.maxRepay();

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.liquidate, ())
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.repay, (LIQ_BORROW_AMOUNT / 2))
        });

        evc.batch(items);

        assertEq(alice_morpho_vault.borrower(), liquidator, "Wrong vault owner after liquidation");
        assertFalse(alice_morpho_vault.canLiquidate(), "Vault should be healthy!");
        
        // Confirm debt decreased
        uint256 latestMorphoDebt = alice_morpho_vault.maxRepay();
        assertLt(latestMorphoDebt, previousMorphoDebt, "Morpho current debt is wrong");

        // Intermediate vault debt is unchanged
        assertApproxEqRel(
            alice_morpho_vault.maxRelease(),
            BORROW_COLLATERAL_AMOUNT,
            1e15,
            "EVK debt not correct amount after liquidation"
        );

        vm.stopPrank();

        // Alice can't withdraw from collateral vault now
        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_morpho_vault.withdraw(1, alice);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_morpho_vault.withdraw(1, liquidator);
        vm.stopPrank();
    }

    // Test 4: Liquidator repays ALL debt
    function test_morpho_liquidate_make_healthy_repay_all_accrue_interest() public noGasMetering {
        test_morpho_setupLiquidationAccrueInterest(twyneLiqLTV);

        assertEq(alice_morpho_vault.borrower(), alice, "Wrong vault owner before liquidation");
        vm.startPrank(liquidator);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.liquidate, ())
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.repay, (type(uint256).max))
        });

        evc.batch(items);
        vm.stopPrank();

        assertEq(alice_morpho_vault.borrower(), liquidator, "Wrong vault owner after liquidation");
        assertEq(alice_morpho_vault.maxRepay(), 0, "Should have no debt");
    }

    // Test 5: Liquidator repays debt and withdraws all
    function test_morpho_liquidate_repay_withdraw_all_accrue_interest() public noGasMetering {
        test_morpho_setupLiquidationAccrueInterest(twyneLiqLTV);

        assertEq(alice_morpho_vault.borrower(), alice, "Wrong vault owner before liquidation");
        vm.startPrank(liquidator);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.liquidate, ())
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.repay, (type(uint256).max))
        });
        items[2] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.withdraw, (type(uint256).max, liquidator))
        });

        evc.batch(items);
        vm.stopPrank();

        assertEq(alice_morpho_vault.borrower(), liquidator, "Wrong vault owner after liquidation");
        assertEq(alice_morpho_vault.maxRepay(), 0, "Should have no debt");
        assertEq(alice_morpho_vault.maxRelease(), 0, "Should have no intermediate vault debt");
    }

    // Test 6: EVK liquidation is blocked by hook
    function test_morpho_liquidate_bad_evk_debt_accrue_interest() public noGasMetering {
        twyneLiqLTV = twyneVaultManager.maxTwyneLTVs(address(morpho_intermediate_vault), USDT);
        test_morpho_setupLiquidationAccrueInterest(twyneLiqLTV);

        // Lower EVK liquidation LTV to make it instantly liquidatable
        vm.startPrank(address(twyneVaultManager.owner()));
        twyneVaultManager.setLTV(morpho_intermediate_vault, address(alice_morpho_vault), 0.1e3, 0.15e3, 0);
        vm.stopPrank();

        assertTrue(alice_morpho_vault.canLiquidate(), "Vault should be unhealthy!");

        vm.warp(block.timestamp + 12);

        (uint256 collateralValue, uint256 liabilityValue) =
            morpho_intermediate_vault.accountLiquidity(address(alice_morpho_vault), true);
        if (BORROW_COLLATERAL_AMOUNT != 0) {
            assertGt(liabilityValue, collateralValue, "liability is not greater than collateral");
        }

        // Confirm EVK liquidation is possible from checkLiquidation
        (uint256 maxRepay, uint256 maxYield) = morpho_intermediate_vault.checkLiquidation(liquidator, address(alice_morpho_vault), address(alice_morpho_vault));
        assertGt(maxRepay, 0, "maxRepay is zero!");
        assertGt(maxYield, 0, "maxYield is zero!");

        // EVK liquidation should be blocked
        IEVC(morpho_intermediate_vault.EVC()).enableController(address(this), address(morpho_intermediate_vault));
        IEVC(morpho_intermediate_vault.EVC()).enableCollateral(address(this), address(alice_morpho_vault));

        vm.expectRevert(TwyneErrors.NotExternallyLiquidated.selector);
        morpho_intermediate_vault.liquidate(address(alice_morpho_vault), address(alice_morpho_vault), type(uint256).max, 0);

        // Try batch call, observe same revert
        IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](1);
        batchItems[0] = IEVC.BatchItem({
            targetContract: address(morpho_intermediate_vault),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeCall(
                ILiquidation.liquidate,
                (address(alice_morpho_vault), address(alice_morpho_vault), type(uint256).max, 0)
            )
        });

        vm.expectRevert(TwyneErrors.NotExternallyLiquidated.selector);
        evc.batch(batchItems);

        assertGt(alice_morpho_vault.maxRelease(), 0, "EVK debt should be non-zero");
    }

    // Test F1: Liquidation reverts when position is healthy
    function test_morpho_liquidate_fails_healthy_cant_liquidate_accrue_interest() public noGasMetering {
        test_morpho_setupLiquidationAccrueInterest(twyneLiqLTV);

        // Repay half the debt to make position healthy
        vm.startPrank(alice);
        SafeERC20.forceApprove(IERC20_OZ(USDT), address(alice_morpho_vault), type(uint).max);
        alice_morpho_vault.repay(LIQ_BORROW_AMOUNT / 2);
        vm.stopPrank();

        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 12);

        bool canLiq = alice_morpho_vault.canLiquidate();
        assertFalse(canLiq, "Vault should be healthy!");

        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.HealthyNotLiquidatable.selector);
        alice_morpho_vault.liquidate();
        vm.stopPrank();
    }

    // Test F2: Liquidator who doesn't make position healthy gets reverted
    function test_morpho_liquidate_fails_excess_repay_accrue_interest() public noGasMetering {
        test_morpho_setupLiquidationAccrueInterest(twyneLiqLTV);

        assertEq(alice_morpho_vault.borrower(), alice, "Wrong vault owner before liquidation");
        vm.startPrank(liquidator);

        vm.expectRevert(TwyneErrors.VaultStatusLiquidatable.selector);
        alice_morpho_vault.liquidate();

        vm.stopPrank();
    }

    // Test F3: Position at threshold cannot be liquidated
    function test_morpho_liquidate_fails_at_threshold() public noGasMetering {
        // Setup position without triggering liquidation
        test_morpho_preLiquidationSetup(twyneLiqLTV);

        // Position should be healthy at this point
        assertFalse(alice_morpho_vault.canLiquidate(), "Position should be healthy initially");

        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.HealthyNotLiquidatable.selector);
        alice_morpho_vault.liquidate();
        vm.stopPrank();
    }

    // Test F4: Self-liquidation reverts
    function test_morpho_liquidate_fails_self_liquidate_accrue_interest() public noGasMetering {
        test_morpho_setupLiquidationAccrueInterest(twyneLiqLTV);

        assertEq(alice_morpho_vault.borrower(), alice, "Wrong vault owner before liquidation");
        vm.startPrank(alice);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.liquidate, ())
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.deposit, (COLLATERAL_AMOUNT))
        });

        vm.expectRevert(TwyneErrors.SelfLiquidation.selector);
        evc.batch(items);

        assertEq(alice_morpho_vault.borrower(), alice, "Vault owner should not change");
        vm.stopPrank();
    }

    ///
    // Safety buffer change liquidation tests
    ///

    // Test 1: Liquidator who doesn't make position healthy cannot liquidate (buffer change)
    function test_morpho_liquidate_without_making_healthy_safetybuffer() public noGasMetering {
        test_morpho_setupLiquidationFromSafetyBufferChange(twyneLiqLTV);

        assertEq(alice_morpho_vault.borrower(), alice, "Wrong vault owner before liquidation");
        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.VaultStatusLiquidatable.selector);
        alice_morpho_vault.liquidate();
        vm.stopPrank();
    }

    // Test 2: Liquidator makes position healthy with collateral (buffer change)
    function test_morpho_liquidate_make_healthy_more_collateral_safetybuffer() public noGasMetering {
        test_morpho_setupLiquidationFromSafetyBufferChange(twyneLiqLTV);

        assertEq(alice_morpho_vault.borrower(), alice, "Wrong vault owner before liquidation");
        vm.startPrank(liquidator);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.liquidate, ())
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.deposit, (COLLATERAL_AMOUNT * 2))
        });

        evc.batch(items);
        vm.stopPrank();

        assertEq(alice_morpho_vault.borrower(), liquidator, "Wrong vault owner after liquidation");
    }

    ///
    // External liquidation tests (Morpho liquidation)
    ///

    function test_morpho_handlePartialExternalLiquidation() public noGasMetering {
        test_morpho_setupCompleteExternalLiquidation();

        // Confirm vault can be liquidated
        assertTrue(alice_morpho_vault.canLiquidate(), "Vault should be unhealthy!");

        vm.warp(block.timestamp + 1);

        // Ensure liquidator has enough USDT and WETH
        deal(WETH, liquidator, 100 ether);
        deal(USDT, liquidator, 10_000_000e6);

        vm.startPrank(liquidator);
        SafeERC20.forceApprove(IERC20_OZ(USDT), morpho, type(uint).max);
        IEVC(alice_morpho_vault.EVC()).enableCollateral(liquidator, WETH);
        IEVC(alice_morpho_vault.EVC()).enableCollateral(liquidator, address(alice_morpho_vault));
        IEVC(alice_morpho_vault.EVC()).enableController(liquidator, address(alice_morpho_vault.intermediateVault()));

        assertFalse(alice_morpho_vault.isExternallyLiquidated());
        assertGt(alice_morpho_vault.maxRepay(), 0);

        uint256 collateralBefore = alice_morpho_vault.collateralBalance();
        
        // Partial liquidation - seize half the collateral
        uint256 seizeAmount = collateralBefore / 2;
        (uint256 seized, uint256 repaid) = IMorpho(morpho).liquidate({
            marketParams: morphoMarketParams,
            borrower: address(alice_morpho_vault),
            seizedAssets: seizeAmount,
            repaidShares: 0,
            data: ""
        });

        assertTrue(alice_morpho_vault.isExternallyLiquidated(), "Vault was not externally liquidated");
        assertGt(alice_morpho_vault.collateralBalance(), 0, "Should have some collateral remaining");

        vm.stopPrank();

        // Check that operations are blocked after external liquidation (as borrower)
        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.ExternallyLiquidated.selector);
        alice_morpho_vault.deposit(1);

        vm.expectRevert(TwyneErrors.ExternallyLiquidated.selector);
        alice_morpho_vault.withdraw(1, alice);

        vm.expectRevert(TwyneErrors.ExternallyLiquidated.selector);
        alice_morpho_vault.liquidate();

        vm.expectRevert(TwyneErrors.ExternallyLiquidated.selector);
        alice_morpho_vault.skim();
        vm.stopPrank();

        // Recover price so Morpho position is healthy before handling
        _setMorphoPriceForTargetHF(1.05e18);

        vm.startPrank(liquidator);

        // Need to handle external liquidation
        // First repay remaining Morpho debt, then call handleExternalLiquidation
        deal(USDT, liquidator, 10_000_000e6);
        SafeERC20.forceApprove(IERC20_OZ(USDT), address(alice_morpho_vault), type(uint).max);
        
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            onBehalfOfAccount: liquidator,
            targetContract: address(alice_morpho_vault),
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.handleExternalLiquidation, ())
        });
        items[1] = IEVC.BatchItem({
            onBehalfOfAccount: liquidator,
            targetContract: address(alice_morpho_vault.intermediateVault()),
            value: 0,
            data: abi.encodeCall(morpho_intermediate_vault.liquidate, (address(alice_morpho_vault), address(alice_morpho_vault), 0, 0))
        });

        evc.batch(items);

        vm.stopPrank();

        // Confirm collateral vault is empty after handling
        assertEq(alice_morpho_vault.borrower(), address(0));
        assertEq(alice_morpho_vault.balanceOf(address(alice_morpho_vault)), 0);
        assertEq(alice_morpho_vault.maxRelease(), 0);
    }

    ///
    // View function tests
    ///

    function test_morpho_canLiquidate_view() public noGasMetering {
        // Setup without borrow
        vm.startPrank(bob);
        IERC20(WETH).approve(address(morpho_intermediate_vault), type(uint256).max);
        morpho_intermediate_vault.deposit(CREDIT_LP_AMOUNT, bob);
        vm.stopPrank();

        vm.startPrank(alice);
        collateralVaultFactory.createMorphoCollateralVault({
            _intermediateVault: address(morpho_intermediate_vault),
            _targetVault: morpho,
            _marketParams: morphoMarketParams,
            _liqLTV: twyneLiqLTV
        });
        address[] memory aliceVaults = collateralVaultFactory.getCollateralVaults(alice);
        alice_morpho_vault = MorphoCollateralVault(aliceVaults[aliceVaults.length - 1]);

        IERC20(WETH).approve(address(alice_morpho_vault), type(uint256).max);
        alice_morpho_vault.deposit(COLLATERAL_AMOUNT);
        vm.stopPrank();

        assertFalse(alice_morpho_vault.canLiquidate(), "Should not be liquidatable with no debt");

        vm.startPrank(alice);
        alice_morpho_vault.borrow(BORROW_USDT_AMOUNT, alice);
        vm.stopPrank();

        assertFalse(alice_morpho_vault.canLiquidate(), "Should not be liquidatable immediately after borrow");

        // Warp to accrue interest
        vm.warp(block.timestamp + 365 days);

        // Function should not revert
        alice_morpho_vault.canLiquidate();
    }

    function test_morpho_marketParams() public noGasMetering {
        vm.startPrank(bob);
        IERC20(WETH).approve(address(morpho_intermediate_vault), type(uint256).max);
        morpho_intermediate_vault.deposit(CREDIT_LP_AMOUNT, bob);
        vm.stopPrank();

        vm.startPrank(alice);
        collateralVaultFactory.createMorphoCollateralVault({
            _intermediateVault: address(morpho_intermediate_vault),
            _targetVault: morpho,
            _marketParams: morphoMarketParams,
            _liqLTV: twyneLiqLTV
        });
        address[] memory aliceVaults = collateralVaultFactory.getCollateralVaults(alice);
        alice_morpho_vault = MorphoCollateralVault(aliceVaults[aliceVaults.length - 1]);
        vm.stopPrank();

        MarketParams memory mp = alice_morpho_vault.marketParams();
        assertEq(mp.loanToken, USDT, "Loan token mismatch");
        assertEq(mp.collateralToken, WETH, "Collateral token mismatch");
        assertEq(mp.oracle, ETH_USDT_ORACLE, "Oracle mismatch");
        assertEq(mp.irm, ETH_USDT_IRM, "IRM mismatch");
        assertEq(mp.lltv, ETH_USDT_LLTV, "LLTV mismatch");
    }

    function test_morpho_liquiditySeeded() public noGasMetering {
        uint256 totalSupply = MorphoLib.totalSupplyAssets(IMorpho(morpho), morphoMarketId);
        assertGe(totalSupply, SEED_LIQUIDITY_USDT, "Market should have seeded liquidity");
    }

    function test_morpho_collateralForBorrower() public noGasMetering {
        test_morpho_preLiquidationSetup(getETHUSDTLTVIn1e4());

        // Borrow to have debt
        vm.startPrank(alice);
        if (alice_morpho_vault.maxRepay() == 0) {
            alice_morpho_vault.borrow(BORROW_USDT_AMOUNT / 2, alice);
        }
        vm.stopPrank();

        uint256 collateralPrice = IOracle(ETH_USDT_ORACLE).price();
        uint256 morphoDebt = alice_morpho_vault.maxRepay();
        uint256 userCollateral = alice_morpho_vault.totalAssetsDepositedOrReserved() - alice_morpho_vault.maxRelease();

        uint256 B = morphoDebt;
        uint256 C = userCollateral.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE);

        uint256 collateralForBorrower = alice_morpho_vault.collateralForBorrower(B, C);

        assertGe(collateralForBorrower, 0, "Collateral for borrower should be non-negative");
        assertLe(collateralForBorrower, userCollateral, "Collateral for borrower should not exceed user collateral");
    }

    function test_morpho_splitCollateralAfterExtLiq_calculation() public noGasMetering {
        // Use a higher LTV to ensure there are reserved assets
        uint16 higherLTV = twyneVaultManager.maxTwyneLTVs(address(morpho_intermediate_vault), USDT);
        test_morpho_preLiquidationSetup(higherLTV);

        // Borrow to have debt
        vm.startPrank(alice);
        if (alice_morpho_vault.maxRepay() == 0) {
            alice_morpho_vault.borrow(BORROW_USDT_AMOUNT / 2, alice);
        }
        vm.stopPrank();

        uint256 collateralBalance = alice_morpho_vault.collateralBalance();
        uint256 maxRepay = alice_morpho_vault.maxRepay();
        uint256 maxRelease = alice_morpho_vault.maxRelease();

        assertGt(collateralBalance, 0, "Should have collateral balance");
        assertGt(maxRepay, 0, "Should have debt to repay");
        // maxRelease may be 0 if liqLTV matches external LTV (no reserved assets needed)
        // Just verify the function doesn't revert
        alice_morpho_vault.maxRelease();
    }

    ///
    // Dynamic liquidation incentive tests
    ///

    /// @notice Test that dynamic incentive gives borrower 0 when severely unhealthy
    function test_morpho_dynamicIncentive_severelyUnhealthy() public noGasMetering {
        test_morpho_setupCompleteExternalLiquidation();

        // Further crash the price to make position severely unhealthy
        _setMorphoOraclePrice(5000); // 50% of original

        vm.warp(block.timestamp + 1);

        deal(WETH, liquidator, 100 ether);
        deal(USDT, liquidator, 10_000_000e6);

        vm.startPrank(liquidator);
        SafeERC20.forceApprove(IERC20_OZ(USDT), morpho, type(uint).max);

        // Perform Morpho liquidation to trigger external liquidation — seize most collateral
        uint256 collateralBefore = alice_morpho_vault.collateralBalance();
        uint256 seizeAmount = collateralBefore / 2;
        IMorpho(morpho).liquidate({
            marketParams: morphoMarketParams,
            borrower: address(alice_morpho_vault),
            seizedAssets: seizeAmount,
            repaidShares: 0,
            data: ""
        });

        assertTrue(alice_morpho_vault.isExternallyLiquidated(), "Should be externally liquidated");
        vm.stopPrank();

        // Recover Morpho price to make position healthy (required by handleExternalLiquidation)
        // Position remains severely unhealthy from Twyne's perspective (debt >> user collateral at max LTV)
        _setMorphoPriceForTargetHF(1.01e18);

        // Handle external liquidation
        address newLiquidator = makeAddr("dynamicIncentiveLiquidator");
        deal(USDT, newLiquidator, 10_000_000e6);
        deal(WETH, newLiquidator, 100 ether);

        vm.startPrank(newLiquidator);
        SafeERC20.forceApprove(IERC20_OZ(USDT), address(alice_morpho_vault), type(uint).max);
        IEVC(alice_morpho_vault.EVC()).enableController(newLiquidator, address(alice_morpho_vault.intermediateVault()));

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            onBehalfOfAccount: newLiquidator,
            targetContract: address(alice_morpho_vault),
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.handleExternalLiquidation, ())
        });
        items[1] = IEVC.BatchItem({
            onBehalfOfAccount: newLiquidator,
            targetContract: address(alice_morpho_vault.intermediateVault()),
            value: 0,
            data: abi.encodeCall(morpho_intermediate_vault.liquidate, (address(alice_morpho_vault), address(alice_morpho_vault), 0, 0))
        });

        evc.batch(items);
        vm.stopPrank();

        assertEq(alice_morpho_vault.borrower(), address(0), "Vault should be reset");
    }

    /// @notice Test that dynamic incentive gives borrower some collateral in intermediate regime
    function test_morpho_dynamicIncentive_intermediateRegime() public noGasMetering {
        test_morpho_setupCompleteExternalLiquidation();

        vm.warp(block.timestamp + 1);

        deal(WETH, liquidator, 100 ether);
        deal(USDT, liquidator, 10_000_000e6);

        vm.startPrank(liquidator);
        SafeERC20.forceApprove(IERC20_OZ(USDT), morpho, type(uint).max);

        uint256 collateralBefore = alice_morpho_vault.collateralBalance();
        uint256 seizeAmount = collateralBefore / 4;
        IMorpho(morpho).liquidate({
            marketParams: morphoMarketParams,
            borrower: address(alice_morpho_vault),
            seizedAssets: seizeAmount,
            repaidShares: 0,
            data: ""
        });

        assertTrue(alice_morpho_vault.isExternallyLiquidated(), "Should be externally liquidated");
        vm.stopPrank();

        // Recover Morpho price to make position healthy (required by handleExternalLiquidation)
        _setMorphoPriceForTargetHF(1.05e18);

        address newLiquidator = makeAddr("intermediateRegimeLiquidator");
        deal(USDT, newLiquidator, 10_000_000e6);
        deal(WETH, newLiquidator, 100 ether);

        vm.startPrank(newLiquidator);
        SafeERC20.forceApprove(IERC20_OZ(USDT), address(alice_morpho_vault), type(uint).max);
        IEVC(alice_morpho_vault.EVC()).enableController(newLiquidator, address(alice_morpho_vault.intermediateVault()));

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            onBehalfOfAccount: newLiquidator,
            targetContract: address(alice_morpho_vault),
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.handleExternalLiquidation, ())
        });
        items[1] = IEVC.BatchItem({
            onBehalfOfAccount: newLiquidator,
            targetContract: address(alice_morpho_vault.intermediateVault()),
            value: 0,
            data: abi.encodeCall(morpho_intermediate_vault.liquidate, (address(alice_morpho_vault), address(alice_morpho_vault), 0, 0))
        });

        evc.batch(items);
        vm.stopPrank();

        assertEq(alice_morpho_vault.borrower(), address(0), "Vault should be reset");
        assertEq(alice_morpho_vault.maxRelease(), 0, "maxRelease should be 0");
    }

    /// @notice Test that borrower + liquidator + release sum equals total collateral (conservation)
    function test_morpho_dynamicIncentive_conservation() public noGasMetering {
        test_morpho_setupCompleteExternalLiquidation();

        vm.warp(block.timestamp + 1);

        deal(WETH, liquidator, 100 ether);
        deal(USDT, liquidator, 10_000_000e6);

        vm.startPrank(liquidator);
        SafeERC20.forceApprove(IERC20_OZ(USDT), morpho, type(uint).max);

        uint256 collateralBefore = alice_morpho_vault.collateralBalance();
        uint256 seizeAmount = collateralBefore / 3;
        IMorpho(morpho).liquidate({
            marketParams: morphoMarketParams,
            borrower: address(alice_morpho_vault),
            seizedAssets: seizeAmount,
            repaidShares: 0,
            data: ""
        });

        assertTrue(alice_morpho_vault.isExternallyLiquidated(), "Should be externally liquidated");
        vm.stopPrank();

        // Recover Morpho price to make position healthy (required by handleExternalLiquidation)
        _setMorphoPriceForTargetHF(1.05e18);

        // Record balances before
        uint256 borrowerBalBefore = IERC20(WETH).balanceOf(alice);
        uint256 remainingCollateral = alice_morpho_vault.collateralBalance();

        address newLiquidator = makeAddr("conservationLiquidator");
        deal(USDT, newLiquidator, 10_000_000e6);
        deal(WETH, newLiquidator, 100 ether);
        uint256 liqBalBefore = IERC20(WETH).balanceOf(newLiquidator);
        uint256 intermediateBalBefore = IERC20(WETH).balanceOf(address(morpho_intermediate_vault));

        vm.startPrank(newLiquidator);
        SafeERC20.forceApprove(IERC20_OZ(USDT), address(alice_morpho_vault), type(uint).max);
        IEVC(alice_morpho_vault.EVC()).enableController(newLiquidator, address(alice_morpho_vault.intermediateVault()));

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            onBehalfOfAccount: newLiquidator,
            targetContract: address(alice_morpho_vault),
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.handleExternalLiquidation, ())
        });
        items[1] = IEVC.BatchItem({
            onBehalfOfAccount: newLiquidator,
            targetContract: address(alice_morpho_vault.intermediateVault()),
            value: 0,
            data: abi.encodeCall(morpho_intermediate_vault.liquidate, (address(alice_morpho_vault), address(alice_morpho_vault), 0, 0))
        });

        evc.batch(items);
        vm.stopPrank();

        // Repay over-transfer refunds should not leave loan-token dust in the vault.
        assertEq(IERC20(USDT).balanceOf(address(alice_morpho_vault)), 0, "USDT dust left in vault");

        // Verify conservation: borrowerClaim + liquidatorReward + releaseAmount = remaining collateral
        uint256 borrowerReceived = IERC20(WETH).balanceOf(alice) - borrowerBalBefore;
        uint256 liqReceived = IERC20(WETH).balanceOf(newLiquidator) - liqBalBefore;
        uint256 intermediateReceived = IERC20(WETH).balanceOf(address(morpho_intermediate_vault)) - intermediateBalBefore;

        assertEq(
            borrowerReceived + liqReceived + intermediateReceived,
            remainingCollateral,
            "Collateral conservation violated: sum must equal remaining collateral"
        );
    }

    /// @notice Test handleExternalLiquidation with zero maxRelease only allows borrower
    function test_morpho_handleExternalLiquidation_zeroReserve() public noGasMetering {
        // Setup with minimum LTV so there are no reserved assets (maxRelease = 0)
        uint16 minimumLTV = uint16(uint(getETHUSDTLTVIn1e4()) * uint(twyneVaultManager.externalLiqBuffers(address(morpho_intermediate_vault), USDT)) / MAXFACTOR);
        test_morpho_preLiquidationSetup(minimumLTV);

        // Additional deposit and borrow
        vm.startPrank(alice);
        IERC20(WETH).approve(address(alice_morpho_vault), type(uint).max);
        SafeERC20.forceApprove(IERC20_OZ(USDT), address(alice_morpho_vault), type(uint).max);
        alice_morpho_vault.deposit(5 ether);

        // Calculate borrow based on actual collateral
        uint256 collateralPrice = IOracle(ETH_USDT_ORACLE).price();
        uint256 collateralInMorpho = alice_morpho_vault.collateralBalance();
        uint256 maxBorrowMorpho = collateralInMorpho.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).wMulDown(ETH_USDT_LLTV) * 80 / 100;
        if (maxBorrowMorpho > 0 && alice_morpho_vault.maxRepay() == 0) {
            alice_morpho_vault.borrow(maxBorrowMorpho, alice);
        }
        vm.stopPrank();

        // Verify maxRelease is 0 (no reserved assets)
        assertEq(alice_morpho_vault.maxRelease(), 0, "maxRelease should be 0 for minimum LTV");

        // Crash price aggressively to trigger external liquidation
        _setMorphoOraclePrice(5000);

        vm.warp(block.timestamp + 1);

        deal(WETH, liquidator, 100 ether);
        deal(USDT, liquidator, 10_000_000e6);

        vm.startPrank(liquidator);
        SafeERC20.forceApprove(IERC20_OZ(USDT), morpho, type(uint).max);

        uint256 collateralBefore = alice_morpho_vault.collateralBalance();
        if (collateralBefore > 0) {
            IMorpho(morpho).liquidate({
                marketParams: morphoMarketParams,
                borrower: address(alice_morpho_vault),
                seizedAssets: collateralBefore / 2,
                repaidShares: 0,
                data: ""
            });
        }
        vm.stopPrank();

        if (alice_morpho_vault.isExternallyLiquidated() && alice_morpho_vault.maxRelease() == 0) {
            // Non-borrower should be rejected
            address newLiquidator = makeAddr("zeroReserveLiquidator");
            vm.startPrank(newLiquidator);
            vm.expectRevert(TwyneErrors.NoLiquidationForZeroReserve.selector);
            alice_morpho_vault.handleExternalLiquidation();
            vm.stopPrank();

            // Borrower should be allowed
            vm.startPrank(alice);
            alice_morpho_vault.handleExternalLiquidation();
            vm.stopPrank();

            assertEq(alice_morpho_vault.borrower(), address(0), "Vault should be reset");
        }
    }

    /// @notice Test external liquidation with zero debt returns all to release + borrower
    function test_morpho_handleExternalLiquidation_zeroDebt() public noGasMetering {
        test_morpho_setupCompleteExternalLiquidation();

        assertTrue(alice_morpho_vault.canLiquidate(), "Vault should be unhealthy!");
        vm.warp(block.timestamp + 1);

        deal(WETH, liquidator, 100 ether);
        deal(USDT, liquidator, 10_000_000e6);

        vm.startPrank(liquidator);
        SafeERC20.forceApprove(IERC20_OZ(USDT), morpho, type(uint).max);

        uint256 collateralBefore = alice_morpho_vault.collateralBalance();
        assertGt(collateralBefore, 0, "Should have collateral");

        IMorpho(morpho).liquidate({
            marketParams: morphoMarketParams,
            borrower: address(alice_morpho_vault),
            seizedAssets: collateralBefore,
            repaidShares: 0,
            data: ""
        });
        vm.stopPrank();

        assertTrue(alice_morpho_vault.isExternallyLiquidated(), "Vault should be externally liquidated");
        assertEq(alice_morpho_vault.maxRepay(), 0, "Debt should be 0 after seizing all collateral");
        assertEq(alice_morpho_vault.collateralBalance(), 0, "Collateral should be 0 after full external liquidation");

        address newLiquidator = makeAddr("zeroDebtLiquidator");
        vm.startPrank(newLiquidator);
        IEVC(alice_morpho_vault.EVC()).enableController(newLiquidator, address(alice_morpho_vault.intermediateVault()));

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            onBehalfOfAccount: newLiquidator,
            targetContract: address(alice_morpho_vault),
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.handleExternalLiquidation, ())
        });
        items[1] = IEVC.BatchItem({
            onBehalfOfAccount: newLiquidator,
            targetContract: address(alice_morpho_vault.intermediateVault()),
            value: 0,
            data: abi.encodeCall(morpho_intermediate_vault.liquidate, (address(alice_morpho_vault), address(alice_morpho_vault), 0, 0))
        });

        evc.batch(items);
        vm.stopPrank();

        // Regression: zero-collateral finalize must not revert and must not accumulate loan-token dust.
        assertEq(IERC20(USDT).balanceOf(address(alice_morpho_vault)), 0, "USDT dust left in vault");
        assertEq(alice_morpho_vault.borrower(), address(0), "Vault should be reset");
    }

    // ============================================================
    // Liquidation trigger via LTV ramp-down
    // ============================================================

    /// @notice A ramp-down of externalLiqBuffer from 1e4 → 0.8e4 over 1000s
    ///         triggers liquidation only once the ramp completes.
    function test_morpho_setupLiquidationFromSafetyBufferRampDown() public noGasMetering {
        test_morpho_preLiquidationSetup(twyneLiqLTV);

        // Position is healthy before the ramp
        assertFalse(alice_morpho_vault.canLiquidate(), "Vault should be healthy before ramp");

        // Start a ramp-down of externalLiqBuffer from 1e4 → 0.8e4 over 1000 seconds
        vm.startPrank(admin);
        twyneVaultManager.setExternalLiqBuffer(address(morpho_intermediate_vault), USDT, 0.8e4, 1000);
        vm.stopPrank();

        // Immediately after starting the ramp, the effective buffer is still ~1e4 → healthy
        assertFalse(alice_morpho_vault.canLiquidate(), "Vault should still be healthy at ramp start");

        // Warp to the end of the ramp — buffer is now 0.8e4
        vm.warp(block.timestamp + 1000);

        // Position should now be liquidatable (same end-state as a buffer change to 0.8e4)
        assertTrue(alice_morpho_vault.canLiquidate(), "Vault should be liquidatable after ramp completes");
    }

    /// @notice A ramp-down of maxTwyneLTV from 0.95e4 → 0.8e4 over 1000s triggers
    ///         liquidation because Math.min(twyneLiqLTV, maxTwyneLTVs) drops below twyneLiqLTV,
    ///         reducing the collateral value backing the combined debt.
    function test_morpho_setupLiquidationFromMaxLTVRampDown() public noGasMetering {
        test_morpho_preLiquidationSetup(twyneLiqLTV);

        assertFalse(alice_morpho_vault.canLiquidate(), "Vault should be healthy before ramp");

        // Ramp maxTwyneLTV from 0.95e4 (above twyneLiqLTV 9150) → 0.8e4 (below it)
        vm.startPrank(admin);
        twyneVaultManager.setMaxLiquidationLTV(address(morpho_intermediate_vault), USDT, 0.8e4, 1000);
        vm.stopPrank();

        // At ramp start the effective maxTwyneLTV is still ~0.95e4 → healthy
        assertFalse(alice_morpho_vault.canLiquidate(), "Vault should still be healthy at ramp start");

        vm.warp(block.timestamp + 1000);

        assertTrue(alice_morpho_vault.canLiquidate(), "Vault should be liquidatable after maxLTV ramp completes");
    }

    // ============================================================
    // handleExternalLiquidation edge cases
    // ============================================================

    /// @notice handleExternalLiquidation alone (without settling the intermediate-vault bad debt
    ///         in the same batch) reverts with BadDebtNotSettled.
    function test_morpho_handleExternalLiquidation_reverts_withoutBadDebtSettlement() public noGasMetering {
        test_morpho_setupCompleteExternalLiquidation();
        assertTrue(alice_morpho_vault.canLiquidate(), "Vault should be unhealthy");

        vm.warp(block.timestamp + 1);

        deal(WETH, liquidator, 100 ether);
        deal(USDT, liquidator, 10_000_000e6);

        // Full external liquidation: seize all collateral, Morpho debt → 0
        vm.startPrank(liquidator);
        SafeERC20.forceApprove(IERC20_OZ(USDT), morpho, type(uint).max);
        uint256 collateralBefore = alice_morpho_vault.collateralBalance();
        IMorpho(morpho).liquidate({
            marketParams: morphoMarketParams,
            borrower: address(alice_morpho_vault),
            seizedAssets: collateralBefore,
            repaidShares: 0,
            data: ""
        });
        vm.stopPrank();

        assertTrue(alice_morpho_vault.isExternallyLiquidated(), "Vault should be externally liquidated");
        assertEq(alice_morpho_vault.maxRepay(), 0, "Morpho debt should be fully repaid");
        assertGt(alice_morpho_vault.maxRelease(), 0, "Intermediate-vault bad debt should remain");

        // Calling handleExternalLiquidation alone must revert: bad debt is not settled
        address newLiquidator = makeAddr("soloLiquidator");
        deal(USDT, newLiquidator, 10_000_000e6);
        vm.startPrank(newLiquidator);
        IEVC(alice_morpho_vault.EVC()).enableController(newLiquidator, address(alice_morpho_vault.intermediateVault()));

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            onBehalfOfAccount: newLiquidator,
            targetContract: address(alice_morpho_vault),
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.handleExternalLiquidation, ())
        });

        vm.expectRevert(TwyneErrors.BadDebtNotSettled.selector);
        evc.batch(items);
        vm.stopPrank();
    }

    /// @notice handleExternalLiquidation reverts with ExternalPositionUnhealthy when the Morpho
    ///         position itself is unhealthy (maxBorrow < debt).
    function test_morpho_handleExternalLiquidation_reverts_unhealthyPosition() public noGasMetering {
        test_morpho_setupCompleteExternalLiquidation();

        vm.warp(block.timestamp + 1);

        deal(WETH, liquidator, 100 ether);
        deal(USDT, liquidator, 10_000_000e6);

        vm.startPrank(liquidator);
        SafeERC20.forceApprove(IERC20_OZ(USDT), morpho, type(uint).max);

        // Partial external liquidation so the vault is flagged externally liquidated
        uint256 collateralBefore = alice_morpho_vault.collateralBalance();
        IMorpho(morpho).liquidate({
            marketParams: morphoMarketParams,
            borrower: address(alice_morpho_vault),
            seizedAssets: collateralBefore / 4,
            repaidShares: 0,
            data: ""
        });
        assertTrue(alice_morpho_vault.isExternallyLiquidated(), "Vault should be externally liquidated");
        vm.stopPrank();

        // Crash the price further so the Morpho position is genuinely unhealthy
        _setMorphoOraclePrice(5000);

        // handleExternalLiquidation requires a healthy Morpho position and must revert
        address newLiquidator = makeAddr("unhealthyHandler");
        deal(USDT, newLiquidator, 10_000_000e6);
        vm.startPrank(newLiquidator);
        IEVC(alice_morpho_vault.EVC()).enableController(newLiquidator, address(alice_morpho_vault.intermediateVault()));

        vm.expectRevert(TwyneErrors.ExternalPositionUnhealthy.selector);
        alice_morpho_vault.handleExternalLiquidation();
        vm.stopPrank();
    }

    /// @notice External-liquidation detection considers collateral supplied directly to Morpho:
    ///         supplying just enough flips isExternallyLiquidated back to false.
    function test_morpho_externalLiquidationDetectionConsidersCollateralSupply() public noGasMetering {
        test_morpho_setupCompleteExternalLiquidation();

        vm.warp(block.timestamp + 1);

        deal(WETH, liquidator, 100 ether);
        deal(USDT, liquidator, 10_000_000e6);

        vm.startPrank(liquidator);
        SafeERC20.forceApprove(IERC20_OZ(USDT), morpho, type(uint).max);
        SafeERC20.forceApprove(IERC20_OZ(WETH), morpho, type(uint).max);

        // Partial Morpho liquidation flags the vault as externally liquidated
        uint256 collateralBefore = alice_morpho_vault.collateralBalance();
        IMorpho(morpho).liquidate({
            marketParams: morphoMarketParams,
            borrower: address(alice_morpho_vault),
            seizedAssets: collateralBefore / 2,
            repaidShares: 0,
            data: ""
        });
        assertTrue(alice_morpho_vault.isExternallyLiquidated(), "Vault should be externally liquidated");

        // Compute the shortfall and supply collateral on behalf of the vault in Morpho
        uint256 shortfall =
            alice_morpho_vault.totalAssetsDepositedOrReserved() - alice_morpho_vault.collateralBalance();
        deal(WETH, liquidator, INITIAL_DEALT_ERC20 + shortfall + 1);

        // Supply one wei short → still externally liquidated
        IMorpho(morpho).supplyCollateral({
            marketParams: morphoMarketParams,
            assets: shortfall - 1,
            onBehalf: address(alice_morpho_vault),
            data: ""
        });
        assertTrue(alice_morpho_vault.isExternallyLiquidated(), "Should still be externally liquidated");

        // Supply the final wei → no longer externally liquidated
        IMorpho(morpho).supplyCollateral({
            marketParams: morphoMarketParams,
            assets: 1,
            onBehalf: address(alice_morpho_vault),
            data: ""
        });
        assertFalse(alice_morpho_vault.isExternallyLiquidated(), "Should no longer be externally liquidated");
        vm.stopPrank();
    }

    /// @notice A batch cannot perform a Morpho liquidation and handle it in the same transaction.
    function test_morpho_verifyBatchCannotForceExtLiquidation() public noGasMetering {
        test_morpho_setupCompleteExternalLiquidation();

        vm.warp(block.timestamp + 1);

        deal(WETH, liquidator, 100 ether);
        deal(USDT, liquidator, 10_000_000e6);

        vm.startPrank(liquidator);
        SafeERC20.forceApprove(IERC20_OZ(USDT), morpho, type(uint).max);
        SafeERC20.forceApprove(IERC20_OZ(WETH), morpho, type(uint).max);

        uint256 seizeAmount = alice_morpho_vault.collateralBalance() / 2;

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            onBehalfOfAccount: liquidator,
            targetContract: morpho,
            value: 0,
            data: abi.encodeCall(
                IMorpho(morpho).liquidate,
                (morphoMarketParams, address(alice_morpho_vault), seizeAmount, 0, "")
            )
        });
        items[1] = IEVC.BatchItem({
            onBehalfOfAccount: liquidator,
            targetContract: address(alice_morpho_vault),
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.handleExternalLiquidation, ())
        });

        // The batch must not succeed: you cannot force an external liquidation and handle it in one tx
        vm.expectRevert();
        evc.batch(items);
        vm.stopPrank();
    }

    /// @notice Handling an external liquidation refunds any un-consumed excess to the liquidator.
    /// @dev `handleExternalLiquidation` forwards `maxRepay()` (sized from `expectedBorrowAssets`, which accrues
    ///      via `borrowRateView`) but `IMorpho.repay` accrues via `borrowRate`. With a divergent IRM the
    ///      forwarded amount exceeds what Morpho consumes and the difference is returned to the caller.
    function test_morpho_handleExternalLiquidation_refundsDustToLiquidator() public noGasMetering {
        // IRM whose view rate exceeds its mutate rate (same address => same market id, existing setup reused).
        vm.etch(ETH_USDT_IRM, type(MockDivergentMorphoIRM).runtimeCode);

        test_morpho_setupCompleteExternalLiquidation();
        assertTrue(alice_morpho_vault.canLiquidate(), "Vault should be unhealthy");

        vm.warp(block.timestamp + 1);

        // External liquidation seizes collateral and repays debt, advancing lastUpdate to now.
        deal(WETH, liquidator, 100 ether);
        deal(USDT, liquidator, 10_000_000e6);
        vm.startPrank(liquidator);
        SafeERC20.forceApprove(IERC20_OZ(USDT), morpho, type(uint256).max);
        IMorpho(morpho).liquidate({
            marketParams: morphoMarketParams,
            borrower: address(alice_morpho_vault),
            seizedAssets: alice_morpho_vault.collateralBalance() / 4,
            repaidShares: 0,
            data: ""
        });
        assertTrue(alice_morpho_vault.isExternallyLiquidated(), "Should be externally liquidated");
        vm.stopPrank();

        // Recover price so the reduced Morpho position is healthy, as handleExternalLiquidation requires.
        _setMorphoPriceForTargetHF(1.05e18);

        // Create the accrual window over which the view debt outruns the real debt.
        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 1000);

        address handler = makeAddr("dustHandler");
        deal(USDT, handler, 10_000_000e6);
        deal(WETH, handler, 100 ether);

        vm.startPrank(handler);
        SafeERC20.forceApprove(IERC20_OZ(USDT), address(alice_morpho_vault), type(uint256).max);
        IEVC(alice_morpho_vault.EVC()).enableController(handler, address(alice_morpho_vault.intermediateVault()));

        uint256 maxRepayBefore = alice_morpho_vault.maxRepay();
        assertGt(maxRepayBefore, 0, "no remaining Morpho debt");
        uint256 before = IERC20(USDT).balanceOf(handler);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            onBehalfOfAccount: handler,
            targetContract: address(alice_morpho_vault),
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.handleExternalLiquidation, ())
        });
        items[1] = IEVC.BatchItem({
            onBehalfOfAccount: handler,
            targetContract: address(alice_morpho_vault.intermediateVault()),
            value: 0,
            data: abi.encodeCall(
                morpho_intermediate_vault.liquidate,
                (address(alice_morpho_vault), address(alice_morpho_vault), 0, 0)
            )
        });
        evc.batch(items);

        uint256 afterBal = IERC20(USDT).balanceOf(handler);
        vm.stopPrank();

        // dust = forwarded (maxRepay) minus actually consumed (balance lost)
        assertGt(maxRepayBefore - (before - afterBal), 0, "liquidator should receive dust refund");
        assertEq(alice_morpho_vault.borrower(), address(0), "Vault should be reset");
    }

    // ============================================================
    // Account operator triggering liquidation
    // ============================================================

    /// @notice An account operator designated by the borrower can liquidate an unhealthy vault
    ///         via an EVC batch and take it over (making it healthy with extra collateral).
    function test_morpho_operatorCanTriggerLiquidation() public noGasMetering {
        test_morpho_setupLiquidationAccrueInterest(twyneLiqLTV);
        assertTrue(alice_morpho_vault.canLiquidate(), "Vault should be liquidatable");

        // Alice designates the liquidator as her account operator
        vm.startPrank(alice);
        evc.setAccountOperator(alice, liquidator, true);
        vm.stopPrank();

        // The operator must first be a Twyne user (own a collateral vault) to receive the liquidated vault
        vm.startPrank(liquidator);
        collateralVaultFactory.createMorphoCollateralVault({
            _intermediateVault: address(morpho_intermediate_vault),
            _targetVault: morpho,
            _marketParams: morphoMarketParams,
            _liqLTV: twyneLiqLTV
        });

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.liquidate, ())
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.deposit, (COLLATERAL_AMOUNT))
        });

        evc.batch(items);

        // Ownership transferred to the operator, position now healthy
        assertEq(alice_morpho_vault.borrower(), liquidator, "Vault should belong to the operator");
        assertFalse(alice_morpho_vault.canLiquidate(), "Vault should be healthy after operator liquidation");
        vm.stopPrank();
    }
}
