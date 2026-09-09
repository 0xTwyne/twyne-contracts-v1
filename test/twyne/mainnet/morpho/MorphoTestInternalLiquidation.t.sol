// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {MorphoLiquidationTest} from "./MorphoLiquidationTest.t.sol";
import {LiquidationMath} from "../euler/LiquidationMath.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {MorphoCollateralVault} from "src/twyne/MorphoCollateralVault.sol";
import {IMorpho, MarketParams, Id} from "morpho/interfaces/IMorpho.sol";
import {IOracle} from "morpho/interfaces/IOracle.sol";
import {MorphoLib} from "morpho/libraries/periphery/MorphoLib.sol";
import {MathLib} from "morpho/libraries/MathLib.sol";
import {ORACLE_PRICE_SCALE} from "morpho/libraries/ConstantsLib.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {SafeERC20, IERC20 as IERC20_OZ} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {MockMorphoOracle} from "test/mocks/MockMorphoOracle.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import "euler-vault-kit/EVault/shared/types/Types.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Snapshot of state before a Twyne internal liquidation
struct LiquidationSnapshot {
    uint256 borrowerWETH;
    uint256 liquidatorWETH;
    uint256 vaultWETH;
    uint256 vaultUSDT;
    uint256 vaultDebt;
    address borrower;
    uint256 maxRepay;
    uint256 totalAssets;
    uint256 maxRelease;
    uint256 expectedCollateralForBorrower;
}

