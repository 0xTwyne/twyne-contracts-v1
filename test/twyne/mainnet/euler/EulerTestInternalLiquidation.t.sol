// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import "euler-vault-kit/EVault/shared/types/Types.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {EulerCollateralVault} from "src/twyne/EulerCollateralVault.sol";
import {LiquidationMath} from "./LiquidationMath.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";
import {VaultType} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {EulerTestBase} from "./EulerTestBase.t.sol";
import {console2} from "forge-std/console2.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";

interface IWETH is IERC20 {
    receive() external payable;
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

struct LiquidationSnapshot {
    uint256 borrowerEWETH;
    uint256 liquidatorEWETH;
    uint256 vaultEWETH;
    uint256 vaultUSDC;
    uint256 vaultDebt;
    address borrower;
    uint256 maxRepay;
    uint256 totalAssets;
    uint256 maxRelease;
    uint256 expectedCollateralForBorrower;
}

struct PositionData {
    uint256 collateralUSD;
    uint256 borrowedUSD;
    uint256 clpReservedUSD;
    uint256 twyneLTV;
    uint256 twyneLTVThreshold;
    uint256 externalLTV;
    address uoa;
}
struct LiquidationOutcome {
    uint256 borrowerCollateralReceivedUSD;
    uint256 liquidatorCollateralGainedUSD;
    uint256 debtInheritedUSD;
    uint256 clpInheritedUSD;
}

struct PostLiquidationData {
    uint256 borrowerSharesReceived;
    uint256 borrowerWETHReceived;
    uint256 borrowerCollateralReceivedUSD;
    uint256 borrowerUSD_viaEWETH;
    uint256 userCollateralShares;
    uint256 vaultCollateralUSD;
    uint256 debtPaidUSD;
    uint256 netCollateralUSD;
    uint256 clpShares;
    uint256 clpUSD;
    uint256 liquidatorCollateralUSD;
}

struct InterpolationTraceData {
    uint256 numerator;
    uint256 denominator;
    uint256 penalty;
    uint256 baseResult;
    uint256 resultBeforeConversion;
    uint256 collateralAmount_WETH;
    uint256 collateralAmount_shares;
    uint256 availableUserCollateral;
    uint256 finalResult;
}

struct PythonComparisonData {
    uint256 pythonB;
    uint256 pythonC;
    uint256 pythonLTV_bps;
    uint256 pythonNumerator;
    uint256 pythonDenominator;
    uint256 pythonPenalty;
    uint256 pythonBaseResult;
    uint256 pythonResultBeforeConversion;
    uint256 pythonCollateralAmount_WETH;
    uint256 pythonCollateralAmount_shares;
    uint256 pythonFinalResult;
}

/// @notice Test suite overview
///  - Case00–01: verify healthy vaults revert (`β_safe * λ̃_e` guard)
///  - Case10–13: core interpolation band (5 ETH / 16k USDC) with price drops 5–12%
///  - Case14–15: same scenarios but different liquidation LTV to prove invariance
///  - Case20–22 + extra cases: fully liquidated + insolvency branches
///  - LowValues Case10–13: dust-scale positions (1e15 wei collateral, ~3.2 USDC debt)
///      * Each low-value test logs raw USD math + `_convert` params for Python parity
///  - `test_liquidationMathUSD_case*`: numeric trace helpers (logs B/C, raw USD, price per unit, share ER)
///  - `test_e_replicatePythonV2Liquidation_*`: reproductions of the Python V2 scenarios
///  - Fuzz suites: `testFuzz_internalLiquidation_lowValues`, `testFuzz_collateralForBorrower`, `testFuzz_liquidation_holistics`
///  - Revert tests: self-liquidation, externally liquidated, healthy-not-liquidatable, etc.

contract EulerTestInternalLiquidation is EulerTestBase {
    uint256 BORROW_ETH_AMOUNT;

    function setUp() public override {
        super.setUp();
    }

    function createInitialPosition(uint256 C, uint256, /* CLP */ uint256 B, uint256 twyneLTV) public {
        //Pre-setup
        uint16 minLTV = IEVault(eulerUSDC).LTVLiquidation(eulerWETH);
        uint16 extLiqBuffer = twyneVaultManager.externalLiqBuffers(eulerWETH);
        require(uint256(minLTV) * uint256(extLiqBuffer) <= uint256(twyneLTV) * MAXFACTOR, "precond fail");
        require(twyneLTV <= twyneVaultManager.maxTwyneLTVs(eulerWETH), "twyneLTV too high");

        // Bob deposits into eeWETH_intermediate_vault to earn boosted yield
        vm.startPrank(bob);
        IERC20(eulerWETH).approve(address(eeWETH_intermediate_vault), type(uint256).max);
        eeWETH_intermediate_vault.deposit(CREDIT_LP_AMOUNT, bob);
        vm.stopPrank();

        vm.startPrank(alice);
        alice_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.EULER_V2,
                _asset: eulerWETH,
                _targetVault: eulerUSDC,
                _liqLTV: twyneLTV, //this is 9000 then 8600
                _targetAsset: address(0)
            })
        );

        vm.label(address(alice_collateral_vault), "alice_collateral_vault");

        // Alice deposit the eulerWETH token into the collateral vault
        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint256).max);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        // reserve assets from intermediate vault - FIXED: use C (collateral) not B (debt)
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.deposit, (C))
        });

        evc.batch(items);

        // Use the specified B (debt amount) directly instead of calculating it
        // Convert B from USD to USDC units (B is in 6 decimals, USDC is 6 decimals)
        uint256 BORROW_USD_AMOUNT = B; // Use B directly as USDC amount

        // Execute the borrow to create the debt position with your specified amount
        alice_collateral_vault.borrow(BORROW_USD_AMOUNT, alice);

        vm.stopPrank();
    }

    function executePriceDrop(uint256 bpsToPriceDrop) public {
        // --- make position liquidatable (EVault-domain prices) ---
        address eulerRouter = IEVault(eulerUSDC).oracle();
        vm.startPrank(EulerRouter(eulerRouter).governor());
        EulerRouter(eulerRouter).govSetConfig(eulerWETH, USD, address(mockOracle));
        EulerRouter(eulerRouter).govSetConfig(eulerUSDC, USD, address(mockOracle));
        uint256 newWethUsd = WETH_USD_PRICE_INITIAL * (100 - bpsToPriceDrop) / 100;
        mockOracle.setPrice(eulerWETH, USD, newWethUsd);
        mockOracle.setPrice(eulerUSDC, USD, USDC_USD_PRICE_INITIAL);
        vm.stopPrank();

        vm.startPrank(oracleRouter.governor());
        oracleRouter.govSetConfig(eulerWETH, USD, address(mockOracle));
        oracleRouter.govSetConfig(eulerUSDC, USD, address(mockOracle));
        mockOracle.setPrice(eulerWETH, USD, newWethUsd);
        mockOracle.setPrice(eulerUSDC, USD, USDC_USD_PRICE_INITIAL);
        vm.stopPrank();
    }

    function setup_approve_customSetup() internal {
        uint256 debt = IEVault(eulerUSDC).debtOf(address(alice_collateral_vault));
        deal(address(USDC), liquidator, debt + 1_000_000);
        dealEToken(eulerWETH, liquidator, 100 ether);

        vm.startPrank(liquidator);
        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint256).max);
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Helper function to execute liquidation in EVC batch with repay to make position healthy
    function executeLiquidationWithRepay() internal {
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        vm.startPrank(liquidator);
        // First: liquidate (transfers ownership to liquidator)
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.liquidate, ())
        });

        // Second: repay all debt to make position healthy
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.repay, (alice_collateral_vault.maxRepay()))
        });

        evc.batch(items);
        vm.stopPrank();
    }

    /////////////////////////////////////////////////////////////////
    ////////////////Case 0: λ_t ≤ β_safe * λ̃_e //////////////////////
    /////////////////////////////////////////////////////////////////

    function test_e_expectRevert_internalLiquidation_case00() external noGasMetering {
        // Case 0: λ_t ≤ β_safe * λ̃_e
        createInitialPosition(5e18, 0, 16000e6, 9000);

        vm.warp(block.timestamp + 1);

        executePriceDrop(5);

        setup_approve_customSetup();

        // Call the handler
        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.HealthyNotLiquidatable.selector);
        alice_collateral_vault.liquidate();
        vm.stopPrank();
    }

    //LTV at limit upper limit before interpolation
    function test_e_expectRevert_internalLiquidation_case01() external noGasMetering {
        createInitialPosition(5e18, 0, 16_000e6, 9000);

        vm.warp(block.timestamp + 1);

        executePriceDrop(9);

        setup_approve_customSetup();

        // Call the handler
        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.HealthyNotLiquidatable.selector);
        alice_collateral_vault.liquidate();
        vm.stopPrank();
    }

    //Case 1: β_safe * λ̃_e < λ_t < λ̃_t^max (Interpolation Range)

    function test_e_internalLiquidation_case10() external noGasMetering {
        createInitialPosition(5e18, 0, 16_000e6, 8500);

        //Makes position liquidatable
        executePriceDrop(5);

        //Checks if position is in interpolation range
        _assertInterpolating();

        //Approves collateral vault to be used for liquidation
        setup_approve_customSetup();

        // Snapshot before
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();

        // Execute liquidation + repay batch
        executeLiquidationWithRepay();

        // Assert all changes
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_e_internalLiquidation_case11() external noGasMetering {
        createInitialPosition(5e18, 0, 16_000e6, 8500);

        executePriceDrop(7);

        //Checks if position is in interpolation range
        _assertInterpolating();

        //Approves collateral vault to be used for liquidation
        setup_approve_customSetup();

        // Snapshot before
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();

        // Execute liquidation + repay batch
        executeLiquidationWithRepay();

        // Assert all changes
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_e_internalLiquidation_case12() external noGasMetering {
        createInitialPosition(5e18, 0, 16_000e6, 8500);

        executePriceDrop(10);
        //Checks if position is in interpolation range
        _assertInterpolating();

        //Approves collateral vault to be used for liquidation
        setup_approve_customSetup();

        // Snapshot before
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();

        // Execute liquidation + repay batch
        executeLiquidationWithRepay();

        // Assert all changes
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_e_internalLiquidation_case13() external noGasMetering {
        createInitialPosition(5e18, 0, 16_000e6, 8500);

        // Makes position liquidatable
        executePriceDrop(12);

        // Approves collateral vault to be used for liquidation
        setup_approve_customSetup();

        // Snapshot before - this will log all the LTV details
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();

        // Execute liquidation + repay batch
        executeLiquidationWithRepay();

        // Assert all changes
        _assertAfterLiquidationAndRepay(snapshot);
    }

    // Case 14 & 15 proof that results are the same as case 12 & 13, but different liq ltv
    // this validates the idea that inteporlation is not affected by liq ltv
    function test_e_internalLiquidation_case14() external noGasMetering {
        createInitialPosition(5e18, 0, 16_000e6, 9000);

        // Makes position liquidatable
        executePriceDrop(10);

        // Approves collateral vault to be used for liquidation
        setup_approve_customSetup();

        // Snapshot before - this will log all the LTV details
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();

        // Execute liquidation + repay batch
        executeLiquidationWithRepay();

        // Assert all changes
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_e_internalLiquidation_case15() external noGasMetering {
        createInitialPosition(5e18, 0, 16_000e6, 9000);

        // Makes position liquidatable
        executePriceDrop(12);

        // Approves collateral vault to be used for liquidation
        setup_approve_customSetup();

        // Snapshot before - this will log all the LTV details
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();

        // Execute liquidation + repay batch
        executeLiquidationWithRepay();

        // Assert all changes
        _assertAfterLiquidationAndRepay(snapshot);
    }

    /////Case 3: λ_t > λ̃_t^max (Fully Liquidated Range)

    function test_e_internalLiquidation_case20() external noGasMetering {
        createInitialPosition(5e18, 0, 16_000e6, 9000);

        executePriceDrop(13);

        setup_approve_customSetup();

        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();

        executeLiquidationWithRepay();

        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_e_internalLiquidation_case21() external noGasMetering {
        createInitialPosition(5e18, 0, 16_000e6, 9000);

        executePriceDrop(16);

        setup_approve_customSetup();

        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();

        executeLiquidationWithRepay();

        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_e_internalLiquidation_case22() external noGasMetering {
        createInitialPosition(5e18, 0, 16_000e6, 9000);

        executePriceDrop(18);

        setup_approve_customSetup();

        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();

        executeLiquidationWithRepay();

        _assertAfterLiquidationAndRepay(snapshot);
    }
    /////////////////////////////////////////////////////////////////
    ////////////////////////Extra cases /////////////////////////////
    /////////////////////////////////////////////////////////////////

    // _lowValues cases are meant to compare deviation between python and solidity

    function test_e_internalLiquidation_lowValues_case10() external noGasMetering {
        createInitialPosition(1e15, 0, 32e5, 8500);

        //Makes position liquidatable
        executePriceDrop(5);

        // Trace liquidation math for Python comparison
        _traceLiquidationMathCurrentState("LowValues Case10 (5% drop)");

        //Checks if position is in interpolation range
        _assertInterpolating();

        //Approves collateral vault to be used for liquidation
        setup_approve_customSetup();

        // Snapshot before
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();

        // Execute liquidation + repay batch
        executeLiquidationWithRepay(); //LTV 8535

        // Assert all changes
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_e_internalLiquidation_lowValues_case11() external noGasMetering {
        createInitialPosition(1e15, 0, 32e5, 8500);

        executePriceDrop(7);

        // Trace liquidation math for Python comparison
        _traceLiquidationMathCurrentState("LowValues Case11 (7% drop)");

        //Checks if position is in interpolation range
        _assertInterpolating();

        //Approves collateral vault to be used for liquidation
        setup_approve_customSetup();

        // Snapshot before
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();

        // Execute liquidation + repay batch
        executeLiquidationWithRepay(); // 8719

        // Assert all changes
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_e_internalLiquidation_lowValues_case12() external noGasMetering {
        createInitialPosition(1e15, 0, 32e5, 8500);

        executePriceDrop(10);

        // Trace liquidation math for Python comparison
        _traceLiquidationMathCurrentState("LowValues Case12 (10% drop)");

        //Checks if position is in interpolation range
        _assertInterpolating();

        //Approves collateral vault to be used for liquidation
        setup_approve_customSetup();

        // Snapshot before
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();

        // Execute liquidation + repay batch
        executeLiquidationWithRepay(); //9009

        // Assert all changes
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_e_internalLiquidation_lowValues_case13() external noGasMetering {
        createInitialPosition(1e15, 0, 32e5, 8500);

        // Makes position liquidatable
        executePriceDrop(12);

        // Trace liquidation math for Python comparison
        _traceLiquidationMathCurrentState("LowValues Case13 (12% drop)");

        // Approves collateral vault to be used for liquidation
        setup_approve_customSetup();

        // Snapshot before - this will log all the LTV details
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();

        // Execute liquidation + repay batch
        executeLiquidationWithRepay(); //9214

        // Assert all changes
        _assertAfterLiquidationAndRepay(snapshot);
    }

    /////////////////////////////////////////////////
    /// Numeric parity tests vs. python reference ///
    /// These tests isolate the pure USD math (B,C, penalties) and then
    /// dump every conversion step so off-chain scripts can ingest the
    /// exact Solidity dataset and reproduce it 1:1.
    /////////////////////////////////////////////////

    function _traceLiquidationMath(
        string memory label,
        uint256 priceDropBps,
        uint256 collateral,
        uint256 clp,
        uint256 borrow,
        uint256 twyneLTV
    ) internal {
        console2.log("=== LIQUIDATION MATH TRACE ===");
        console2.log("Label", label);
        createInitialPosition(collateral, clp, borrow, twyneLTV);
        executePriceDrop(priceDropBps);
        _traceLiquidationMathCurrentState(label);
    }

    /// @notice Traces liquidation math for the current vault state (position already created)
    function _traceLiquidationMathCurrentState(string memory label) internal view {
        console2.log("=== LIQUIDATION MATH TRACE ===");
        console2.log("Label", label);
        (uint256 B, uint256 C) = _getBC();
        uint256 rawBase = LiquidationMath.borrowerCollateralBase(
            B,
            C,
            twyneVaultManager.externalLiqBuffers(eulerWETH),
            IEVault(eulerUSDC).LTVLiquidation(eulerWETH),
            twyneVaultManager.maxTwyneLTVs(eulerWETH)
        );
        console2.log("LiquidationMath raw base", rawBase);
        if (rawBase == 0) {
            console2.log("convertBaseToCollateral skipped (rawBase == 0)");
            return;
        }
        (
            uint256 usdValue,
            uint256 underlyingAmount,
            uint256 shareAmount,
            uint256 pricePerUnit,
            uint256 shareExchangeRate
        ) = _convertBaseToCollateralDebug(alice_collateral_vault, rawBase);
        console2.log("convertBaseToCollateral usdValue", usdValue);
        console2.log("convertBaseToCollateral underlyingAmount", underlyingAmount);
        console2.log("convertBaseToCollateral shareAmount", shareAmount);
        console2.log("convertBaseToCollateral pricePerUnit", pricePerUnit);
        console2.log("convertBaseToCollateral shareExchangeRate", shareExchangeRate);
        console2.log("totalAssetsDepositedOrReserved", alice_collateral_vault.totalAssetsDepositedOrReserved());
        console2.log("maxRelease", alice_collateral_vault.maxRelease());
    }

    function _convertBaseToCollateralDebug(EulerCollateralVault vault, uint256 collateralValue)
        internal
        view
        returns (uint256 usdValue, uint256 underlyingAmount, uint256 shareAmount, uint256 pricePerUnit, uint256 shareExchangeRate)
    {
        usdValue = collateralValue;
        address unitOfAccount = IEVault(vault.intermediateVault()).unitOfAccount();
        address assetAddr = vault.asset();
        address underlyingAsset = IEVault(assetAddr).asset();

        underlyingAmount = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(collateralValue, unitOfAccount, underlyingAsset);
        uint256 convertedShares = IEVault(assetAddr).convertToShares(underlyingAmount);
        uint256 cap = vault.totalAssetsDepositedOrReserved() - vault.maxRelease();
        shareAmount = Math.min(cap, convertedShares);
        pricePerUnit = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(1e18, unitOfAccount, underlyingAsset);
        shareExchangeRate = underlyingAmount > 0 ? convertedShares * 1e18 / underlyingAmount : 0;
    }

    function test_liquidationMathUSD_case10() external noGasMetering {
        _traceLiquidationMath("Case10 (5% drop)", 5, 5e18, 0, 16_000e6, 8500);
    }

    function test_liquidationMathUSD_case11() external noGasMetering {
        _traceLiquidationMath("Case11 (7% drop)", 7, 5e18, 0, 16_000e6, 8500);
    }

    function test_liquidationMathUSD_case12() external noGasMetering {
        _traceLiquidationMath("Case12 (10% drop)", 10, 5e18, 0, 16_000e6, 8500);
    }

    function test_liquidationMathUSD_case13() external noGasMetering {
        _traceLiquidationMath("Case13 (12% drop)", 12, 5e18, 0, 16_000e6, 8500);
    }

    function test_liquidationMathUSD_case20() external noGasMetering {
        _traceLiquidationMath("Case20 (13% drop, twyneLTV 90%)", 13, 5e18, 0, 16_000e6, 9000);
    }

    function test_liquidationMathUSD_case21() external noGasMetering {
        _traceLiquidationMath("Case21 (16% drop, twyneLTV 90%)", 16, 5e18, 0, 16_000e6, 9000);
    }

    function test_liquidationMathUSD_case22() external noGasMetering {
        _traceLiquidationMath("Case22 (18% drop, twyneLTV 90%)", 18, 5e18, 0, 16_000e6, 9000);
    }

    //Corner Cases

    //This case prove that if current ltv > 100% (in this case 100108209(1e8 precision))
    //the liquidator can liquidate position, BUT he loses money
    function test_e_internalLiquidation_case_ltv_higher_than_max() external noGasMetering {
        createInitialPosition(5e18, 0, 16_000e6, 9000);

        executePriceDrop(19);

        setup_approve_customSetup();

        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();

        executeLiquidationWithRepay();

        _assertAfterLiquidationAndRepay(snapshot);
    }

    //Same as above, but with different liq ltv
    function test_e_internalLiquidation_insolvency() external noGasMetering {
        createInitialPosition(5e18, 0, 16_000e6, 9000);

        executePriceDrop(40);

        setup_approve_customSetup();

        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();

        executeLiquidationWithRepay();

        _assertAfterLiquidationAndRepay(snapshot);
    }

    /////////////////////////////////////////////////////////////////
    ///////////////// /////Python Comparison Tests /////////////////////////////
    /////////////////////////////////////////////////////////////////

    //Python results:
    //     === V2 LIQUIDATION SUMMARY ===

    // Fixed Protocol Parameters:
    // External Collateral Liquidation LTV (λ̃_e^C): 85.00%
    // External Credit Liquidation LTV (λ̃_e^CLP): 85.00%
    // Safety Buffer (β_safe): 0.990
    // Max Twyne Liquidation LTV (λ̃_t^max): 97.00%
    // Penalty Tax (τ): 0.00%

    // Borrower Position (Pre-liquidation):
    // Collateral: 100.0000
    // Borrowed: 96.0000
    // CLP Reserved: 12.8936
    // Twyne LTV: 0.9600 (threshold: 0.9500)
    // External LTV: 0.8504

    // Borrower Outcome:
    // Collateral Remaining: 1.2335
    // Debt Remaining: 0.0000
    // CLP Remaining: 0.0000

    // Bob Gains:
    // Collateral Gained: 98.7665
    // Debt Inherited: 96.0000
    // CLP Inherited: 12.8936

    // Bob Final Position (Post-liquidation):
    // Collateral: 200.0000 → 298.7665
    // Borrowed: 140.0000 → 236.0000
    // CLP Reserved: 13.9037 → 26.7974
    // Twyne LTV: 0.7000 → 0.7899
    // Liquidation LTV: 0.9000 → 0.9170 (forced by CLP invariant)
    // External LTV: 0.7249 (must be < 0.8500)
    // Ideal CLP for position: 26.7974 (actual: 26.7974)

    // Protocol Fee: 0.0000

    // Effective Liquidation Incentive:
    // Net Gain: 2.7665
    // Incentive Rate: 2.88%

    // Test Conditions
    // Solidity Test Setup:
    // Uses 10,000 USD collateral instead of 100 USD for better precision
    // Executes a price drop to reach the target LTV because:
    // Creating a position directly at 96% LTV would fail with E_AccountLiquidity() (Euler's safe threshold is ~84.15%)
    // Strategy: Create position at ~86.4% LTV (11,111 USD collateral, 9,600 USD debt), then drop WETH price by 10% to
    // bring collateral value to 10,000 USD, achieving 96% LTV
    // This simulates a market price drop that makes the position liquidatable
    // Python Script:
    // Uses 100 USD collateral directly
    // Creates position at target LTV (96%) without price manipulation
    function test_e_replicatePythonV2Liquidation_test1() external noGasMetering {
        // === SETUP: Configure protocol parameters to match Python script ===
        vm.startPrank(admin); // or owner

        // Set Safety Buffer (β_safe) = 99% = 0.990
        // externalLiqBuffer = 0.99e4 = 9900
        twyneVaultManager.setExternalLiqBuffer(eulerWETH, 0.99e4); // 99%

        // Set Max Twyne Liquidation LTV (λ̃_t^max) = 97% = 0.97
        // maxTwyneLTVs = 0.97e4 = 9700
        twyneVaultManager.setMaxLiquidationLTV(eulerWETH, 0.97e4); // 97%

        vm.stopPrank();

        // Verify the parameters are set correctly
        uint16 extLiqBuffer = twyneVaultManager.externalLiqBuffers(eulerWETH);
        uint16 maxLTV = twyneVaultManager.maxTwyneLTVs(eulerWETH);

        assertEq(extLiqBuffer, 9900, "Safety buffer should be 99%");
        assertEq(maxLTV, 9700, "Max LTV should be 97%");

        // === Now create position with 10,000 USD collateral, 9,600 USD debt ===

        // Step 1: Get the unit of account (USD) from intermediate vault
        address uoa = IEVault(eeWETH_intermediate_vault).unitOfAccount();

        // Step 2: Get the current WETH price in USD
        uint256 wethPriceUSD = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(
            1e18, // 1 WETH (18 decimals)
            eulerWETH,
            uoa // USD unit of account
        );

        // Step 3: Target final state: C = 10,000 USD, B = 9,600 USD, LTV = 96%
        uint256 targetCollateralUSD = 10000 * 1e18; // 10,000 USD
        uint256 targetDebtUSDC = 9600 * 1e6; // 9,600 USDC (96% of 10,000)

        // Step 4: Strategy to reach 96% LTV - drop price by 10% to reach target
        uint256 priceDropBps = 1000; // 10% = 1000 bps
        uint256 initialCollateralUSD = (targetCollateralUSD * 10000) / (10000 - priceDropBps);
        uint256 initialCollateralWETH = (initialCollateralUSD * 1e18) / wethPriceUSD;

        // Set twyneLTV to 95% (9500) as the liquidation threshold
        uint256 twyneLTV = 9500; // 95%

        // Freeze time before position creation to prevent interest accrual
        uint256 frozenTimestamp = block.timestamp;
        vm.warp(frozenTimestamp);

        createInitialPosition(initialCollateralWETH, 0, targetDebtUSDC, twyneLTV);

        // Reset timestamp after position creation to keep it frozen
        vm.warp(frozenTimestamp);

        // Step 5: Execute price drop to reach target state

        // Execute price drop - inline version with correct basis points
        // bpsToPriceDrop is in basis points (1000 = 10%), so use 10000 instead of 100
        address eulerRouter = IEVault(eulerUSDC).oracle();
        vm.startPrank(EulerRouter(eulerRouter).governor());
        EulerRouter(eulerRouter).govSetConfig(eulerWETH, USD, address(mockOracle));
        EulerRouter(eulerRouter).govSetConfig(eulerUSDC, USD, address(mockOracle));
        uint256 newWethUsd = WETH_USD_PRICE_INITIAL * (10000 - priceDropBps) / 10000; // Fixed: use 10000 for basis
            // points
        mockOracle.setPrice(eulerWETH, USD, newWethUsd);
        mockOracle.setPrice(eulerUSDC, USD, USDC_USD_PRICE_INITIAL);
        vm.stopPrank();

        vm.startPrank(oracleRouter.governor());
        oracleRouter.govSetConfig(eulerWETH, USD, address(mockOracle));
        oracleRouter.govSetConfig(eulerUSDC, USD, address(mockOracle));
        mockOracle.setPrice(eulerWETH, USD, newWethUsd);
        mockOracle.setPrice(eulerUSDC, USD, USDC_USD_PRICE_INITIAL);
        vm.stopPrank();

        // Freeze time again after price drop to prevent interest accrual before liquidation
        vm.warp(frozenTimestamp);

        // Step 7: Verify final position (should be at 96% LTV)
        (uint256 B_final, uint256 C_final) = _getBC();

        // Create struct to hold position data (reduces stack depth)
        PositionData memory preLiquidation;
        preLiquidation.uoa = IEVault(alice_collateral_vault.intermediateVault()).unitOfAccount();
        preLiquidation.collateralUSD = C_final;
        preLiquidation.borrowedUSD = B_final;
        preLiquidation.clpReservedUSD = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(
            alice_collateral_vault.maxRelease(), alice_collateral_vault.asset(), preLiquidation.uoa
        );
        preLiquidation.twyneLTV = (B_final * MAXFACTOR) / C_final;
        preLiquidation.twyneLTVThreshold = alice_collateral_vault.twyneLiqLTV();
        (uint256 extCollateralScaledByLiqLTV, uint256 extBorrowDebtValue) =
            IEVault(eulerUSDC).accountLiquidity(address(alice_collateral_vault), true);
        // externalCollateralScaledByLiqLTV = actualCollateralValue * externalLiquidationLTV
        // So: LTV = debt / collateral = (debt * externalLiquidationLTV) / externalCollateralScaledByLiqLTV
        uint256 extLiqLTV = IEVault(eulerUSDC).LTVLiquidation(eulerWETH); // 1e4 precision
        preLiquidation.externalLTV = extCollateralScaledByLiqLTV > 0
            ? (extBorrowDebtValue * extLiqLTV * MAXFACTOR) / extCollateralScaledByLiqLTV
            : 0;

        console2.log("=== BORROWER POSITION (Pre-liquidation) ===");
        console2.log("Collateral (USD):", preLiquidation.collateralUSD);
        console2.log("Borrowed (USD):", preLiquidation.borrowedUSD);
        console2.log("CLP Reserved (USD):", preLiquidation.clpReservedUSD);
        console2.log("Twyne LTV (bps):", preLiquidation.twyneLTV);
        console2.log("Twyne LTV threshold (bps):", preLiquidation.twyneLTVThreshold);
        console2.log("External LTV (bps):", preLiquidation.externalLTV);

        assertApproxEqRel(preLiquidation.twyneLTV, 9600, 0.02e18, "LTV should be approximately 96% after price drop");
        assertTrue(alice_collateral_vault.canLiquidate(), "Position should be liquidatable");

        // Step 8: Setup liquidator and execute liquidation
        // Freeze time before capturing debt to prevent interest accrual
        vm.warp(frozenTimestamp);

        // Capture debt AFTER freezing time to get accurate value
        uint256 debt = IEVault(eulerUSDC).debtOf(address(alice_collateral_vault));
        deal(address(USDC), liquidator, debt + 1_000_000);
        dealEToken(eulerWETH, liquidator, alice_collateral_vault.collateralForBorrower(B_final, C_final) + 10 ether);

        vm.startPrank(liquidator);
        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint256).max);
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint256).max);
        vm.stopPrank();

        // Get balances before liquidation
        uint256 borrowerEWETHBefore = IERC20(eulerWETH).balanceOf(alice);

        console2.log("=== EXECUTING LIQUIDATION ===");
        executeLiquidationWithRepay();

        // Calculate and log outcomes
        uint256 borrowerEWETHAfter = IERC20(eulerWETH).balanceOf(alice);

        address assetAddr = alice_collateral_vault.asset();
        address underlyingAsset = IEVault(assetAddr).asset();

        // Group post-liquidation calculations into struct to reduce stack depth
        PostLiquidationData memory postLiquidation;
        postLiquidation.borrowerSharesReceived = borrowerEWETHAfter - borrowerEWETHBefore;

        // Convert eWETH shares → WETH → USD (to match original interpolation USD value)
        postLiquidation.borrowerWETHReceived =
            IEVault(assetAddr).convertToAssets(postLiquidation.borrowerSharesReceived);
        postLiquidation.borrowerCollateralReceivedUSD = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(
            postLiquidation.borrowerWETHReceived, underlyingAsset, preLiquidation.uoa
        );

        // Also quote eWETH directly for comparison (contract's _getBC() pattern)
        postLiquidation.borrowerUSD_viaEWETH = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(
            postLiquidation.borrowerSharesReceived, assetAddr, preLiquidation.uoa
        );

        console2.log("=== BORROWER COLLATERAL (Post-liquidation) ===");
        console2.log("Borrower Collateral Gained (eWETH shares):", postLiquidation.borrowerSharesReceived);
        console2.log("Borrower Collateral Gained (WETH underlying):", postLiquidation.borrowerWETHReceived);
        console2.log("Borrower Collateral Gained (USD via WETH):", postLiquidation.borrowerCollateralReceivedUSD);
        console2.log("Borrower Collateral Gained (USD via eWETH direct):", postLiquidation.borrowerUSD_viaEWETH);

        // Get vault user collateral (C) after liquidation - matching _getBC() approach
        // Quote: totalAssetsDepositedOrReserved - maxRelease() (user collateral, excluding CLP)
        // Use: eWETH price directly (matching contract's _getBC() pattern)
        postLiquidation.userCollateralShares =
            alice_collateral_vault.totalAssetsDepositedOrReserved() - alice_collateral_vault.maxRelease();
        postLiquidation.vaultCollateralUSD = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(
            postLiquidation.userCollateralShares, assetAddr, preLiquidation.uoa
        );

        // Get debt paid (convert USDC to USD)
        postLiquidation.debtPaidUSD =
            EulerRouter(twyneVaultManager.oracleRouter()).getQuote(debt, eulerUSDC, preLiquidation.uoa);

        // Calculate net collateral (C - debt paid)
        postLiquidation.netCollateralUSD = postLiquidation.vaultCollateralUSD > postLiquidation.debtPaidUSD
            ? postLiquidation.vaultCollateralUSD - postLiquidation.debtPaidUSD
            : 0;

        // Get CLP after liquidation - use eWETH price directly (matching contract's approach)
        postLiquidation.clpShares = alice_collateral_vault.maxRelease();
        postLiquidation.clpUSD = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(
            postLiquidation.clpShares, assetAddr, preLiquidation.uoa
        );

        // Calculate liquidator collateral = C - Borrower Collateral
        // Note: C is user collateral (excluding CLP), so liquidator gets: C - Borrower Collateral
        // (CLP is already excluded from C)
        postLiquidation.liquidatorCollateralUSD = postLiquidation.vaultCollateralUSD
            > postLiquidation.borrowerCollateralReceivedUSD
            ? postLiquidation.vaultCollateralUSD - postLiquidation.borrowerCollateralReceivedUSD
            : 0;

        console2.log("=== VAULT COLLATERAL & DEBT (Post-liquidation) ===");
        console2.log("Vault Collateral C (USD):", postLiquidation.vaultCollateralUSD);
        console2.log("CLP Reserved (USD):", postLiquidation.clpUSD);
        console2.log("Borrower Collateral (USD):", postLiquidation.borrowerCollateralReceivedUSD);
        console2.log("Liquidator Collateral (C - Borrower, USD):", postLiquidation.liquidatorCollateralUSD);
        console2.log("Debt Paid (USD):", postLiquidation.debtPaidUSD);
        console2.log("Net Collateral (C - debt paid, USD):", postLiquidation.netCollateralUSD);
    }

    //Python results for test 2:
    // === V2 LIQUIDATION SUMMARY ===

    // Fixed Protocol Parameters:
    // External Collateral Liquidation LTV (λ̃_e^C): 85.00%
    // External Credit Liquidation LTV (λ̃_e^CLP): 85.00%
    // Safety Buffer (β_safe): 0.990
    // Max Twyne Liquidation LTV (λ̃_t^max): 97.00%
    // Penalty Tax (τ): 0.00%

    // Borrower Position (Pre-liquidation):
    // Collateral: 100.0000
    // Borrowed: 93.5000
    // CLP Reserved: 9.3286
    // Twyne LTV: 0.9350 (threshold: 0.9200)
    // External LTV: 0.8552

    // Borrower Outcome:
    // Collateral Remaining: 4.3171
    // Debt Remaining: 0.0000
    // CLP Remaining: 0.0000

    // Charlie (CLP) Gains:
    // Collateral Gained: 95.6829
    // Debt Inherited: 93.5000
    // CLP Inherited: 9.3286

    // Charlie (CLP) Final Position (Post-liquidation):
    // Collateral: 50.0000 → 145.6829
    // Borrowed: 0.0000 → 93.5000
    // CLP Reserved: 0.0000 → 9.3286
    // Twyne LTV: 0.0000 → 0.6418
    // Liquidation LTV: 0.8415 → 0.8954 (forced by CLP invariant)
    // External LTV: 0.6032 (must be < 0.8500)
    // Ideal CLP for position: 9.3286 (actual: 9.3286)

    // Protocol Fee: 0.0000

    // Effective Liquidation Incentive:
    // Net Gain: 2.1829
    // Incentive Rate: 2.33%
    function test_e_replicatePythonV2Liquidation_test2() external noGasMetering {
        // === SETUP: Configure protocol parameters to match Python script Test 2 ===
        // Test 2: 93.5% LTV scenario
        vm.startPrank(admin);

        // Set Safety Buffer (β_safe) = 99% = 0.990
        twyneVaultManager.setExternalLiqBuffer(eulerWETH, 0.99e4); // 99%

        // Set Max Twyne Liquidation LTV (λ̃_t^max) = 97% = 0.97
        twyneVaultManager.setMaxLiquidationLTV(eulerWETH, 0.97e4); // 97%

        vm.stopPrank();

        // Verify the parameters are set correctly
        uint16 extLiqBuffer = twyneVaultManager.externalLiqBuffers(eulerWETH);
        uint16 maxLTV = twyneVaultManager.maxTwyneLTVs(eulerWETH);

        assertEq(extLiqBuffer, 9900, "Safety buffer should be 99%");
        assertEq(maxLTV, 9700, "Max LTV should be 97%");

        // === Test 2: Target 93.5% LTV with 10,000 USD collateral, 9,350 USD debt ===
        // Step 1: Get the unit of account (USD) from intermediate vault
        address uoa = IEVault(eeWETH_intermediate_vault).unitOfAccount();

        // Step 2: Get the current WETH price in USD
        uint256 wethPriceUSD = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(
            1e18, // 1 WETH (18 decimals)
            eulerWETH,
            uoa // USD unit of account
        );

        // Step 3: Target final state: C = 10,000 USD, B = 9,350 USD, LTV = 93.5%
        uint256 targetCollateralUSD = 10000 * 1e18; // 10,000 USD
        uint256 targetDebtUSDC = 9350 * 1e6; // 9,350 USDC (93.5% of 10,000)

        // Step 4: Strategy to reach 93.5% LTV - drop price by 10% to reach target
        uint256 priceDropBps = 1000; // 10% = 1000 bps
        uint256 initialCollateralUSD = (targetCollateralUSD * 10000) / (10000 - priceDropBps);
        uint256 initialCollateralWETH = (initialCollateralUSD * 1e18) / wethPriceUSD;

        // Set twyneLTV to 92% (9200) as the liquidation threshold
        uint256 twyneLTV = 9200; // 92%

        // Freeze time before position creation to prevent interest accrual
        uint256 frozenTimestamp = block.timestamp;
        vm.warp(frozenTimestamp);

        createInitialPosition(initialCollateralWETH, 0, targetDebtUSDC, twyneLTV);

        // Reset timestamp after position creation to keep it frozen
        vm.warp(frozenTimestamp);

        // Step 5: Execute price drop to reach target state (93.5% LTV)

        // Execute price drop
        address eulerRouter = IEVault(eulerUSDC).oracle();
        vm.startPrank(EulerRouter(eulerRouter).governor());
        EulerRouter(eulerRouter).govSetConfig(eulerWETH, USD, address(mockOracle));
        EulerRouter(eulerRouter).govSetConfig(eulerUSDC, USD, address(mockOracle));
        uint256 newWethUsd = WETH_USD_PRICE_INITIAL * (10000 - priceDropBps) / 10000;
        mockOracle.setPrice(eulerWETH, USD, newWethUsd);
        mockOracle.setPrice(eulerUSDC, USD, USDC_USD_PRICE_INITIAL);
        vm.stopPrank();

        vm.startPrank(oracleRouter.governor());
        oracleRouter.govSetConfig(eulerWETH, USD, address(mockOracle));
        oracleRouter.govSetConfig(eulerUSDC, USD, address(mockOracle));
        mockOracle.setPrice(eulerWETH, USD, newWethUsd);
        mockOracle.setPrice(eulerUSDC, USD, USDC_USD_PRICE_INITIAL);
        vm.stopPrank();

        // Freeze time again after price drop
        vm.warp(frozenTimestamp);

        // Step 7: Verify final position (should be at 93.5% LTV)
        (uint256 B_final, uint256 C_final) = _getBC();

        // Create struct to hold position data
        PositionData memory preLiquidation;
        preLiquidation.uoa = IEVault(alice_collateral_vault.intermediateVault()).unitOfAccount();
        preLiquidation.collateralUSD = C_final;
        preLiquidation.borrowedUSD = B_final;
        preLiquidation.clpReservedUSD = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(
            alice_collateral_vault.maxRelease(), alice_collateral_vault.asset(), preLiquidation.uoa
        );
        preLiquidation.twyneLTV = (B_final * MAXFACTOR) / C_final;
        preLiquidation.twyneLTVThreshold = alice_collateral_vault.twyneLiqLTV();
        (uint256 extCollateralScaledByLiqLTV, uint256 extBorrowDebtValue) =
            IEVault(eulerUSDC).accountLiquidity(address(alice_collateral_vault), true);
        uint256 extLiqLTV = IEVault(eulerUSDC).LTVLiquidation(eulerWETH);
        preLiquidation.externalLTV = extCollateralScaledByLiqLTV > 0
            ? (extBorrowDebtValue * extLiqLTV * MAXFACTOR) / extCollateralScaledByLiqLTV
            : 0;

        console2.log("=== BORROWER POSITION (Pre-liquidation) ===");
        console2.log("Collateral (USD):", preLiquidation.collateralUSD);
        console2.log("Borrowed (USD):", preLiquidation.borrowedUSD);
        console2.log("CLP Reserved (USD):", preLiquidation.clpReservedUSD);
        console2.log("Twyne LTV (bps):", preLiquidation.twyneLTV);
        console2.log("Twyne LTV threshold (bps):", preLiquidation.twyneLTVThreshold);
        console2.log("External LTV (bps):", preLiquidation.externalLTV);

        assertApproxEqRel(preLiquidation.twyneLTV, 9350, 0.02e18, "LTV should be approximately 93.5% after price drop");
        assertTrue(alice_collateral_vault.canLiquidate(), "Position should be liquidatable");

        // Step 8: Setup liquidator and execute liquidation
        vm.warp(frozenTimestamp);

        uint256 debt = IEVault(eulerUSDC).debtOf(address(alice_collateral_vault));
        deal(address(USDC), liquidator, debt + 1_000_000);
        dealEToken(eulerWETH, liquidator, alice_collateral_vault.collateralForBorrower(B_final, C_final) + 10 ether);

        vm.startPrank(liquidator);
        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint256).max);
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint256).max);
        vm.stopPrank();

        // Get balances before liquidation
        uint256 borrowerEWETHBefore = IERC20(eulerWETH).balanceOf(alice);

        console2.log("=== EXECUTING LIQUIDATION ===");
        _traceInterpolationMath(B_final, C_final);
        executeLiquidationWithRepay();

        uint256 borrowerEWETHAfter = IERC20(eulerWETH).balanceOf(alice);

        address assetAddr = alice_collateral_vault.asset();
        address underlyingAsset = IEVault(assetAddr).asset();

        // Group post-liquidation calculations into struct to reduce stack depth
        PostLiquidationData memory postLiquidation;
        postLiquidation.borrowerSharesReceived = borrowerEWETHAfter - borrowerEWETHBefore;

        // Convert eWETH shares → WETH → USD (to match original interpolation USD value)
        postLiquidation.borrowerWETHReceived =
            IEVault(assetAddr).convertToAssets(postLiquidation.borrowerSharesReceived);
        postLiquidation.borrowerCollateralReceivedUSD = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(
            postLiquidation.borrowerWETHReceived, underlyingAsset, preLiquidation.uoa
        );

        // Also quote eWETH directly for comparison (contract's _getBC() pattern)
        postLiquidation.borrowerUSD_viaEWETH = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(
            postLiquidation.borrowerSharesReceived, assetAddr, preLiquidation.uoa
        );

        console2.log("=== BORROWER COLLATERAL (Post-liquidation) ===");
        console2.log("Borrower Collateral Gained (eWETH shares):", postLiquidation.borrowerSharesReceived);
        console2.log("Borrower Collateral Gained (WETH underlying):", postLiquidation.borrowerWETHReceived);
        console2.log("Borrower Collateral Gained (USD via WETH):", postLiquidation.borrowerCollateralReceivedUSD);
        console2.log("Borrower Collateral Gained (USD via eWETH direct):", postLiquidation.borrowerUSD_viaEWETH);

        // Get vault user collateral (C) after liquidation - matching _getBC() approach
        // Quote: totalAssetsDepositedOrReserved - maxRelease() (user collateral, excluding CLP)
        // Use: eWETH price directly (matching contract's _getBC() pattern)
        postLiquidation.userCollateralShares =
            alice_collateral_vault.totalAssetsDepositedOrReserved() - alice_collateral_vault.maxRelease();
        postLiquidation.vaultCollateralUSD = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(
            postLiquidation.userCollateralShares, assetAddr, preLiquidation.uoa
        );

        // Get debt paid (convert USDC to USD)
        postLiquidation.debtPaidUSD =
            EulerRouter(twyneVaultManager.oracleRouter()).getQuote(debt, eulerUSDC, preLiquidation.uoa);

        // Calculate net collateral (C - debt paid)
        postLiquidation.netCollateralUSD = postLiquidation.vaultCollateralUSD > postLiquidation.debtPaidUSD
            ? postLiquidation.vaultCollateralUSD - postLiquidation.debtPaidUSD
            : 0;

        // Get CLP after liquidation - use eWETH price directly (matching contract's approach)
        postLiquidation.clpShares = alice_collateral_vault.maxRelease();
        postLiquidation.clpUSD = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(
            postLiquidation.clpShares, assetAddr, preLiquidation.uoa
        );

        // Calculate liquidator collateral = C - CLP - Borrower Collateral
        // Note: C is user collateral (excluding CLP), so liquidator gets: C - Borrower Collateral
        // (CLP is already excluded from C)
        postLiquidation.liquidatorCollateralUSD = postLiquidation.vaultCollateralUSD
            > postLiquidation.borrowerCollateralReceivedUSD
            ? postLiquidation.vaultCollateralUSD - postLiquidation.borrowerCollateralReceivedUSD
            : 0;

        console2.log("=== VAULT COLLATERAL & DEBT (Post-liquidation) ===");
        console2.log("Vault Collateral C (USD):", postLiquidation.vaultCollateralUSD);
        console2.log("CLP Reserved (USD):", postLiquidation.clpUSD);
        console2.log("Borrower Collateral (USD):", postLiquidation.borrowerCollateralReceivedUSD);
        console2.log("Liquidator Collateral (C - CLP - Borrower, USD):", postLiquidation.liquidatorCollateralUSD);
        console2.log("Debt Paid (USD):", postLiquidation.debtPaidUSD);
        console2.log("Net Collateral (C - debt paid, USD):", postLiquidation.netCollateralUSD);
    }

    /// @notice Helper function to trace interpolation math and check sensitivity
    function _traceInterpolationMath(uint256 B, uint256 C) internal view {
        uint256 liqLTV_e = uint256(twyneVaultManager.externalLiqBuffers(alice_collateral_vault.asset()))
            * uint256(IEVault(eulerUSDC).LTVLiquidation(alice_collateral_vault.asset())); // 1e8 precision
        uint256 maxLTV_t = uint256(twyneVaultManager.maxTwyneLTVs(alice_collateral_vault.asset())); // 1e4 precision

        uint256 currentLTV_bps = (B * MAXFACTOR) / C;

        // Check which branch we're in
        bool isFullyLiquidated = MAXFACTOR * B >= maxLTV_t * C;
        bool isSafeCase = MAXFACTOR * MAXFACTOR * B <= liqLTV_e * C;
        bool isInterpolationCase = !isFullyLiquidated && !isSafeCase;

        console2.log("=== INTERPOLATION MATH TRACE ===");
        console2.log("B (debt, USD):", B);
        console2.log("C (collateral, USD):", C);
        console2.log("Current LTV (bps):", currentLTV_bps);
        console2.log("liqLTV_e (1e8):", liqLTV_e);
        console2.log("maxLTV_t (1e4):", maxLTV_t);
        console2.log("isInterpolationCase:", isInterpolationCase ? 1 : 0);

        if (isInterpolationCase) {
            // Group interpolation calculations into struct to reduce stack depth
            InterpolationTraceData memory trace;

            // Calculate penalty step by step
            trace.numerator = (MAXFACTOR - maxLTV_t) * (MAXFACTOR * MAXFACTOR * B - (liqLTV_e * C));
            trace.denominator = MAXFACTOR * (MAXFACTOR * maxLTV_t - liqLTV_e);
            trace.penalty = trace.numerator / trace.denominator;
            trace.baseResult = C > B ? C - B : 0;
            trace.resultBeforeConversion = trace.baseResult > trace.penalty ? trace.baseResult - trace.penalty : 0;

            console2.log("Interpolation numerator:", trace.numerator);
            console2.log("Interpolation denominator:", trace.denominator);
            console2.log("Penalty (USD):", trace.penalty);
            console2.log("Base result (C - B, USD):", trace.baseResult);
            console2.log("Result before conversion (USD):", trace.resultBeforeConversion);

            // === TRACE _convertBaseToCollateral ===
            address uoa = IEVault(alice_collateral_vault.intermediateVault()).unitOfAccount();
            address assetAddr = alice_collateral_vault.asset();
            address underlyingAsset = IEVault(assetAddr).asset(); // Get underlying WETH, not eWETH vault

            // Step 1: Convert USD to underlying WETH via oracle (same as _convertBaseToCollateral)
            trace.collateralAmount_WETH = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(
                trace.resultBeforeConversion,
                uoa,
                underlyingAsset // Use underlying WETH, not eWETH vault
            );

            // Step 2: Convert WETH to eWETH shares
            trace.collateralAmount_shares = IEVault(assetAddr).convertToShares(trace.collateralAmount_WETH);

            // Step 3: Get available user collateral
            trace.availableUserCollateral =
                alice_collateral_vault.totalAssetsDepositedOrReserved() - alice_collateral_vault.maxRelease();

            // Step 4: Math.min
            trace.finalResult = Math.min(trace.availableUserCollateral, trace.collateralAmount_shares);

            console2.log("=== CONVERSION TRACE ===");
            console2.log("Input (USD):", trace.resultBeforeConversion);
            console2.log("After oracle (WETH underlying):", trace.collateralAmount_WETH);
            console2.log("After convertToShares (eWETH shares):", trace.collateralAmount_shares);
            console2.log("Available user collateral (shares):", trace.availableUserCollateral);
            console2.log("Final result (Math.min, shares):", trace.finalResult);

            // Compare with Python's exact values - group into struct to reduce stack depth
            PythonComparisonData memory python;
            python.pythonB = 9350 * 1e18;
            python.pythonC = 10000 * 1e18;
            python.pythonLTV_bps = (python.pythonB * MAXFACTOR) / python.pythonC;

            python.pythonNumerator =
                (MAXFACTOR - maxLTV_t) * (MAXFACTOR * MAXFACTOR * python.pythonB - (liqLTV_e * python.pythonC));
            python.pythonDenominator = MAXFACTOR * (MAXFACTOR * maxLTV_t - liqLTV_e);
            python.pythonPenalty = python.pythonNumerator / python.pythonDenominator;
            python.pythonBaseResult = python.pythonC - python.pythonB;
            python.pythonResultBeforeConversion = python.pythonBaseResult - python.pythonPenalty;

            // Trace Python's conversion
            python.pythonCollateralAmount_WETH = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(
                python.pythonResultBeforeConversion,
                uoa,
                underlyingAsset // Use underlying WETH
            );
            python.pythonCollateralAmount_shares =
                IEVault(assetAddr).convertToShares(python.pythonCollateralAmount_WETH);
            python.pythonFinalResult = Math.min(trace.availableUserCollateral, python.pythonCollateralAmount_shares);

            console2.log("=== PYTHON VALUES (for comparison) ===");
            console2.log("Python B (USD):", python.pythonB);
            console2.log("Python C (USD):", python.pythonC);
            console2.log("Python LTV (bps):", python.pythonLTV_bps);
            console2.log("Python Penalty (USD):", python.pythonPenalty);
            console2.log("Python Base result (USD):", python.pythonBaseResult);
            console2.log("Python Result before conversion (USD):", python.pythonResultBeforeConversion);
            console2.log("Python After oracle (WETH underlying):", python.pythonCollateralAmount_WETH);
            console2.log("Python After convertToShares (shares):", python.pythonCollateralAmount_shares);
            console2.log("Python Final result (shares):", python.pythonFinalResult);

            console2.log("=== DIFFERENCE ANALYSIS ===");
            console2.log(
                "LTV difference (bps):",
                currentLTV_bps > python.pythonLTV_bps
                    ? currentLTV_bps - python.pythonLTV_bps
                    : python.pythonLTV_bps - currentLTV_bps
            );
            console2.log(
                "Penalty difference (USD):",
                trace.penalty > python.pythonPenalty
                    ? trace.penalty - python.pythonPenalty
                    : python.pythonPenalty - trace.penalty
            );
            console2.log(
                "Result before conversion diff (USD):",
                trace.resultBeforeConversion > python.pythonResultBeforeConversion
                    ? trace.resultBeforeConversion - python.pythonResultBeforeConversion
                    : python.pythonResultBeforeConversion - trace.resultBeforeConversion
            );
            console2.log(
                "Oracle conversion diff (WETH):",
                trace.collateralAmount_WETH > python.pythonCollateralAmount_WETH
                    ? trace.collateralAmount_WETH - python.pythonCollateralAmount_WETH
                    : python.pythonCollateralAmount_WETH - trace.collateralAmount_WETH
            );
            console2.log(
                "Final result diff (shares):",
                trace.finalResult > python.pythonFinalResult
                    ? trace.finalResult - python.pythonFinalResult
                    : python.pythonFinalResult - trace.finalResult
            );
        }

        // Get actual result from contract
        uint256 actualResult = alice_collateral_vault.collateralForBorrower(B, C);
        console2.log("Actual collateralForBorrower result:", actualResult);
    }
    /////////////////////////////////////////////////////////////////
    ///////////////// /////Fuzzing Tests /////////////////////////////
    /////////////////////////////////////////////////////////////////


    /// @notice Fuzz test for collateralForBorrower function
    /// @dev Tests the core liquidation math with various B and C values
    function testFuzz_collateralForBorrower(
        uint256 B, // debt (fuzzed)
        uint256 C // collateral (fuzzed)
    ) public {
        createInitialPosition(5e18, 0, 16_000e6, 9000);

        // Bound inputs to reasonable ranges that won't cause oracle issues
        // Both B and C are in USD/unit of account (same units as _getBC() returns)
        B = bound(B, 1e6, 1e15); // 1 USD to 1 billion USD
        C = bound(C, 1e6, 1e15); // 1 USD to 1 billion USD (same units as B)

        // Ensure C >= B (collateral >= debt, otherwise position is insolvent)
        if (C < B) {
            C = B + bound(C, 1, 1e8); // Ensure C >= B with some margin
        }

        // Skip if values would cause overflow in calculations
        vm.assume(MAXFACTOR * B <= 1e30);
        vm.assume(C <= 1e30);

        uint256 result = alice_collateral_vault.collateralForBorrower(B, C);

        // Invariants to check (mathematical properties only, no oracle conversions):
        // 1. Result should be >= 0 (already guaranteed by uint256)
        assertGe(result, 0, "Result negative");

        // 2. If fully liquidated (LTV >= maxLTV_t), result should be 0
        uint256 maxLTV_t = uint256(twyneVaultManager.maxTwyneLTVs(alice_collateral_vault.asset()));
        if (MAXFACTOR * B >= maxLTV_t * C) {
            assertEq(result, 0, "Fully liquidated position should return 0");
        }

        // 3. Result should be monotonically increasing with C (more collateral = more result)
        // Test by comparing with C + 1
        if (C < type(uint256).max) {
            uint256 resultCPlus1 = alice_collateral_vault.collateralForBorrower(B, C + 1);
            assertGe(resultCPlus1, result, "Result should increase with collateral");
        }

        // 4. Result should be monotonically decreasing with B (more debt = less result)
        // Test by comparing with B + 1
        if (B < type(uint256).max && MAXFACTOR * (B + 1) < maxLTV_t * C) {
            uint256 resultBPlus1 = alice_collateral_vault.collateralForBorrower(B + 1, C);
            assertLe(resultBPlus1, result, "Result should decrease with debt");
        }
    }

    function testFuzz_liquidation_holistics(
        uint256 collateralAmount, // in eWETH tokens (18 decimals)
        uint256 debtAmount, // in USDC (6 decimals)
        uint256 priceDropBps,
        uint256 twyneLTV
    ) public noGasMetering {
        // 1. Bound collateral to work with fixed 8 ether in intermediate vault
        collateralAmount = bound(collateralAmount, 1e18, 7e18); // 1 to 7 ETH

        // 2. Fixed valid twyneLTV
        twyneLTV = uint16(bound(twyneLTV, 8500, 9300));

        // 2. Calculate max debt based on collateral amount
        // Conservative estimate: 1 WETH ≈ $3000, max LTV = 90%
        // Max debt = collateral * price * LTV
        // C (18 decimals) * 3000e6 (USDC, 6 decimals) * 9000 / 10000 / 1e18
        uint256 maxDebtForCollateral = (collateralAmount * 3500e6 * twyneLTV) / (1e18 * 10000);
        // Ensure minimum debt of 1 USDC and cap at reasonable maximum
        uint256 minDebt = 1e6;
        uint256 maxDebt = maxDebtForCollateral < 10_000e6 ? maxDebtForCollateral : 10_000e6;

        // 3. Bound debt based on collateral
        debtAmount = bound(debtAmount, minDebt, maxDebt);
        priceDropBps = bound(priceDropBps, 0, 50); // 0% to 50% drop

        // 3. Create position (this already sets up bob with 8 ether in intermediate vault)
        createInitialPosition(collateralAmount, 0, debtAmount, twyneLTV);

        // 4. Execute price drop
        executePriceDrop(priceDropBps);

        // 5. Skip if not liquidatable
        vm.assume(alice_collateral_vault.canLiquidate());

        // 6. Setup liquidator with enough tokens
        (uint256 B, uint256 C) = _getBC();
        uint256 neededCollateral = alice_collateral_vault.collateralForBorrower(B, C);
        uint256 debt = IEVault(eulerUSDC).debtOf(address(alice_collateral_vault));

        deal(address(USDC), liquidator, debt + 1_000_000);
        dealEToken(eulerWETH, liquidator, neededCollateral + 10 ether);

        vm.startPrank(liquidator);
        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint256).max);
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint256).max);
        vm.stopPrank();

        // 7. Execute liquidation
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    /////////////////////////////////////////////////////////////////
    ///////////////// /////Revert Tests /////////////////////////////
    /////////////////////////////////////////////////////////////////

    /// @notice Test that borrower cannot liquidate their own position
    function test_e_expectRevert_selfLiquidation() external noGasMetering {
        createInitialPosition(5e18, 0, 16_000e6, 8500);

        // Makes position liquidatable
        executePriceDrop(10);

        setup_approve_customSetup();

        // Borrower tries to liquidate their own position
        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.SelfLiquidation.selector);
        alice_collateral_vault.liquidate();
        vm.stopPrank();
    }

    /// @notice Test that liquidate() reverts when vault is externally liquidated
    function test_e_expectRevert_externallyLiquidated() external noGasMetering {
        createInitialPosition(5e18, 0, 16_000e6, 8500);

        // Makes position liquidatable with 30% price drop
        executePriceDrop(30);

        // Warp time to allow liquidation
        vm.warp(block.timestamp + 1);

        setup_approve_customSetup();

        // Verify initial state - vault is not externally liquidated
        assertFalse(
            alice_collateral_vault.isExternallyLiquidated(), "Vault should not be externally liquidated initially"
        );
        assertGt(IERC20(eulerWETH).balanceOf(address(alice_collateral_vault)), 0, "Vault should have collateral");

        // Perform external liquidation via Euler
        vm.startPrank(liquidator);

        // Enable liquidator to perform external liquidation
        IEVC(IEVault(eulerWETH).EVC()).enableCollateral(liquidator, address(eulerWETH));
        IEVC(IEVault(eulerUSDC).EVC()).enableController(liquidator, address(eulerUSDC));

        // Liquidate alice_collateral_vault via eulerUSDC EVault
        assertGt(alice_collateral_vault.maxRepay(), 0, "Vault should have debt to liquidate");

        // This decreases the debt but leaves some collateral, making it externally liquidated
        IEVault(eulerUSDC).liquidate({
            violator: address(alice_collateral_vault),
            collateral: eulerWETH,
            repayAssets: type(uint256).max,
            minYieldBalance: 0
        });
        vm.stopPrank();

        // Verify vault is now externally liquidated
        assertTrue(alice_collateral_vault.isExternallyLiquidated(), "Vault should be externally liquidated");

        // Liquidator tries to liquidate externally liquidated vault - should revert
        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.ExternallyLiquidated.selector);
        alice_collateral_vault.liquidate();
        vm.stopPrank();
    }

    /// @notice Test that liquidate() reverts when vault is healthy (not liquidatable)
    function test_e_expectRevert_healthyNotLiquidatable() external noGasMetering {
        createInitialPosition(5e18, 0, 16_000e6, 9000);

        vm.warp(block.timestamp + 1);

        // Small price drop that keeps position healthy (LTV <= β_safe * λ̃_e)
        executePriceDrop(5);

        setup_approve_customSetup();

        // Verify vault is not liquidatable
        assertFalse(alice_collateral_vault.canLiquidate(), "Vault should not be liquidatable");

        // Liquidator tries to liquidate healthy vault - should revert
        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.HealthyNotLiquidatable.selector);
        alice_collateral_vault.liquidate();
        vm.stopPrank();
    }

    /////////////////////////////////////////////////////////////////
    ///////////////// /////Helper Functions //////////////////////////
    /////////////////////////////////////////////////////////////////

    function _assertInterpolating() internal view {
        // --- Identical to `_canLiquidate()` externals ---------------------------------
        // Cache the same pair returned inside `_canLiquidate()`:
        // (collateral value scaled by Euler’s liquidation LTV, external debt value in unit of account)
        (uint256 extCollateralScaledByLiqLTV, uint256 externalBorrowDebtValue) =
            IEVault(eulerUSDC).accountLiquidity(address(alice_collateral_vault), true);

        // Mirror Twyne’s “user collateral” computation: total assets - reserved (maxRelease)
        uint256 userCollateral =
            alice_collateral_vault.totalAssetsDepositedOrReserved() - alice_collateral_vault.maxRelease();
        require(userCollateral > 0, "no collateral");

        // Convert that collateral to the same unit of account via the oracle, exactly like `_canLiquidate()`
        address uoa = IEVault(alice_collateral_vault.intermediateVault()).unitOfAccount();
        uint256 userCollateralValue =
            EulerRouter(twyneVaultManager.oracleRouter()).getQuote(userCollateral, alice_collateral_vault.asset(), uoa);
        require(userCollateralValue > 0, "zero collateral value");

        // This reproduces the LTV calculation implicit in `_canLiquidate()`’s second inequality
        // (externalBorrowDebtValue * MAXFACTOR > twyneLiqLTV * userCollateralValue)
        uint256 currentLTV = externalBorrowDebtValue * MAXFACTOR / userCollateralValue;

        // --- Additional guardrails just for the test ---------------------------------
        // These compute the thresholds so we can assert the state is in the interpolation band.

        // β_safe * λ̃_e (same values `_canLiquidate()` uses, but here we convert to bps for direct comparison)
        uint256 safeThresholdRaw = uint256(twyneVaultManager.externalLiqBuffers(alice_collateral_vault.asset()))
            * IEVault(eulerUSDC).LTVLiquidation(alice_collateral_vault.asset());
        uint256 safeThresholdBps = safeThresholdRaw / MAXFACTOR;

        // Twyne’s max liquidation LTV; same value the contract enforces when setting the vault’s LTV
        uint256 maxTwyneLTV = uint256(twyneVaultManager.maxTwyneLTVs(alice_collateral_vault.asset()));

        // --- Final assertion ----------------------------------------------------------
        // Ensure we’re strictly inside the interpolation window:
        // β_safe*λ̃_e < λ_t < λ̃_t^max
        if (!(safeThresholdBps < currentLTV && currentLTV < maxTwyneLTV)) {
            // Debug output to inspect mismatches if the assertion ever fails
            console2.log("extCollateralScaledByLiqLTV", extCollateralScaledByLiqLTV);
            console2.log("externalBorrowDebtValue", externalBorrowDebtValue);
            console2.log("userCollateralValue", userCollateralValue);
            console2.log("safeThresholdBps", safeThresholdBps);
            console2.log("currentLTV", currentLTV);
            console2.log("maxTwyneLTV", maxTwyneLTV);
            revert("not in interpolation band");
        }
    }

    /// @notice Helper to get B and C values (debt and collateral)
    /// @dev This matches the contract's _getBC() implementation which returns values in USD/unit of account
    function _getBC() internal view returns (uint256 B, uint256 C) {
        (, uint256 externalBorrowDebtValue) = IEVault(eulerUSDC).accountLiquidity(address(alice_collateral_vault), true);
        B = externalBorrowDebtValue;

        uint256 userCollateral =
            alice_collateral_vault.totalAssetsDepositedOrReserved() - alice_collateral_vault.maxRelease();
        address uoa = IEVault(alice_collateral_vault.intermediateVault()).unitOfAccount();
        C = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(userCollateral, alice_collateral_vault.asset(), uoa);
    }

    /// @notice Snapshots all relevant state before liquidation and repay
    function _snapshotBeforeLiquidation() internal view returns (LiquidationSnapshot memory snapshot) {
        snapshot.borrowerEWETH = IERC20(eulerWETH).balanceOf(alice);
        snapshot.liquidatorEWETH = IERC20(eulerWETH).balanceOf(liquidator);
        snapshot.vaultDebt = IEVault(eulerUSDC).debtOf(address(alice_collateral_vault));
        snapshot.borrower = alice_collateral_vault.borrower();
        snapshot.maxRepay = alice_collateral_vault.maxRepay();
        snapshot.totalAssets = alice_collateral_vault.totalAssetsDepositedOrReserved();
        snapshot.maxRelease = alice_collateral_vault.maxRelease();
        snapshot.vaultEWETH = IERC20(eulerWETH).balanceOf(address(alice_collateral_vault));
        snapshot.vaultUSDC = IERC20(eulerUSDC).balanceOf(address(alice_collateral_vault));

        // Calculate expected collateralForBorrower
        (uint256 B, uint256 C) = _getBC();

        // Calculate interpolation parameters to prove interpolation is working
        uint256 liqLTV_e = uint256(twyneVaultManager.externalLiqBuffers(alice_collateral_vault.asset()))
            * uint256(IEVault(eulerUSDC).LTVLiquidation(alice_collateral_vault.asset())); // 1e8 precision
        uint256 maxLTV_t = uint256(twyneVaultManager.maxTwyneLTVs(alice_collateral_vault.asset())); // 1e4 precision

        // Current LTV in same units as liqLTV_e (1e8 precision)
        // The condition in collateralForBorrower is: MAXFACTOR * MAXFACTOR * B <= liqLTV_e * C
        // Which means: (MAXFACTOR * MAXFACTOR * B) / C <= liqLTV_e
        // So the LTV in 1e8 precision is: (MAXFACTOR * MAXFACTOR * B) / C = (1e8 * B) / C
        uint256 currentLTV_1e8 = (MAXFACTOR * MAXFACTOR * B) / C; // LTV in 1e8 precision
        uint256 maxLTV_t_1e8 = maxLTV_t * MAXFACTOR; // Convert maxLTV_t from 1e4 to 1e8

        // Determine which branch
        bool isFullyLiquidated = MAXFACTOR * B >= maxLTV_t * C;
        bool isSafeCase = MAXFACTOR * MAXFACTOR * B <= liqLTV_e * C;
        bool isInterpolationCase = !isFullyLiquidated && !isSafeCase;

        // Calculate interpolation components if in interpolation case
        uint256 interpolationPenalty = 0;
        if (isInterpolationCase) {
            uint256 numerator = (MAXFACTOR - maxLTV_t) * (MAXFACTOR * MAXFACTOR * B - (liqLTV_e * C));
            uint256 denominator = MAXFACTOR * (MAXFACTOR * maxLTV_t - liqLTV_e);
            interpolationPenalty = numerator / denominator;
        }

        console2.log("=== SNAPSHOT DEBUG ===");
        console2.log("B (debt) at snapshot", B);
        console2.log("C (collateral) at snapshot", C);
        console2.log("alice eWETH balance at snapshot", snapshot.borrowerEWETH);
        console2.log("liquidator eWETH balance at snapshot", snapshot.liquidatorEWETH);
        console2.log("=== INTERPOLATION PROOF ===");
        console2.log("liqLTV_e (lower threshold, 1e8)", liqLTV_e);
        console2.log("maxLTV_t (upper threshold, 1e4)", maxLTV_t);
        console2.log("maxLTV_t_1e8 (upper threshold, 1e8)", maxLTV_t_1e8);
        console2.log("currentLTV_1e8 (actual LTV, 1e8)", currentLTV_1e8);
        console2.log("isFullyLiquidated", isFullyLiquidated ? 1 : 0);
        console2.log("isSafeCase", isSafeCase ? 1 : 0);
        console2.log("isInterpolationCase", isInterpolationCase ? 1 : 0);
        if (isInterpolationCase) {
            console2.log("interpolationPenalty (USD)", interpolationPenalty);
            console2.log("C - B (base before penalty, USD)", C > B ? C - B : 0);
        }

        snapshot.expectedCollateralForBorrower = alice_collateral_vault.collateralForBorrower(B, C);
        console2.log("expectedCollateralForBorrower", snapshot.expectedCollateralForBorrower);
    }

    /// @notice Verifies all state changes after liquidation and repay batch
    function _assertAfterLiquidationAndRepay(LiquidationSnapshot memory before) internal view {
        // 1. Credit movement checks - measure ACTUAL transfer
        uint256 borrowerEWETHAfter = IERC20(eulerWETH).balanceOf(alice);
        uint256 liquidatorEWETHAfter = IERC20(eulerWETH).balanceOf(liquidator);

        // DEBUG: Log all values to understand the discrepancy
        console2.log("=== LIQUIDATION ASSERT DEBUG ===");
        console2.log("before.borrowerEWETH", before.borrowerEWETH);
        console2.log("borrowerEWETHAfter", borrowerEWETHAfter);
        console2.log("before.liquidatorEWETH", before.liquidatorEWETH);
        console2.log("liquidatorEWETHAfter", liquidatorEWETHAfter);
        console2.log("before.expectedCollateralForBorrower", before.expectedCollateralForBorrower);

        // Calculate what actually happened
        uint256 actualCollateralTransferred = borrowerEWETHAfter - before.borrowerEWETH;
        uint256 actualLiquidatorPaid = before.liquidatorEWETH - liquidatorEWETHAfter;

        console2.log("actualCollateralTransferred", actualCollateralTransferred);
        console2.log("actualLiquidatorPaid", actualLiquidatorPaid);

        // Verify liquidator paid exactly what borrower received
        assertEq(
            actualLiquidatorPaid, actualCollateralTransferred, "liquidator decrease should equal borrower increase"
        );

        // 2. Verify the actual transfer matches what collateralForBorrower would return
        // Use the SNAPSHOT B/C values (before liquidation), not current state
        // The actual transfer should match what we calculated at snapshot time
        assertEq(
            actualCollateralTransferred,
            before.expectedCollateralForBorrower,
            "actual transfer should match snapshot collateralForBorrower calculation"
        );

        // 3. Vault state checks
        assertEq(alice_collateral_vault.borrower(), liquidator, "vault borrower should be liquidator");

        // 3. Debt check - should be reduced by maxRepay
        uint256 vaultDebtAfter = IEVault(eulerUSDC).debtOf(address(alice_collateral_vault));
        assertEq(vaultDebtAfter, before.vaultDebt - before.maxRepay, "debt should be reduced by maxRepay");

        // 4. Health check - vault should no longer be liquidatable
        assertFalse(alice_collateral_vault.canLiquidate(), "vault should not be liquidatable after repay");

        // 5. LTV check - should be below safe threshold
        uint256 userCollateral =
            alice_collateral_vault.totalAssetsDepositedOrReserved() - alice_collateral_vault.maxRelease();

        uint256 currentLTV = 0;
        if (userCollateral > 0) {
            address uoa = IEVault(alice_collateral_vault.intermediateVault()).unitOfAccount();
            uint256 userCollateralValue = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(
                userCollateral, alice_collateral_vault.asset(), uoa
            );
            (, uint256 externalBorrowDebtValue) =
                IEVault(eulerUSDC).accountLiquidity(address(alice_collateral_vault), true);

            if (userCollateralValue > 0) {
                currentLTV = externalBorrowDebtValue * MAXFACTOR / userCollateralValue;
            }
        }

        uint256 safeThresholdBps = uint256(twyneVaultManager.externalLiqBuffers(alice_collateral_vault.asset()))
            * IEVault(eulerUSDC).LTVLiquidation(alice_collateral_vault.asset()) / MAXFACTOR;

        assertLe(currentLTV, safeThresholdBps, "LTV should be below safe threshold after repay");
    }
}