/// @title MorphoTestInternalLiquidation
/// @notice Comprehensive internal (Twyne) liquidation tests for the Morpho ETH-USDT market.
/// @dev Follows the same pattern as AaveTestInternalLiquidation and EulerTestInternalLiquidation.
///
/// Test suite overview:
///  - Case00–01: verify healthy vaults revert (`β_safe * λ̃_e` guard)
///  - Case10–13: core interpolation band with progressive price drops
///  - Case14–15: same scenarios but different liquidation LTV to prove invariance
///  - Case20–22: fully liquidated + insolvency branches
///  - LowValues Case10–13: dust-scale positions (~0.001 WETH collateral, ~2 USDT debt)
///  - `test_liquidationMathUSDT_case*`: numeric trace helpers (logs B/C, raw USD, price conversion)
///  - Corner cases: LTV > 100%, insolvency
///  - Revert tests: self-liquidation, healthy-not-liquidatable
contract MorphoTestInternalLiquidation is MorphoLiquidationTest {
    using MathLib for uint;

    function setUp() public override {
        super.setUp();
    }

    // ─── Position creation ─────────────────────────────────────────────

    /// @notice Creates an initial borrowing position on Morpho via Twyne
    /// @param C Collateral amount in WETH (18 decimals)
    /// @param B Borrow amount in USDT (6 decimals)
    /// @param twyneLTV Twyne liquidation LTV in 1e4 precision
    function createInitialPosition(uint256 C, uint256 /* CLP */, uint256 B, uint256 twyneLTV) public {
        // Pre-setup checks
        uint256 extLiqLTV = ETH_USDT_LLTV * 1e4 / 1e18; // 9150 in 1e4
        uint16 extLiqBuffer = twyneVaultManager.externalLiqBuffers(address(morpho_intermediate_vault), USDT);
        require(extLiqLTV * uint256(extLiqBuffer) <= uint256(twyneLTV) * MAXFACTOR, "precond: LTV too low");
        require(twyneLTV <= twyneVaultManager.maxTwyneLTVs(address(morpho_intermediate_vault), USDT), "precond: twyneLTV too high");

        // Bob deposits WETH into intermediate vault (credit LP)
        vm.startPrank(bob);
        IERC20(WETH).approve(address(morpho_intermediate_vault), type(uint256).max);
        morpho_intermediate_vault.deposit(CREDIT_LP_AMOUNT, bob);
        vm.stopPrank();

        // Alice deploys a Morpho collateral vault
        vm.startPrank(alice);
        collateralVaultFactory.createMorphoCollateralVault({
            _intermediateVault: address(morpho_intermediate_vault),
            _targetVault: morpho,
            _marketParams: morphoMarketParams,
            _liqLTV: uint16(twyneLTV)
        });
        address[] memory aliceVaults = collateralVaultFactory.getCollateralVaults(alice);
        alice_morpho_vault = MorphoCollateralVault(aliceVaults[aliceVaults.length - 1]);
        vm.label(address(alice_morpho_vault), "alice_morpho_vault_eth_usdt");

        IERC20(WETH).approve(address(alice_morpho_vault), type(uint256).max);

        // Deposit and borrow in a single EVC batch
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.deposit, (C))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.borrow, (B, alice))
        });
        evc.batch(items);
        vm.stopPrank();
    }

    // ─── Price manipulation ────────────────────────────────────────────

    /// @notice Drop the Morpho oracle price by `pctDrop` percent
    /// @param pctDrop percentage drop (e.g. 10 = 10% drop)
    function executePriceDrop(uint256 pctDrop) public {
        _setMorphoOraclePrice(MAXFACTOR - pctDrop * MAXFACTOR / 100);
    }

    /// @notice Set price so that the current LTV becomes `targetLtvBps` (1e4 precision)
    function _setMorphoPriceForTargetLTV(uint256 targetLtvBps) internal {
        require(targetLtvBps > 0, "targetLTV=0");
        (uint256 B, uint256 C) = _getBC_test();
        require(B > 0 && C > 0, "no BC");

        uint256 currentLtvBps = (B * MAXFACTOR) / C;
        // Lowering price => LTV goes up. newPrice = currentPrice * currentLTV / targetLTV
        uint256 newPrice = (INITIAL_MORPHO_PRICE * currentLtvBps) / targetLtvBps;
        require(newPrice > 0, "price=0");

        MockMorphoOracle mockMorphoOracle = new MockMorphoOracle();
        vm.etch(ETH_USDT_ORACLE, address(mockMorphoOracle).code);
        MockMorphoOracle(ETH_USDT_ORACLE).setPrice(newPrice);
    }

    // ─── Helper views ──────────────────────────────────────────────────

    /// @notice Returns debt (B) and user collateral value (C) in loan-token (USDT) terms
    /// @dev Matches the contract's internal `_getBC()` logic
    function _getBC_test() internal view returns (uint256 B, uint256 C) {
        uint256 collateralPrice = IOracle(ETH_USDT_ORACLE).price();
        uint256 userCollateral = alice_morpho_vault.totalAssetsDepositedOrReserved() - alice_morpho_vault.maxRelease();
        B = alice_morpho_vault.maxRepay();
        C = userCollateral.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE);
    }

    /// @notice Returns β_safe * λ̃_e in 1e4 precision
    function _liqLTVExternalBps() internal view returns (uint256) {
        uint256 buffer = uint256(twyneVaultManager.externalLiqBuffers(address(morpho_intermediate_vault), USDT));
        uint256 extLiqLtv = ETH_USDT_LLTV * 1e4 / 1e18; // 9150
        return (buffer * extLiqLtv) / MAXFACTOR;
    }

    /// @notice Returns an LTV in the interpolation band at position numerator/denominator
    function _interpolationTargetLTVBps(uint256 numerator, uint256 denominator) internal view returns (uint256) {
        uint256 liqLTV_e_bps = _liqLTVExternalBps();
        uint256 maxLTV_t = uint256(twyneVaultManager.maxTwyneLTVs(address(morpho_intermediate_vault), USDT));
        return liqLTV_e_bps + (maxLTV_t - liqLTV_e_bps) * numerator / denominator;
    }

    /// @dev Ensure liquidator has enough WETH for `collateralForBorrower` transfer
    function _fundLiquidatorWithCollateral(uint256 amount) internal {
        deal(WETH, liquidator, amount + 1 ether);
        vm.startPrank(liquidator);
        IERC20(WETH).approve(address(alice_morpho_vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Fund & approve liquidator for USDT (debt repay) and WETH (collateral)
    function setup_approve_customSetup() internal {
        uint256 debt = alice_morpho_vault.maxRepay();
        deal(USDT, liquidator, debt + 1_000_000e6);
        deal(WETH, liquidator, 100 ether);

        vm.startPrank(liquidator);
        SafeERC20.forceApprove(IERC20_OZ(USDT), address(alice_morpho_vault), type(uint256).max);
        IERC20(WETH).approve(address(alice_morpho_vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Execute Twyne internal liquidation + repay in a single EVC batch
    function executeLiquidationWithRepay() internal {
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        vm.startPrank(liquidator);
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
            data: abi.encodeCall(alice_morpho_vault.repay, (alice_morpho_vault.maxRepay()))
        });
        evc.batch(items);
        vm.stopPrank();
    }

    /// @notice Assert that the current LTV is in the interpolation band
    function _assertInterpolating() internal view {
        (uint256 B, uint256 C) = _getBC_test();

        uint256 buffer = uint256(twyneVaultManager.externalLiqBuffers(address(morpho_intermediate_vault), USDT));
        uint256 extLiqLtv = ETH_USDT_LLTV * 1e4 / 1e18;
        uint256 liqLTV_e = buffer * extLiqLtv; // 1e8 precision
        uint256 maxLTV_t = uint256(twyneVaultManager.maxTwyneLTVs(address(morpho_intermediate_vault), USDT));

        bool isFullyLiquidated = MAXFACTOR * B >= maxLTV_t * C;
        bool isSafeCase = MAXFACTOR * MAXFACTOR * B <= liqLTV_e * C;

        console2.log("=== INTERPOLATION CHECK ===");
        console2.log("B", B);
        console2.log("C", C);
        console2.log("currentLTV_bps", C > 0 ? (B * MAXFACTOR) / C : 0);
        console2.log("liqLTV_e (1e8)", liqLTV_e);
        console2.log("maxLTV_t (1e4)", maxLTV_t);
        console2.log("isFullyLiquidated", isFullyLiquidated ? 1 : 0);
        console2.log("isSafeCase", isSafeCase ? 1 : 0);

        if (isFullyLiquidated || isSafeCase) {
            revert("not in interpolation band");
        }
    }

    /// @notice Take a snapshot of vault state before liquidation
    function _snapshotBeforeLiquidation() internal view returns (LiquidationSnapshot memory snapshot) {
        snapshot.borrowerWETH = IERC20(WETH).balanceOf(alice);
        snapshot.liquidatorWETH = IERC20(WETH).balanceOf(liquidator);
        snapshot.vaultDebt = alice_morpho_vault.maxRepay();
        snapshot.borrower = alice_morpho_vault.borrower();
        snapshot.maxRepay = alice_morpho_vault.maxRepay();
        snapshot.totalAssets = alice_morpho_vault.totalAssetsDepositedOrReserved();
        snapshot.maxRelease = alice_morpho_vault.maxRelease();

        (uint256 B, uint256 C) = _getBC_test();
        snapshot.expectedCollateralForBorrower = alice_morpho_vault.collateralForBorrower(B, C);

        console2.log("=== SNAPSHOT DEBUG ===");
        console2.log("B (debt USDT)", B);
        console2.log("C (collateral in USDT)", C);
        console2.log("twyneLiqLTV", alice_morpho_vault.twyneLiqLTV());
        console2.log("expectedCollateralForBorrower (WETH)", snapshot.expectedCollateralForBorrower);
        console2.log("userCollateral (WETH)", snapshot.totalAssets - snapshot.maxRelease);
    }

    /// @notice Assert invariants after internal liquidation + repay
    function _assertAfterLiquidationAndRepay(LiquidationSnapshot memory before) internal view {
        uint256 borrowerWETHAfter = IERC20(WETH).balanceOf(alice);
        uint256 liquidatorWETHAfter = IERC20(WETH).balanceOf(liquidator);

        uint256 actualCollateralTransferred = borrowerWETHAfter - before.borrowerWETH;

        // Liquidator decrease should equal borrower increase
        assertApproxEqAbs(
            before.liquidatorWETH - liquidatorWETHAfter,
            actualCollateralTransferred,
            10,
            "liquidator decrease should equal borrower increase"
        );

        // Actual transfer should match collateralForBorrower calculation
        assertApproxEqAbs(
            actualCollateralTransferred,
            before.expectedCollateralForBorrower,
            10,
            "actual transfer should match snapshot collateralForBorrower calculation"
        );

        // Ownership transferred to liquidator
        assertEq(alice_morpho_vault.borrower(), liquidator, "vault borrower should be liquidator");

        // Debt should be 0 after full repay
        assertEq(alice_morpho_vault.maxRepay(), 0, "debt should be 0 after full repay");

        // Vault should no longer be liquidatable
        assertFalse(alice_morpho_vault.canLiquidate(), "vault should not be liquidatable after repay");
    }

    // ─── Numeric trace helpers ─────────────────────────────────────────

    function _traceLiquidationMath(
        string memory label,
        uint256 priceDropPct,
        uint256 collateral,
        uint256 clp,
        uint256 borrow,
        uint256 twyneLTV_
    ) internal {
        console2.log("=== LIQUIDATION MATH TRACE ===");
        console2.log("Label", label);
        createInitialPosition(collateral, clp, borrow, twyneLTV_);
        executePriceDrop(priceDropPct);
        _traceLiquidationMathCurrentState(label);
    }

    function _traceLiquidationMathCurrentState(string memory label) internal view {
        console2.log("=== LIQUIDATION MATH TRACE ===");
        console2.log("Label", label);

        (uint256 B, uint256 C) = _getBC_test();

        uint256 buffer = uint256(twyneVaultManager.externalLiqBuffers(address(morpho_intermediate_vault), USDT));
        uint256 extLiqLtv = ETH_USDT_LLTV * 1e4 / 1e18;
        uint256 maxLTV_t = uint256(twyneVaultManager.maxTwyneLTVs(address(morpho_intermediate_vault), USDT));

        uint256 rawBase = LiquidationMath.borrowerCollateralBase(B, C, buffer, extLiqLtv, maxLTV_t);

        console2.log("B (debt USDT)", B);
        console2.log("C (collateral USDT)", C);
        console2.log("LiquidationMath raw base", rawBase);

        if (rawBase == 0) {
            console2.log("convertBaseToCollateral skipped (rawBase == 0)");
            return;
        }

        (uint256 collateralAmount, uint256 availableUserCollateral, uint256 price) =
            _convertBaseToCollateralDebug(rawBase);

        console2.log("collateralAmount (WETH)", collateralAmount);
        console2.log("availableUserCollateral (WETH)", availableUserCollateral);
        console2.log("morphoOraclePrice", price);
    }

    /// @notice Mirrors MorphoCollateralVault._convertBaseToCollateral for debugging
    function _convertBaseToCollateralDebug(uint256 collateralValue)
        internal
        view
        returns (uint256 collateralAmount, uint256 availableUserCollateral, uint256 price)
    {
        price = IOracle(ETH_USDT_ORACLE).price();
        collateralAmount = collateralValue.mulDivDown(ORACLE_PRICE_SCALE, price);
        availableUserCollateral = alice_morpho_vault.totalAssetsDepositedOrReserved() - alice_morpho_vault.maxRelease();
        collateralAmount = Math.min(availableUserCollateral, collateralAmount);
    }

    /// @notice Calculate max borrow considering both Morpho LLTV and Twyne LTV
    function _maxBorrowForCollateral(uint256 collateralAmount, uint256 twyneLTVBps) internal view returns (uint256) {
        uint256 collateralPrice = IOracle(ETH_USDT_ORACLE).price();
        uint256 maxBorrowMorpho = collateralAmount.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).wMulDown(ETH_USDT_LLTV);
        uint256 maxBorrow = collateralAmount.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE) * twyneLTVBps / MAXFACTOR;
        return (Math.min(maxBorrowMorpho, maxBorrow) * 95) / 100;
    }

    /////////////////////////////////////////////////////////////////
    //////////////// Case 0: λ_t ≤ β_safe * λ̃_e /////////////////////
    /////////////////////////////////////////////////////////////////

    /// @notice Healthy position — small debt, small drop → cannot liquidate
    function test_m_expectRevert_internalLiquidation_case00() external noGasMetering {
        createInitialPosition(5e18, 0, BORROW_USDT_AMOUNT / 2, twyneLiqLTV);

        // Small price drop, still healthy
        executePriceDrop(2);

        setup_approve_customSetup();

        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.HealthyNotLiquidatable.selector);
        alice_morpho_vault.liquidate();
        vm.stopPrank();
    }

    /// @notice LTV at upper boundary before interpolation band → still healthy
    function test_m_expectRevert_internalLiquidation_case01() external noGasMetering {
        uint256 borrowAmount = _maxBorrowForCollateral(5e18, twyneLiqLTV);
        createInitialPosition(5e18, 0, borrowAmount, twyneLiqLTV);

        vm.warp(block.timestamp + 1);

        // Keep LTV slightly below external liquidation threshold
        uint256 liqLTV_e_bps = _liqLTVExternalBps();
        uint256 targetLtvBps = liqLTV_e_bps > 50 ? liqLTV_e_bps - 50 : liqLTV_e_bps / 2;
        _setMorphoPriceForTargetLTV(targetLtvBps);

        setup_approve_customSetup();

        assertFalse(alice_morpho_vault.canLiquidate(), "vault should not be liquidatable at boundary");

        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.HealthyNotLiquidatable.selector);
        alice_morpho_vault.liquidate();
        vm.stopPrank();
    }

    /////////////////////////////////////////////////////////////////
    //////// Case 1: β_safe * λ̃_e < λ_t < λ̃^max_t /////////////////
    //////// (Interpolation Range) //////////////////////////////////
    /////////////////////////////////////////////////////////////////

    function test_m_internalLiquidation_case10() external noGasMetering {
        createInitialPosition(5e18, 0, BORROW_USDT_AMOUNT, twyneLiqLTV);
        _setMorphoPriceForTargetLTV(_interpolationTargetLTVBps(1, 5));

        _assertInterpolating();

        setup_approve_customSetup();
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_m_internalLiquidation_case11() external noGasMetering {
        createInitialPosition(5e18, 0, BORROW_USDT_AMOUNT, twyneLiqLTV);
        _setMorphoPriceForTargetLTV(_interpolationTargetLTVBps(2, 5));

        _assertInterpolating();

        setup_approve_customSetup();
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_m_internalLiquidation_case12() external noGasMetering {
        createInitialPosition(5e18, 0, BORROW_USDT_AMOUNT, twyneLiqLTV);
        _setMorphoPriceForTargetLTV(_interpolationTargetLTVBps(3, 5));

        _assertInterpolating();

        setup_approve_customSetup();
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_m_internalLiquidation_case13() external noGasMetering {
        createInitialPosition(5e18, 0, BORROW_USDT_AMOUNT, twyneLiqLTV);
        _setMorphoPriceForTargetLTV(_interpolationTargetLTVBps(4, 5));

        _assertInterpolating();

        setup_approve_customSetup();
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    /// @notice Case 14 & 15 prove that interpolation results are unaffected by choice of twyneLiqLTV
    function test_m_internalLiquidation_case14() external noGasMetering {
        createInitialPosition(5e18, 0, BORROW_USDT_AMOUNT, 9150); // same as Morpho LLTV
        _setMorphoPriceForTargetLTV(_interpolationTargetLTVBps(3, 5));

        _assertInterpolating();

        setup_approve_customSetup();
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_m_internalLiquidation_case15() external noGasMetering {
        createInitialPosition(5e18, 0, BORROW_USDT_AMOUNT, 9150);
        _setMorphoPriceForTargetLTV(_interpolationTargetLTVBps(4, 5));

        _assertInterpolating();

        setup_approve_customSetup();
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    /////////////////////////////////////////////////////////////////
    //////// Case 2: λ_t >= λ̃^max_t (Fully Liquidated Range) ///////
    /////////////////////////////////////////////////////////////////

    function test_m_internalLiquidation_case20() external noGasMetering {
        createInitialPosition(5e18, 0, BORROW_USDT_AMOUNT, twyneLiqLTV);

        executePriceDrop(40);

        setup_approve_customSetup();
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_m_internalLiquidation_case21() external noGasMetering {
        createInitialPosition(5e18, 0, BORROW_USDT_AMOUNT, twyneLiqLTV);

        executePriceDrop(42);

        setup_approve_customSetup();
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_m_internalLiquidation_case22() external noGasMetering {
        createInitialPosition(5e18, 0, BORROW_USDT_AMOUNT, twyneLiqLTV);

        executePriceDrop(45);

        setup_approve_customSetup();
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    /////////////////////////////////////////////////////////////////
    ///////////////// Corner cases //////////////////////////////////
    /////////////////////////////////////////////////////////////////

    /// @notice If current LTV > 100% (max branch), liquidation still proceeds (liquidator may lose money)
    function test_m_internalLiquidation_case_ltv_higher_than_max() external noGasMetering {
        createInitialPosition(5e18, 0, BORROW_USDT_AMOUNT, twyneLiqLTV);

        // Large price drop to push LTV above maxLTV_t
        executePriceDrop(70);

        // Ensure we are in the "fully liquidated" branch
        (uint256 B, uint256 C) = _getBC_test();
        uint256 maxLTV_t = uint256(twyneVaultManager.maxTwyneLTVs(address(morpho_intermediate_vault), USDT));
        assertTrue(MAXFACTOR * B >= maxLTV_t * C, "not in fully-liquidated branch");

        setup_approve_customSetup();
        _fundLiquidatorWithCollateral(alice_morpho_vault.collateralForBorrower(B, C));

        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    /// @notice Insolvency / extreme price crash branch
    function test_m_internalLiquidation_insolvency() external noGasMetering {
        createInitialPosition(5e18, 0, BORROW_USDT_AMOUNT, twyneLiqLTV);

        executePriceDrop(90);

        (uint256 B, uint256 C) = _getBC_test();
        setup_approve_customSetup();
        _fundLiquidatorWithCollateral(alice_morpho_vault.collateralForBorrower(B, C));

        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    /////////////////////////////////////////////////////////////////
    ///////////////// Numeric trace tests ///////////////////////////
    /////////////////////////////////////////////////////////////////

    function test_liquidationMathUSDT_case10() external noGasMetering {
        _traceLiquidationMath("Case10 (32% drop)", 32, 5e18, 0, BORROW_USDT_AMOUNT, 9150);
    }

    function test_liquidationMathUSDT_case11() external noGasMetering {
        _traceLiquidationMath("Case11 (34% drop)", 34, 5e18, 0, BORROW_USDT_AMOUNT, 9150);
    }

    function test_liquidationMathUSDT_case12() external noGasMetering {
        _traceLiquidationMath("Case12 (35% drop)", 35, 5e18, 0, BORROW_USDT_AMOUNT, 9150);
    }

    function test_liquidationMathUSDT_case20() external noGasMetering {
        _traceLiquidationMath("Case20 (40% drop, twyneLTV 91.5%)", 40, 5e18, 0, BORROW_USDT_AMOUNT, 9150);
    }

    function test_liquidationMathUSDT_case21() external noGasMetering {
        _traceLiquidationMath("Case21 (42% drop, twyneLTV 91.5%)", 42, 5e18, 0, BORROW_USDT_AMOUNT, 9150);
    }

    function test_liquidationMathUSDT_case22() external noGasMetering {
        _traceLiquidationMath("Case22 (45% drop, twyneLTV 91.5%)", 45, 5e18, 0, BORROW_USDT_AMOUNT, 9150);
    }

    /////////////////////////////////////////////////////////////////
    ///////////////// Low-value precision cases /////////////////////
    /////////////////////////////////////////////////////////////////

    /// @notice Dust-scale position: ~0.001 WETH collateral, ~2.2 USDT debt
    function test_m_internalLiquidation_lowValues_case10() external noGasMetering {
        uint256 smallCollateral = 1e15;
        uint256 lowBorrow = smallCollateral.mulDivDown(INITIAL_MORPHO_PRICE, ORACLE_PRICE_SCALE) * 80 / 100;
        createInitialPosition(smallCollateral, 0, lowBorrow, twyneLiqLTV);
        _setMorphoPriceForTargetLTV(_interpolationTargetLTVBps(1, 5));
        _assertInterpolating();
        assertTrue(alice_morpho_vault.canLiquidate(), "vault should be liquidatable");

        setup_approve_customSetup();
        (uint256 B, uint256 C) = _getBC_test();
        _fundLiquidatorWithCollateral(alice_morpho_vault.collateralForBorrower(B, C));

        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_m_internalLiquidation_lowValues_case11() external noGasMetering {
        uint256 smallCollateral = 1e15;
        uint256 lowBorrow = smallCollateral.mulDivDown(INITIAL_MORPHO_PRICE, ORACLE_PRICE_SCALE) * 80 / 100;
        createInitialPosition(smallCollateral, 0, lowBorrow, twyneLiqLTV);
        _setMorphoPriceForTargetLTV(_interpolationTargetLTVBps(2, 5));
        _assertInterpolating();
        assertTrue(alice_morpho_vault.canLiquidate(), "vault should be liquidatable");

        setup_approve_customSetup();
        (uint256 B, uint256 C) = _getBC_test();
        _fundLiquidatorWithCollateral(alice_morpho_vault.collateralForBorrower(B, C));

        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_m_internalLiquidation_lowValues_case12() external noGasMetering {
        uint256 smallCollateral = 1e15;
        uint256 lowBorrow = smallCollateral.mulDivDown(INITIAL_MORPHO_PRICE, ORACLE_PRICE_SCALE) * 80 / 100;
        createInitialPosition(smallCollateral, 0, lowBorrow, twyneLiqLTV);
        _setMorphoPriceForTargetLTV(_interpolationTargetLTVBps(3, 5));
        _assertInterpolating();
        assertTrue(alice_morpho_vault.canLiquidate(), "vault should be liquidatable");

        setup_approve_customSetup();
        (uint256 B, uint256 C) = _getBC_test();
        _fundLiquidatorWithCollateral(alice_morpho_vault.collateralForBorrower(B, C));

        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_m_internalLiquidation_lowValues_case13() external noGasMetering {
        uint256 smallCollateral = 1e15;
        uint256 lowBorrow = smallCollateral.mulDivDown(INITIAL_MORPHO_PRICE, ORACLE_PRICE_SCALE) * 80 / 100;
        createInitialPosition(smallCollateral, 0, lowBorrow, twyneLiqLTV);
        _setMorphoPriceForTargetLTV(_interpolationTargetLTVBps(4, 5));

        setup_approve_customSetup();
        (uint256 B, uint256 C) = _getBC_test();
        _fundLiquidatorWithCollateral(alice_morpho_vault.collateralForBorrower(B, C));

        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    /////////////////////////////////////////////////////////////////
    ///////////////// Python comparison tests ///////////////////////
    /////////////////////////////////////////////////////////////////

    /// @notice Morpho-adapted version of Python V2 scenario #1 (96% LTV vs 95% threshold)
    function test_m_replicatePythonV2Liquidation_test1() external noGasMetering {
        vm.startPrank(admin);
        twyneVaultManager.setExternalLiqBuffer(address(morpho_intermediate_vault), USDT, 0.99e4, 0);
        twyneVaultManager.setMaxLiquidationLTV(address(morpho_intermediate_vault), USDT, 0.97e4, 0);
        vm.stopPrank();

        uint16 extLiqBuffer = twyneVaultManager.externalLiqBuffers(address(morpho_intermediate_vault), USDT);
        uint16 maxLTV = twyneVaultManager.maxTwyneLTVs(address(morpho_intermediate_vault), USDT);
        assertEq(extLiqBuffer, 9900, "Safety buffer should be 99%");
        assertEq(maxLTV, 9700, "Max LTV should be 97%");

        // Target: ~10,000 USDT collateral value, 9,600 USDT debt → 96% LTV
        uint256 collateralPrice = IOracle(ETH_USDT_ORACLE).price();
        uint256 targetDebtUSDT = 9_600 * 1e6;
        uint256 priceDropPct = 10;

        // Pre-drop collateral: need enough so after 10% drop we have ~10,000 USDT value
        // collateral_WETH = targetCollateralValue_USDT / ((100-drop)/100) * ORACLE_PRICE_SCALE / price
        // where targetCollateralValue_USDT is in 6 decimals
        uint256 preDropValueUSDT = (10_000 * 1e6 * 100) / (100 - priceDropPct);
        uint256 collateralWETH = preDropValueUSDT.mulDivDown(ORACLE_PRICE_SCALE, collateralPrice);

        // Ensure alice has enough WETH
        deal(WETH, alice, collateralWETH + 10 ether);

        uint256 twyneLTV_ = 9500; // 95% threshold
        createInitialPosition(collateralWETH, 0, targetDebtUSDT, twyneLTV_);
        executePriceDrop(priceDropPct);

        (uint256 B_final, uint256 C_final) = _getBC_test();
        uint256 ltv_bps = C_final > 0 ? (B_final * MAXFACTOR) / C_final : 0;
        console2.log("PythonTest1 B_final", B_final);
        console2.log("PythonTest1 C_final", C_final);
        console2.log("PythonTest1 LTV(bps)", ltv_bps);

        assertApproxEqAbs(ltv_bps, 9600, 300, "LTV should be ~96%");
        assertTrue(alice_morpho_vault.canLiquidate(), "position should be liquidatable");

        setup_approve_customSetup();
        _fundLiquidatorWithCollateral(alice_morpho_vault.collateralForBorrower(B_final, C_final));

        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    /// @notice Morpho-adapted version of Python V2 scenario #2 (93.5% LTV vs 92% threshold)
    function test_m_replicatePythonV2Liquidation_test2() external noGasMetering {
        vm.startPrank(admin);
        twyneVaultManager.setExternalLiqBuffer(address(morpho_intermediate_vault), USDT, 0.99e4, 0);
        twyneVaultManager.setMaxLiquidationLTV(address(morpho_intermediate_vault), USDT, 0.97e4, 0);
        vm.stopPrank();

        uint256 collateralPrice = IOracle(ETH_USDT_ORACLE).price();
        uint256 targetDebtUSDT = 9_350 * 1e6;
        uint256 priceDropPct = 10;

        uint256 preDropValueUSDT = (10_000 * 1e6 * 100) / (100 - priceDropPct);
        uint256 collateralWETH = preDropValueUSDT.mulDivDown(ORACLE_PRICE_SCALE, collateralPrice);

        deal(WETH, alice, collateralWETH + 10 ether);

        uint256 twyneLTV_ = 9200; // 92%
        createInitialPosition(collateralWETH, 0, targetDebtUSDT, twyneLTV_);
        executePriceDrop(priceDropPct);

        (uint256 B_final, uint256 C_final) = _getBC_test();
        uint256 ltv_bps = C_final > 0 ? (B_final * MAXFACTOR) / C_final : 0;
        console2.log("PythonTest2 B_final", B_final);
        console2.log("PythonTest2 C_final", C_final);
        console2.log("PythonTest2 LTV(bps)", ltv_bps);

        assertApproxEqAbs(ltv_bps, 9350, 300, "LTV should be ~93.5%");
        assertTrue(alice_morpho_vault.canLiquidate(), "position should be liquidatable");

        setup_approve_customSetup();
        _fundLiquidatorWithCollateral(alice_morpho_vault.collateralForBorrower(B_final, C_final));

        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    /////////////////////////////////////////////////////////////////
    ///////////////// Revert tests /////////////////////////////////
    /////////////////////////////////////////////////////////////////

    /// @notice Self-liquidation should revert
    function test_m_expectRevert_selfLiquidation() external noGasMetering {
        createInitialPosition(5e18, 0, BORROW_USDT_AMOUNT, twyneLiqLTV);
        executePriceDrop(40);

        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.SelfLiquidation.selector);
        alice_morpho_vault.liquidate();
        vm.stopPrank();
    }

    /// @notice Cannot liquidate after external liquidation
    function test_m_expectRevert_liquidateAfterExternalLiquidation() external noGasMetering {
        test_morpho_setupCompleteExternalLiquidation();

        deal(WETH, liquidator, 100 ether);
        deal(USDT, liquidator, 10_000_000e6);

        vm.startPrank(liquidator);
        SafeERC20.forceApprove(IERC20_OZ(USDT), morpho, type(uint256).max);

        uint256 collateralBefore = alice_morpho_vault.collateralBalance();
        IMorpho(morpho).liquidate({
            marketParams: morphoMarketParams,
            borrower: address(alice_morpho_vault),
            seizedAssets: collateralBefore / 2,
            repaidShares: 0,
            data: ""
        });
        vm.stopPrank();

        assertTrue(alice_morpho_vault.isExternallyLiquidated(), "should be externally liquidated");

        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.ExternallyLiquidated.selector);
        alice_morpho_vault.liquidate();
        vm.stopPrank();
    }

    /////////////////////////////////////////////////////////////////
    // Oracle conversion correctness (target <-> collateral via mo_oracle)
    /////////////////////////////////////////////////////////////////

    /// @notice _convertBaseToCollateral (loan -> collateral) is the Morpho-specific conversion
    ///         since Morpho keeps no receipt token in the CV. Verify it uses mo_oracle exactly,
    ///         observable through collateralForBorrower(0, loanValue), against an independent
    ///         computation at a known oracle price.
    function test_morpho_oracleConversion_inverseMatchesMoOracle() public {
        createInitialPosition(5e18, 0, BORROW_USDT_AMOUNT / 2, twyneLiqLTV);

        // Set an exact, known oracle price: 1 WETH collateral = 2000 USDT loan
        uint256 knownPrice = 2000e18;
        MockMorphoOracle mock = new MockMorphoOracle();
        vm.etch(ETH_USDT_ORACLE, address(mock).code);
        MockMorphoOracle(ETH_USDT_ORACLE).setPrice(knownPrice);
        assertEq(IOracle(ETH_USDT_ORACLE).price(), knownPrice, "oracle price not set");

        uint256 userCollateral =
            alice_morpho_vault.totalAssetsDepositedOrReserved() - alice_morpho_vault.maxRelease();
        uint256 forward = userCollateral.mulDivDown(knownPrice, ORACLE_PRICE_SCALE); // collateral -> loan

        // (1) Round-trip: forward then inverse must return the original user collateral (within 1 wei)
        assertApproxEqAbs(
            alice_morpho_vault.collateralForBorrower(0, forward), userCollateral, 1,
            "round-trip conversion must return user collateral"
        );

        // (2) Sub-collateral loan value must match the exact oracle ratio loan * SCALE / price
        uint256 loanValue = forward * 37 / 100;
        uint256 expected = loanValue.mulDivDown(ORACLE_PRICE_SCALE, knownPrice);
        assertApproxEqAbs(
            alice_morpho_vault.collateralForBorrower(0, loanValue), expected, 1,
            "inverse conversion must match loan * SCALE / mo_oracle price"
        );

        // (3) Loan value exceeding user collateral must be capped at user collateral
        uint256 overCap = (userCollateral + 1 ether).mulDivDown(knownPrice, ORACLE_PRICE_SCALE);
        assertEq(
            alice_morpho_vault.collateralForBorrower(0, overCap), userCollateral,
            "inverse conversion must cap at user collateral"
        );
    }

    /////////////////////////////////////////////////////////////////
    // collateralForBorrower differential vs off-chain model
    /////////////////////////////////////////////////////////////////

    /// @dev Compares the contract's collateralForBorrower(B, C) against an independent pure-math
    ///      implementation (LiquidationMath.borrowerCollateralBase) followed by the same oracle
    ///      conversion. Genuine differential check — two separate implementations of the spec.
    function _assertCollateralForBorrowerMatchesModel() internal view {
        (uint256 B, uint256 C) = _getBC_test();
        uint256 buffer = uint256(twyneVaultManager.externalLiqBuffers(address(morpho_intermediate_vault), USDT));
        uint256 extLiqLtv = ETH_USDT_LLTV * 1e4 / 1e18;
        uint256 maxLTV_t = uint256(twyneVaultManager.maxTwyneLTVs(address(morpho_intermediate_vault), USDT));
        uint256 price = IOracle(ETH_USDT_ORACLE).price();
        uint256 userCollateral =
            alice_morpho_vault.totalAssetsDepositedOrReserved() - alice_morpho_vault.maxRelease();

        uint256 rawBase = LiquidationMath.borrowerCollateralBase(B, C, buffer, extLiqLtv, maxLTV_t);
        uint256 expected = Math.min(userCollateral, rawBase.mulDivDown(ORACLE_PRICE_SCALE, price));
        uint256 actual = alice_morpho_vault.collateralForBorrower(B, C);

        assertApproxEqAbs(actual, expected, 2, "collateralForBorrower diverges from off-chain model");
    }

    /// @notice Safe regime (λ_t ≤ β_safe·λ̃_e): borrower keeps C − B.
    function test_morpho_collateralForBorrower_matchesModel_safeRegime() public {
        createInitialPosition(5e18, 0, BORROW_USDT_AMOUNT / 4, twyneLiqLTV);
        assertFalse(alice_morpho_vault.canLiquidate(), "precond: position must be healthy");
        _assertCollateralForBorrowerMatchesModel();
    }

    /// @notice Interpolation regime (β_safe·λ̃_e < λ_t < λ̃_t^max): linear dynamic incentive.
    function test_morpho_collateralForBorrower_matchesModel_interpolationRegime() public {
        createInitialPosition(5e18, 0, BORROW_USDT_AMOUNT, twyneLiqLTV);
        _setMorphoPriceForTargetLTV(_interpolationTargetLTVBps(2, 5));
        _assertCollateralForBorrowerMatchesModel();
    }

    /// @notice Severely-unhealthy regime (λ_t ≥ λ̃_t^max): borrower gets 0.
    function test_morpho_collateralForBorrower_matchesModel_severelyUnhealthy() public {
        createInitialPosition(5e18, 0, BORROW_USDT_AMOUNT, twyneLiqLTV);
        executePriceDrop(50); // deep drop → λ_t ≥ λ̃_t^max
        (uint256 B, uint256 C) = _getBC_test();
        assertEq(alice_morpho_vault.collateralForBorrower(B, C), 0, "severely unhealthy must give borrower 0");
        _assertCollateralForBorrowerMatchesModel();
    }
}
