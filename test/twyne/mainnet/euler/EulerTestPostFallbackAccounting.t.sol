// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import "euler-vault-kit/EVault/shared/types/Types.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {EulerCollateralVault} from "src/twyne/EulerCollateralVault.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";
import {VaultType} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {EulerTestBase} from "./EulerTestBase.t.sol";
import {console2} from "forge-std/console2.sol";

import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {LiquidationMath} from "./LiquidationMath.sol";

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

struct PostFallbackAccountingData {
    uint256 pre_C;
    uint256 pre_CLP;
    uint256 C_left;
    uint256 C_left_USD;
    uint256 B_left;
    uint256 max_liqLTV_t;
    uint256 C_temp_USD;
    uint256 C_temp;
    uint256 C_LP_new;
    uint256 C_new;
    uint256 C_diff;
    uint256 C_LP_diff;
    uint256 clp_loss_bps;
    uint256 excess_credit;
}

struct PostFallbackInputs {
    uint256 borrower_C;
    uint256 borrower_C_LP;
    uint256 B_ext;
    uint256 pre_C;
    uint256 pre_CLP;
    uint256 max_liqLTV_t;
}

struct PostFallbackCalculations {
    uint256 C_left;
    uint256 C_temp_calc;
    uint256 C_temp;
    uint256 C_LP_new;
    uint256 C_new;
}

struct PostFallbackDiffs {
    uint256 C_diff;
    bool C_LP_diff_negative;
    uint256 C_LP_diff_magnitude;
}

struct PostFallbackCLPLoss {
    uint256 clp_remaining_bps;
    uint256 clp_loss_bps;
}

struct PostFallbackExcessCredit {
    uint256 required_collateral;
    uint256 total_collateral;
    uint256 clp_invariant;
    uint256 excess_credit_calc;
    bool excess_credit_negative;
    uint256 excess_credit_magnitude;
}

/// @notice Test suite overview
///  - Case00–01: post-fallback accounting for safe cases (λ_t ≤ β_safe * λ̃_e)
///  - Case10–13: post-fallback accounting for interpolation range (β_safe * λ̃_e < λ_t < λ̃_t^max)
///      * Case10–13: varying price drops (13%, 15%, 17%, 19%) to test interpolation band
///  - Case20–22: post-fallback accounting for fully liquidated range (λ_t > λ̃_t^max)
///      * Case20–22: varying price drops (20%, 22%, 25%) to test full liquidation
///  - `test_e_mathlib_python_PostFallbackAccounting_Example`: validates Solidity post-fallback accounting
///      * against Python model with exact integer arithmetic comparison
///  - `test_e_mathlib_splitCollateralAfterExtLiq_case*`: compare splitCollateralAfterExtLiq math logic
///      * with Python model across all LTV ranges (case0x, case1x, case2x)
///  - Math edge cases: zero collateral, zero maxRelease, zero userCollateralInitial, etc.
///  - Fuzz suites: `testFuzz_handleExternalLiquidation_InterpolationWindow`, `testFuzz_handleExternalLiquidation_holistics`,
///      * `testFuzz_splitCollateralAfterExtLiq_*` (conservation, bounds, relationships, small values)
///  - Revert tests: NotExternallyLiquidated, ExternalPositionUnhealthy, NoLiquidationForZeroReserve
///  - Test execution flags:
///      * `withoutHealthCheck` (default: false): When false, skips tests with "withoutHealthCheck" in name.
///        These tests require the health check in handleExternalLiquidation() to be commented out.
///      * `withoutFuzz` (default: true): When true, skips all fuzz tests to speed up test execution.

contract EulerTestInternalLiquidation is EulerTestBase {
    uint256 BORROW_ETH_AMOUNT;

    function setUp() public override {
        super.setUp();

        // Configure USDC → WETH oracle pair for handleExternalLiquidation
        vm.startPrank(oracleRouter.governor());
        oracleRouter.govSetConfig(USDC, WETH, address(mockOracle));

        // Calculate USDC → WETH price: WETH_USD_PRICE_INITIAL / USDC_USD_PRICE_INITIAL
        // But need to account for decimals: USDC has 6 decimals, WETH has 18 decimals
        // So: (1e6 * WETH_USD_PRICE_INITIAL) / (1e18 * USDC_USD_PRICE_INITIAL) * 1e18
        // Simplified: (WETH_USD_PRICE_INITIAL * 1e6) / USDC_USD_PRICE_INITIAL
        uint256 usdcToWethPrice = (WETH_USD_PRICE_INITIAL * 1e6) / USDC_USD_PRICE_INITIAL;
        mockOracle.setPrice(USDC, WETH, usdcToWethPrice);
        vm.stopPrank();
    }

    /////////////////////////////////////////////////////////////////
    ////////////////Case 0: λ_t ≤ β_safe * λ̃_e //////////////////////
    /////////////////////////////////////////////////////////////////

    function test_e_handleExternalLiquidation_case00() external noGasMetering {
        // 1. Arrange: build initial vault state
        createInitialPosition(5e18, 0, 16_000e6, 9000);

        // 2. Price drop
        executePriceDrop(10);

        // 3. Give liquidator approvals / balances
        setup_approve_customSetup();

        // 5. Execute external liquidation and repay batch 
        // (we obtain desired LTV before calling handleExternalLiquidation)
        executeExternalLiquidationWithPartialRepay(10); 

        uint256 C_old = alice_collateral_vault.totalAssetsDepositedOrReserved() - alice_collateral_vault.maxRelease();
        uint256 C_LP_old = alice_collateral_vault.maxRelease();
        uint256 B_left = alice_collateral_vault.maxRepay();
        uint256 twyne_maxLTV = twyneVaultManager.maxTwyneLTVs(alice_collateral_vault.asset());

        console2.log("C_old", C_old);
        console2.log("C_LP_old", C_LP_old);
        console2.log("B_left", B_left);
        console2.log("twyne_maxLTV", twyne_maxLTV);

        // 4. Snapshot after price drop and external liquidation 
        // -> in this way we obtain the desired LTV before calling handleExternalLiquidation
        // LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation(); //8108 LTV

        // 5. Log post-fallback accounting (before executing)
        // _logPostFallbackAccounting();

        // 6. Execute post fallback accounting
        executeHandleExternalLiquidation(); 

        uint256 C_new = alice_collateral_vault.totalAssetsDepositedOrReserved() - alice_collateral_vault.maxRelease();
        uint256 C_LP_new = alice_collateral_vault.maxRelease();
        uint256 C_diff = C_old - C_new;
        uint256 C_LP_diff = C_LP_old - C_LP_new;
        console2.log("C_diff", C_diff);
        console2.log("C_LP_diff", C_LP_diff);

        // 7. Assert: vault fully unwinded, borrower reset
        assertEq(alice_collateral_vault.borrower(), address(0), "owner is not 0");
        assertEq(alice_collateral_vault.totalAssetsDepositedOrReserved(), 0, "totalAssetsDepositedOrReserved is not 0");
        // _assertAfterLiquidationAndRepay(snapshot);
    }

    //LTV at limit upper limit before interpolation
    function test_e_handleExternalLiquidation_case01() external noGasMetering {
        // 1. Arrange: build initial vault state
        createInitialPosition(5e18, 0, 16_000e6, 9000);

        // 2. Price drop
        executePriceDrop(10);

        // 3. Give liquidator approvals / balances
        setup_approve_customSetup();

        // 5. Execute external liquidation and repay batch 
        // (we obtain desired LTV before calling handleExternalLiquidation)
        executeExternalLiquidationWithPartialRepay(8); 

        // 4. Snapshot after price drop and external liquidation 
        // -> in this way we obtain the desired LTV before calling handleExternalLiquidation
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation(); //8288 LTV

        // 5. Log post-fallback accounting (before executing)
        _logPostFallbackAccounting();

        // 6. Execute post fallback accounting
        executeHandleExternalLiquidation();

        // 7. Assert: vault fully unwinded, borrower reset
        assertEq(alice_collateral_vault.borrower(), address(0), "owner is not 0");
        assertEq(alice_collateral_vault.totalAssetsDepositedOrReserved(), 0, "totalAssetsDepositedOrReserved is not 0");
        // _assertAfterLiquidationAndRepay(snapshot);
    }

    /// @notice Tests marked with `withoutHealthCheck` bypass the external position health check
    /// @dev These tests are used to validate post-fallback accounting logic for scenarios where the external
    /// @dev position would be considered unhealthy (e.g., case 10: interpolation range, case 20: fully liquidated).
    /// @dev
    /// @dev To run these tests, the health check in `EulerCollateralVault.handleExternalLiquidation()` must be
    /// @dev commented out. The code to comment out is in EulerCollateralVault.sol (lines 241-245):
    /// @dev ```
    /// @dev {
    /// @dev     (uint externalCollateralValueScaledByLiqLTV, uint externalBorrowDebtValue) = 
    /// @dev         IEVault(targetVault).accountLiquidity(address(this), true);
    /// @dev     require(externalCollateralValueScaledByLiqLTV >= externalBorrowDebtValue, ExternalPositionUnhealthy());
    /// @dev }
    /// @dev ```
    /// @dev
    /// @dev These tests generate real-world datasets from end-to-end liquidation flows that can be used to
    /// @dev validate the Python liquidation model against Solidity's exact integer arithmetic, even when
    /// @dev the external position health check would normally prevent execution.

    /// @notice Flag to enable/disable tests that require the health check to be commented out.
    /// @dev When set to false, all tests with "withoutHealthCheck" in their name will skip execution.
    /// This prevents test failures when running all tests if the health check require statement is enabled.
    bool withoutHealthCheck = false;

    //Case 1: β_safe * λ̃_e < λ_t < λ̃_t^max (Interpolation Range)
    function test_e_handleExternalLiquidation_withoutHealthCheck_case10() external noGasMetering {
        if (!withoutHealthCheck) return;
        // 1. Arrange: build initial vault state
        createInitialPosition(5e18, 0, 16_000e6, 8500);

        // 2. Price drop
        executePriceDrop(13);

        // 3. Give liquidator approvals / balances
        setup_approve_customSetup();

        // 5. Execute external liquidation and repay batch 
        // (we obtain desired LTV before calling handleExternalLiquidation)
        executeExternalLiquidationWithPartialRepay(8); 

        // 4. Snapshot after price drop and external liquidation 
        // -> in this way we obtain the desired LTV before calling handleExternalLiquidation
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation(); //8574 LTV

        // 5. Log post-fallback accounting (before executing)
        _logPostFallbackAccounting();

        // 6. Execute post fallback accounting
        executeHandleExternalLiquidation();

        // 7. Assert: vault fully unwinded, borrower reset
        assertEq(alice_collateral_vault.borrower(), address(0), "owner is not 0");
        assertEq(alice_collateral_vault.totalAssetsDepositedOrReserved(), 0, "totalAssetsDepositedOrReserved is not 0");
        // _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_e_handleExternalLiquidation_withoutHealthCheck_case11() external noGasMetering {
        if (!withoutHealthCheck) return;
        // 1. Arrange: build initial vault state
        createInitialPosition(5e18, 0, 16_000e6, 8500);

        // 2. Price drop
        executePriceDrop(15);

        // 3. Give liquidator approvals / balances
        setup_approve_customSetup();

        // 5. Execute external liquidation and repay batch 
        // (we obtain desired LTV before calling handleExternalLiquidation)
        executeExternalLiquidationWithPartialRepay(8); 

        // 4. Snapshot after price drop and external liquidation 
        // -> in this way we obtain the desired LTV before calling handleExternalLiquidation
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation(); //8776 LTV

        // 5. Log post-fallback accounting (before executing)
        _logPostFallbackAccounting();

        // 6. Execute post fallback accounting
        executeHandleExternalLiquidation();

        // 7. Assert: vault fully unwinded, borrower reset
        assertEq(alice_collateral_vault.borrower(), address(0), "owner is not 0");
        assertEq(alice_collateral_vault.totalAssetsDepositedOrReserved(), 0, "totalAssetsDepositedOrReserved is not 0");
        // _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_e_handleExternalLiquidation_withoutHealthCheck_case12() external noGasMetering { //TODO
        if (!withoutHealthCheck) return;
        // 1. Arrange: build initial vault state
        createInitialPosition(5e18, 0, 16_000e6, 8500);

        // 2. Price drop
        executePriceDrop(17);

        // 3. Give liquidator approvals / balances
        setup_approve_customSetup();

        // 5. Execute external liquidation and repay batch 
        // (we obtain desired LTV before calling handleExternalLiquidation)
        executeExternalLiquidationWithPartialRepay(8); 

        // 4. Snapshot after price drop and external liquidation 
        // -> in this way we obtain the desired LTV before calling handleExternalLiquidation
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation(); //8988 LTV

        // 5. Log post-fallback accounting (before executing)
        _logPostFallbackAccounting();

        // 6. Execute post fallback accounting
        executeHandleExternalLiquidation();

        //Used to compare with case 14
        // Log balances after handleExternalLiquidation
        address asset = alice_collateral_vault.asset();
        address borrowerAddress = snapshot.borrower; // Use snapshot.borrower before it gets reset
        address intermediateVaultAddress = address(alice_collateral_vault.intermediateVault());
        
        console2.log("=== Balances after handleExternalLiquidation ===");
        console2.log("Liquidator balance:", IERC20(asset).balanceOf(liquidator));
        console2.log("Borrower (alice) balance:", IERC20(asset).balanceOf(borrowerAddress));
        console2.log("Intermediate vault balance:", IERC20(asset).balanceOf(intermediateVaultAddress));
        console2.log("Collateral vault balance:", IERC20(asset).balanceOf(address(alice_collateral_vault)));

        // 7. Assert: vault fully unwinded, borrower reset
        assertEq(alice_collateral_vault.borrower(), address(0), "owner is not 0");
        assertEq(alice_collateral_vault.totalAssetsDepositedOrReserved(), 0, "totalAssetsDepositedOrReserved is not 0");
        // _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_e_handleExternalLiquidation_withoutHealthCheck_case13() external noGasMetering { //TODO
        if (!withoutHealthCheck) return;
        // 1. Arrange: build initial vault state
        createInitialPosition(5e18, 0, 16_000e6, 8500);

        // 2. Price drop
        executePriceDrop(19);

        // 3. Give liquidator approvals / balances
        setup_approve_customSetup();

        // 5. Execute external liquidation and repay batch 
        // (we obtain desired LTV before calling handleExternalLiquidation)
        executeExternalLiquidationWithPartialRepay(8); 

        // 4. Snapshot after price drop and external liquidation 
        // -> in this way we obtain the desired LTV before calling handleExternalLiquidation
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation(); //8988 LTV

        // 5. Log post-fallback accounting (before executing)
        _logPostFallbackAccounting();

        // 6. Execute post fallback accounting
        executeHandleExternalLiquidation();

        //Used to compare with case 15
        // Log balances after handleExternalLiquidation
        address asset = alice_collateral_vault.asset();
        address borrowerAddress = snapshot.borrower; // Use snapshot.borrower before it gets reset
        address intermediateVaultAddress = address(alice_collateral_vault.intermediateVault());
        
        console2.log("=== Balances after handleExternalLiquidation ===");
        console2.log("Liquidator balance:", IERC20(asset).balanceOf(liquidator));
        console2.log("Borrower (alice) balance:", IERC20(asset).balanceOf(borrowerAddress));
        console2.log("Intermediate vault balance:", IERC20(asset).balanceOf(intermediateVaultAddress));
        console2.log("Collateral vault balance:", IERC20(asset).balanceOf(address(alice_collateral_vault)));

        // 7. Assert: vault fully unwinded, borrower reset
        assertEq(alice_collateral_vault.borrower(), address(0), "owner is not 0");
        assertEq(alice_collateral_vault.totalAssetsDepositedOrReserved(), 0, "totalAssetsDepositedOrReserved is not 0");
        // _assertAfterLiquidationAndRepay(snapshot);
    }

    /////Case 3: λ_t > λ̃_t^max (Fully Liquidated Range)

    function test_e_handleExternalLiquidation_withoutHealthCheck_case20() external noGasMetering { //TODO
        if (!withoutHealthCheck) return;
        // 1. Arrange: build initial vault state
        createInitialPosition(5e18, 0, 16_000e6, 8500);

        // 2. Price drop
        executePriceDrop(20);

        // 3. Give liquidator approvals / balances
        setup_approve_customSetup();

        // 5. Execute external liquidation and repay batch 
        // (we obtain desired LTV before calling handleExternalLiquidation)
        executeExternalLiquidationWithPartialRepay(8); 

        // 4. Snapshot after price drop and external liquidation 
        // -> in this way we obtain the desired LTV before calling handleExternalLiquidation
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation(); //9325 LTV

        // 5. Log post-fallback accounting (before executing)
        _logPostFallbackAccounting();

        // 6. Execute post fallback accounting
        executeHandleExternalLiquidation();

        // 7. Assert: vault fully unwinded, borrower reset
        assertEq(alice_collateral_vault.borrower(), address(0), "owner is not 0");
        assertEq(alice_collateral_vault.totalAssetsDepositedOrReserved(), 0, "totalAssetsDepositedOrReserved is not 0");
        // _assertAfterLiquidationAndRepay(snapshot);

    }

    function test_e_handleExternalLiquidation_withoutHealthCheck_case21() external noGasMetering { //TODO
        if (!withoutHealthCheck) return;
        // 1. Arrange: build initial vault state
        createInitialPosition(5e18, 0, 16_000e6, 8500);

        // 2. Price drop
        executePriceDrop(22);

        // 3. Give liquidator approvals / balances
        setup_approve_customSetup();

        // 5. Execute external liquidation and repay batch 
        // (we obtain desired LTV before calling handleExternalLiquidation)
        executeExternalLiquidationWithPartialRepay(8); 

        // 4. Snapshot after price drop and external liquidation 
        // -> in this way we obtain the desired LTV before calling handleExternalLiquidation
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation(); //9564 LTV

        // 5. Log post-fallback accounting (before executing)
        _logPostFallbackAccounting();

        // 6. Execute post fallback accounting
        executeHandleExternalLiquidation();

        // 7. Assert: vault fully unwinded, borrower reset
        assertEq(alice_collateral_vault.borrower(), address(0), "owner is not 0");
        assertEq(alice_collateral_vault.totalAssetsDepositedOrReserved(), 0, "totalAssetsDepositedOrReserved is not 0");
        // _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_e_handleExternalLiquidation_withoutHealthCheck_case22() external noGasMetering { //TODO
        if (!withoutHealthCheck) return;
        // 1. Arrange: build initial vault state
        createInitialPosition(5e18, 0, 16_000e6, 8500);

        // 2. Price drop
        executePriceDrop(25);

        // 3. Give liquidator approvals / balances
        setup_approve_customSetup();

        // 5. Execute external liquidation and repay batch 
        // (we obtain desired LTV before calling handleExternalLiquidation)
        executeExternalLiquidationWithPartialRepay(8); 

        // 4. Snapshot after price drop and external liquidation 
        // -> in this way we obtain the desired LTV before calling handleExternalLiquidation
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation(); //9946 LTV

        // 5. Log post-fallback accounting (before executing)
        _logPostFallbackAccounting();

        // 6. Execute post fallback accounting
        executeHandleExternalLiquidation();

        // 7. Assert: vault fully unwinded, borrower reset
        assertEq(alice_collateral_vault.borrower(), address(0), "owner is not 0");
        assertEq(alice_collateral_vault.totalAssetsDepositedOrReserved(), 0, "totalAssetsDepositedOrReserved is not 0");
        // _assertAfterLiquidationAndRepay(snapshot);
    }

    /////////////////////////////////////////////////////////////////
    ////Tests to compare liquidation math logic with python model////
    /////////////////////////////////////////////////////////////////

    //The input in this tests are representing the datasets we use in solidity
    //and python to obtain results. Tests must show same results in solidity&python
    //using exactly the same dataset.
    //case0x is for λ_t ≤ β_safe * λ̃_e
    //case1x is for β_safe * λ̃_e < λ_t < λ̃_t^max (Interpolation Range)
    //case2x is for λ_t > λ̃_t^max (Fully Liquidated Range)

    /// @notice Validates Solidity post-fallback accounting against Python example results
    /// @dev Python example: C=85.0, C_LP=15.0, B_ext=70.0, pre_C=90.0, pre_CLP=17.0, max_liqLTV_t=0.93
    /// @dev Expected results: C_temp=75.268817, C_new=83.0, C_LP_new=17.0, C_diff=2.0, C_LP_diff=-2.0
    /// 
    /// @dev IMPORTANT: Numerical Precision Difference Between Python and Solidity
    /// @dev This test validates the same mathematical logic as the Python model, but there are small
    /// @dev numerical differences in the results due to different arithmetic implementations:
    /// @dev 
    /// @dev - Python uses floating-point arithmetic: C_temp = 70.0 / 0.93 ≈ 75.26881720430107
    /// @dev   When scaled to 1e18: 75268817204301070336 (floating point precision)
    /// @dev 
    /// @dev - Solidity uses integer division: C_temp = (70e18 * 10000) / 9300 = 75268817204301075268
    /// @dev   (exact integer division result)
    /// @dev 
    /// @dev The difference (4932, ~0.000000000000007%) comes from:
    /// @dev   1. Floating-point representation limitations in Python (IEEE 754 double precision)
    /// @dev   2. Integer division truncation in Solidity (no rounding, exact division)
    /// @dev   3. Different order of operations (Python: 70.0/0.93, Solidity: (70*10000)/9300)
    /// @dev 
    /// @dev This test uses Solidity's exact integer division results, which are the correct values
    /// @dev for the Solidity implementation. The small difference is expected and acceptable, as both
    /// @dev implementations are mathematically equivalent but use different numerical representations.
    /// @dev The Python model serves as a reference implementation, while this test validates the
    /// @dev actual on-chain behavior using integer arithmetic.
    function test_e_mathlib_python_PostFallbackAccounting_Example() external noGasMetering {
        // Python example values (in base units - we'll use 1e18 precision for WETH)
        // borrower.C = 85.0, borrower.C_LP = 15.0, B_ext = 70.0
        // pre_C = 90.0, pre_CLP = 17.0, max_liqLTV_t = 0.93 (9300 in 1e4 precision)
        
        // Convert Python values to Solidity units (assuming 1 unit = 1e18 wei for WETH)
        PostFallbackInputs memory inputs = PostFallbackInputs({
            borrower_C: 85e18,      // Current collateral after external liquidation
            borrower_C_LP: 15e18,   // Current CLP after external liquidation
            B_ext: 70e18,           // External debt (in USD/base units)
            pre_C: 90e18,           // C_old (before handleExternalLiquidation)
            pre_CLP: 17e18,         // C_LP_old (before handleExternalLiquidation)
            max_liqLTV_t: 9300      // max_liqLTV_t in 1e4 precision (0.93)
        });
        
        // Calculate C_left = C + C_LP (total remaining collateral)
        PostFallbackCalculations memory calc = PostFallbackCalculations({
            C_left: inputs.borrower_C + inputs.borrower_C_LP, // 100e18
            C_temp_calc: 0,
            C_temp: 0,
            C_LP_new: 0,
            C_new: 0
        });
        
        // Calculate C_temp = min(B_left / max_liqLTV_t, C_left)
        // B_left is in base units, max_liqLTV_t is in 1e4 precision
        // C_temp = min((70e18 * 1e4) / 9300, 100e18) = min(75.268817204301075268e18, 100e18) = 75.268817204301075268e18
        calc.C_temp_calc = (inputs.B_ext * MAXFACTOR) / inputs.max_liqLTV_t;
        calc.C_temp = Math.min(calc.C_temp_calc, calc.C_left);
        
        // Expected: C_temp from Python floating point calculation: 70.0 / 0.93 * 1e18 ≈ 75268817204301070336
        // Solidity integer division: (70e18 * 10000) / 9300 = 75268817204301075268
        // Small difference (4932) due to floating point vs integer arithmetic - both are valid
        // Using Solidity's exact integer division result (correct for Solidity)
        uint256 expected_C_temp = 75268817204301075268; // Exact Solidity integer division result
        assertEq(calc.C_temp, expected_C_temp, "C_temp should match Solidity integer division result");
        
        // Calculate C_LP_new = min(C_left - C_temp, C_LP_old)
        // C_LP_new = min(100e18 - 75268817204301075268, 17e18) = min(24731182795698924732, 17e18) = 17e18
        calc.C_LP_new = Math.min(
            calc.C_left > calc.C_temp ? calc.C_left - calc.C_temp : 0,
            inputs.pre_CLP
        );
        assertEq(calc.C_LP_new, inputs.pre_CLP, "C_LP_new should equal C_LP_old (17e18)");
        
        // Calculate C_new = max(C_temp, C_left - C_LP_old)
        // C_new = max(75268817204301075268, 100e18 - 17e18) = max(75268817204301075268, 83e18) = 83e18
        calc.C_new = Math.max(
            calc.C_temp,
            calc.C_left > inputs.pre_CLP ? calc.C_left - inputs.pre_CLP : 0
        );
        assertEq(calc.C_new, 83e18, "C_new should equal 83e18");
        
        // Calculate C_diff = borrower.C - C_new
        // C_diff = 85e18 - 83e18 = 2e18
        PostFallbackDiffs memory diffs = PostFallbackDiffs({
            C_diff: inputs.borrower_C > calc.C_new ? inputs.borrower_C - calc.C_new : 0,
            C_LP_diff_negative: false,
            C_LP_diff_magnitude: 0
        });
        assertEq(diffs.C_diff, 2e18, "C_diff should equal 2e18");
        
        // Calculate C_LP_diff = borrower.C_LP - C_LP_new
        // C_LP_diff = 15e18 - 17e18 = -2e18 (negative, but we handle as 0 in Solidity)
        // In Python this is -2.0, but Solidity can't represent negative, so we check the condition
        diffs.C_LP_diff_negative = inputs.borrower_C_LP < calc.C_LP_new;
        assertTrue(diffs.C_LP_diff_negative, "C_LP_diff should be negative (15 < 17)");
        diffs.C_LP_diff_magnitude = calc.C_LP_new > inputs.borrower_C_LP ? calc.C_LP_new - inputs.borrower_C_LP : 0;
        assertEq(diffs.C_LP_diff_magnitude, 2e18, "C_LP_diff magnitude should be 2e18");
        
        // Calculate CLP loss = max(0.0, 1 - (C_LP_new / C_LP_old))
        // CLP loss = max(0.0, 1 - (17e18 / 17e18)) = max(0.0, 0) = 0.0
        PostFallbackCLPLoss memory clpLoss = PostFallbackCLPLoss({
            clp_remaining_bps: (calc.C_LP_new * MAXFACTOR) / inputs.pre_CLP,
            clp_loss_bps: 0
        });
        clpLoss.clp_loss_bps = clpLoss.clp_remaining_bps < MAXFACTOR ? MAXFACTOR - clpLoss.clp_remaining_bps : 0;
        assertEq(clpLoss.clp_loss_bps, 0, "CLP loss should be 0%");
        
        // Calculate excess credit = C_LP_new - _clp_invariant(max_liqLTV_t, B_left)
        // _clp_invariant = max(0.0, total_collateral - required_collateral)
        // required_collateral = B_left / max_liqLTV_t = (70e18 * 10000) / 9300 = 75268817204301075268
        // total_collateral = C + C_LP = 85e18 + 15e18 = 100e18
        // _clp_invariant = max(0.0, 100e18 - 75268817204301075268) = 24731182795698924732
        // excess_credit = 17e18 - 24731182795698924732 = -7731182795698924732 (negative)
        PostFallbackExcessCredit memory excessCredit = PostFallbackExcessCredit({
            required_collateral: (inputs.B_ext * MAXFACTOR) / inputs.max_liqLTV_t,
            total_collateral: inputs.borrower_C + inputs.borrower_C_LP,
            clp_invariant: 0,
            excess_credit_calc: 0,
            excess_credit_negative: false,
            excess_credit_magnitude: 0
        });
        excessCredit.clp_invariant = excessCredit.total_collateral > excessCredit.required_collateral 
            ? excessCredit.total_collateral - excessCredit.required_collateral 
            : 0;
        excessCredit.excess_credit_calc = calc.C_LP_new > excessCredit.clp_invariant 
            ? calc.C_LP_new - excessCredit.clp_invariant 
            : 0; // Would be negative, but Solidity can't represent negative
        excessCredit.excess_credit_negative = calc.C_LP_new < excessCredit.clp_invariant;
        assertTrue(excessCredit.excess_credit_negative, "Excess credit should be negative");
        excessCredit.excess_credit_magnitude = excessCredit.clp_invariant > calc.C_LP_new 
            ? excessCredit.clp_invariant - calc.C_LP_new 
            : 0;
        // Expected: clp_invariant = 100e18 - 75268817204301075268 = 24731182795698924732
        // excess_credit_magnitude = 24731182795698924732 - 17e18 = 7731182795698924732
        // Python floating point gives: 7731182795698927616 (difference: 2884 due to floating point precision)
        // Using Solidity's exact integer division result (correct for Solidity)
        uint256 expected_excess_credit_magnitude = 7731182795698924732; // Exact Solidity integer division result
        assertEq(excessCredit.excess_credit_magnitude, expected_excess_credit_magnitude, 
            "Excess credit magnitude should match Solidity integer division result");
        
        // Log results for comparison
        console2.log("=== Post-Fallback Accounting Validation ===");
        console2.log("C_temp:", calc.C_temp);
        console2.log("C_old (pre_C):", inputs.pre_C);
        console2.log("C_LP_old (pre_CLP):", inputs.pre_CLP);
        console2.log("B_left:", inputs.B_ext);
        console2.log("C_diff:", diffs.C_diff);
        console2.log("C_LP_diff (negative):", diffs.C_LP_diff_negative ? 1 : 0);
        console2.log("C_LP_diff magnitude:", diffs.C_LP_diff_magnitude);
        console2.log("C_new:", calc.C_new);
        console2.log("C_LP_new:", calc.C_LP_new);
        console2.log("Excess credit (negative):", excessCredit.excess_credit_negative ? 1 : 0);
        console2.log("Excess credit magnitude:", excessCredit.excess_credit_magnitude);
        console2.log("CLP loss (bps):", clpLoss.clp_loss_bps);
    }

    /////////////////////////////////////////////////////////////////
    ////Tests to compare splitCollateralAfterExtLiq math logic with python model////
    /////////////////////////////////////////////////////////////////

    struct SplitCollateralAfterExtLiqInputUoA {
        uint256 collateralBalanceUoA;
        uint256 maxRepayUoA;
        uint256 maxReleaseUoA;
        uint256 B;
        uint256 externalLiqBuffer;
        uint256 extLiqLTV;
        uint256 maxLTV_tUoA;
    }

    function test_e_mathlib_splitCollateralAfterExtLiq_pythonExample() external noGasMetering {
        // Values from post-fallback accounting (in USD, multiply by 1e18 for wei)
        // Note: C_left should be the current state (borrower.C + borrower.C_LP), not C_old + C_LP_old
        uint256 B_leftUoA = 70e18;     // 70.0 USD
        uint256 C_LP_oldUoA = 17e18;   // 17.0 USD
        
        // To get C_new = 83 and C_LP_new = 17, we need C_left = 100
        // (C_left = C_new + C_LP_new = 83 + 17 = 100)
        uint256 C_leftUoA = 100e18;    // Total collateral (current state)

        (uint256 liquidatorRewardUoA, uint256 releaseAmountUoA, uint256 borrowerClaimUoA) =
            LiquidationMath.splitCollateralAfterExtLiqUoA(
                C_leftUoA,        // Total collateral = 100
                B_leftUoA,
                C_LP_oldUoA,      // How much should be released = 17
                10_000,
                8_500,
                9_300
            );
            
        console2.log("C_new (should be 83):", borrowerClaimUoA + liquidatorRewardUoA);
        console2.log("releaseAmountUoA(CLP_NEW):", releaseAmountUoA);
    }

    function test_e_mathlib_splitCollateralAfterExtLiq_boundsBased_case00() external noGasMetering {
        // Target LTV: 8000 bps
        // Using fixed C_left=100, C_LP_old=10 to match target LTV
        uint256 C_leftUoA = 100e18;
        uint256 C_LP_oldUoA = 10e18;
        // B_left = (8000 * 90) / 10000 = 72
        uint256 B_leftUoA = 72e18; // 72e18

        // Verify LTV calculation: LTV_bps = (MAXFACTOR * B) / C
        // where C = C_left - C_LP_old = 100 - 10 = 90
        uint256 userCollateralValueUoA = C_leftUoA - C_LP_oldUoA; // 90e18
        uint256 calculatedLTV_bps = (10000 * B_leftUoA) / userCollateralValueUoA;
        console2.log("=== Case 00 (Target: 8000 LTV) ===");
        console2.log("Calculated LTV (bps):", calculatedLTV_bps);
        require(calculatedLTV_bps == 8000, "LTV mismatch");

        (uint256 liquidatorRewardUoA, uint256 releaseAmountUoA, uint256 borrowerClaimUoA) =
            LiquidationMath.splitCollateralAfterExtLiqUoA(
                C_leftUoA,
                B_leftUoA,
                C_LP_oldUoA,
                10_000,
                8_500,
                9_300
            );

        uint256 C_new = borrowerClaimUoA + liquidatorRewardUoA;
        console2.log("C_new:", C_new);
        console2.log("C_LP_new:", releaseAmountUoA);
    }

    //LTV at limit upper limit before interpolation
    function test_e_mathlib_splitCollateralAfterExtLiq_boundsBased_case01() external noGasMetering {
        // Target LTV: 8288 bps
        // Using fixed C_left=100, C_LP_old=10 to match target LTV
        uint256 C_leftUoA = 100e18;
        uint256 C_LP_oldUoA = 10e18;
        // B_left = (8288 * 90) / 10000 = 74.592
        uint256 B_leftUoA = 74592000000000000000; // 74.592e18

        // Verify LTV calculation: LTV_bps = (MAXFACTOR * B) / C
        // where C = C_left - C_LP_old = 100 - 10 = 90
        uint256 userCollateralValueUoA = C_leftUoA - C_LP_oldUoA; // 90e18
        uint256 calculatedLTV_bps = (10000 * B_leftUoA) / userCollateralValueUoA;
        console2.log("=== Case 01 (Target: 8288 LTV) ===");
        console2.log("Calculated LTV (bps):", calculatedLTV_bps);
        require(calculatedLTV_bps == 8288, "LTV mismatch");

        (uint256 liquidatorRewardUoA, uint256 releaseAmountUoA, uint256 borrowerClaimUoA) =
            LiquidationMath.splitCollateralAfterExtLiqUoA(
                C_leftUoA,
                B_leftUoA,
                C_LP_oldUoA,
                10_000,
                8_500,
                9_300
            );

        uint256 C_new = borrowerClaimUoA + liquidatorRewardUoA;
        console2.log("C_new:", C_new);
        console2.log("C_LP_new:", releaseAmountUoA);
    }

    //Case 1: β_safe * λ̃_e < λ_t < λ̃_t^max (Interpolation Range)
    function test_e_mathlib_splitCollateralAfterExtLiq_boundsBased_case10() external noGasMetering {
        // Target LTV: 8574 bps
        uint256 C_leftUoA = 100e18;
        uint256 C_LP_oldUoA = 10e18;
        // B_left = (8574 * 90) / 10000 = 77.166
        uint256 B_leftUoA = 77166000000000000000; // 77.166e18

        // Verify LTV calculation: LTV_bps = (MAXFACTOR * B) / C
        // where C = C_left - C_LP_old = 100 - 10 = 90
        uint256 userCollateralValueUoA = C_leftUoA - C_LP_oldUoA; // 90e18
        uint256 calculatedLTV_bps = (10000 * B_leftUoA) / userCollateralValueUoA;
        console2.log("=== Case 10 (Target: 8574 LTV) ===");
        console2.log("Calculated LTV (bps):", calculatedLTV_bps);
        require(calculatedLTV_bps == 8574, "LTV mismatch");

        (uint256 liquidatorRewardUoA, uint256 releaseAmountUoA, uint256 borrowerClaimUoA) =
            LiquidationMath.splitCollateralAfterExtLiqUoA(
                C_leftUoA,
                B_leftUoA,
                C_LP_oldUoA,
                10_000,
                8_500,
                9_300
            );

        uint256 C_new = borrowerClaimUoA + liquidatorRewardUoA;
        console2.log("C_new:", C_new);
        console2.log("C_LP_new:", releaseAmountUoA);
    }

    function test_e_mathlib_splitCollateralAfterExtLiq_boundsBased_case11() external noGasMetering {
        // Target LTV: 8776 bps
        uint256 C_leftUoA = 100e18;
        uint256 C_LP_oldUoA = 10e18;
        // B_left = (8776 * 90) / 10000 = 78.984
        uint256 B_leftUoA = 78984000000000000000; // 78.984e18

        // Verify LTV calculation: LTV_bps = (MAXFACTOR * B) / C
        // where C = C_left - C_LP_old = 100 - 10 = 90
        uint256 userCollateralValueUoA = C_leftUoA - C_LP_oldUoA; // 90e18
        uint256 calculatedLTV_bps = (10000 * B_leftUoA) / userCollateralValueUoA;
        console2.log("=== Case 11 (Target: 8776 LTV) ===");
        console2.log("Calculated LTV (bps):", calculatedLTV_bps);
        require(calculatedLTV_bps == 8776, "LTV mismatch");

        (uint256 liquidatorRewardUoA, uint256 releaseAmountUoA, uint256 borrowerClaimUoA) =
            LiquidationMath.splitCollateralAfterExtLiqUoA(
                C_leftUoA,
                B_leftUoA,
                C_LP_oldUoA,
                10_000,
                8_500,
                9_300
            );

        uint256 C_new = borrowerClaimUoA + liquidatorRewardUoA;
        console2.log("C_new:", C_new);
        console2.log("C_LP_new:", releaseAmountUoA);
    }

    function test_e_mathlib_splitCollateralAfterExtLiq_boundsBased_case12() external noGasMetering {
        // Target LTV: 8988 bps
        uint256 C_leftUoA = 100e18;
        uint256 C_LP_oldUoA = 10e18;
        // B_left = (8988 * 90) / 10000 = 80.892
        uint256 B_leftUoA = 80892000000000000000; // 80.892e18

        // Verify LTV calculation: LTV_bps = (MAXFACTOR * B) / C
        // where C = C_left - C_LP_old = 100 - 10 = 90
        uint256 userCollateralValueUoA = C_leftUoA - C_LP_oldUoA; // 90e18
        uint256 calculatedLTV_bps = (10000 * B_leftUoA) / userCollateralValueUoA;
        console2.log("=== Case 12 (Target: 8988 LTV) ===");
        console2.log("Calculated LTV (bps):", calculatedLTV_bps);
        require(calculatedLTV_bps == 8988, "LTV mismatch");

        (uint256 liquidatorRewardUoA, uint256 releaseAmountUoA, uint256 borrowerClaimUoA) =
            LiquidationMath.splitCollateralAfterExtLiqUoA(
                C_leftUoA,
                B_leftUoA,
                C_LP_oldUoA,
                10_000,
                8_500,
                9_300
            );

        uint256 C_new = borrowerClaimUoA + liquidatorRewardUoA;
        console2.log("C_new:", C_new);
        console2.log("C_LP_new:", releaseAmountUoA);
    }

    function test_e_mathlib_splitCollateralAfterExtLiq_boundsBased_case13() external noGasMetering {
        // Target LTV: 9209 bps
        uint256 C_leftUoA = 100e18;
        uint256 C_LP_oldUoA = 10e18;
        // B_left = (9209 * 90) / 10000 = 82.881
        uint256 B_leftUoA = 82881000000000000000; // 82.881e18

        // Verify LTV calculation: LTV_bps = (MAXFACTOR * B) / C
        // where C = C_left - C_LP_old = 100 - 10 = 90
        uint256 userCollateralValueUoA = C_leftUoA - C_LP_oldUoA; // 90e18
        uint256 calculatedLTV_bps = (10000 * B_leftUoA) / userCollateralValueUoA;
        console2.log("=== Case 15 (Target: 9209 LTV) ===");
        console2.log("Calculated LTV (bps):", calculatedLTV_bps);
        require(calculatedLTV_bps == 9209, "LTV mismatch");

        (uint256 liquidatorRewardUoA, uint256 releaseAmountUoA, uint256 borrowerClaimUoA) =
            LiquidationMath.splitCollateralAfterExtLiqUoA(
                C_leftUoA,
                B_leftUoA,
                C_LP_oldUoA,
                10_000,
                8_500,
                9_300
            );

        uint256 C_new = borrowerClaimUoA + liquidatorRewardUoA;
        console2.log("C_new:", C_new);
        console2.log("C_LP_new:", releaseAmountUoA);
    }

    /////Case 3: λ_t > λ̃_t^max (Fully Liquidated Range)

    function test_e_mathlib_splitCollateralAfterExtLiq_boundsBased_case20() external noGasMetering {
        // Target LTV: 9325 bps
        uint256 C_leftUoA = 100e18;
        uint256 C_LP_oldUoA = 10e18;
        // B_left = (9325 * 90) / 10000 = 83.925
        uint256 B_leftUoA = 83925000000000000000; // 83.925e18

        // Verify LTV calculation: LTV_bps = (MAXFACTOR * B) / C
        // where C = C_left - C_LP_old = 100 - 10 = 90
        uint256 userCollateralValueUoA = C_leftUoA - C_LP_oldUoA; // 90e18
        uint256 calculatedLTV_bps = (10000 * B_leftUoA) / userCollateralValueUoA;
        console2.log("=== Case 20 (Target: 9325 LTV) ===");
        console2.log("Calculated LTV (bps):", calculatedLTV_bps);
        require(calculatedLTV_bps == 9325, "LTV mismatch");

        (uint256 liquidatorRewardUoA, uint256 releaseAmountUoA, uint256 borrowerClaimUoA) =
            LiquidationMath.splitCollateralAfterExtLiqUoA(
                C_leftUoA,
                B_leftUoA,
                C_LP_oldUoA,
                10_000,
                8_500,
                9_300
            );

        uint256 C_new = borrowerClaimUoA + liquidatorRewardUoA;
        console2.log("C_new:", C_new);
        console2.log("C_LP_new:", releaseAmountUoA);
    }

    function test_e_mathlib_splitCollateralAfterExtLiq_boundsBased_case21() external noGasMetering {
        // Target LTV: 9564 bps
        uint256 C_leftUoA = 100e18;
        uint256 C_LP_oldUoA = 10e18;
        // B_left = (9564 * 90) / 10000 = 86.076
        uint256 B_leftUoA = 86076000000000000000; // 86.076e18

        // Verify LTV calculation: LTV_bps = (MAXFACTOR * B) / C
        // where C = C_left - C_LP_old = 100 - 10 = 90
        uint256 userCollateralValueUoA = C_leftUoA - C_LP_oldUoA; // 90e18
        uint256 calculatedLTV_bps = (10000 * B_leftUoA) / userCollateralValueUoA;
        console2.log("=== Case 21 (Target: 9564 LTV) ===");
        console2.log("Calculated LTV (bps):", calculatedLTV_bps);
        require(calculatedLTV_bps == 9564, "LTV mismatch");

        (uint256 liquidatorRewardUoA, uint256 releaseAmountUoA, uint256 borrowerClaimUoA) =
            LiquidationMath.splitCollateralAfterExtLiqUoA(
                C_leftUoA,
                B_leftUoA,
                C_LP_oldUoA,
                10_000,
                8_500,
                9_300
            );

        uint256 C_new = borrowerClaimUoA + liquidatorRewardUoA;
        console2.log("C_new:", C_new);
        console2.log("C_LP_new:", releaseAmountUoA);
    }

    function test_e_mathlib_splitCollateralAfterExtLiq_boundsBased_case22() external noGasMetering {
        // Target LTV: 9946 bps
        uint256 C_leftUoA = 100e18;
        uint256 C_LP_oldUoA = 10e18;
        // B_left = (9946 * 90) / 10000 = 89.514
        uint256 B_leftUoA = 89514000000000000000; // 89.514e18

        // Verify LTV calculation: LTV_bps = (MAXFACTOR * B) / C
        // where C = C_left - C_LP_old = 100 - 10 = 90
        uint256 userCollateralValueUoA = C_leftUoA - C_LP_oldUoA; // 90e18
        uint256 calculatedLTV_bps = (10000 * B_leftUoA) / userCollateralValueUoA;
        console2.log("=== Case 22 (Target: 9946 LTV) ===");
        console2.log("Calculated LTV (bps):", calculatedLTV_bps);
        require(calculatedLTV_bps == 9946, "LTV mismatch");

        (uint256 liquidatorRewardUoA, uint256 releaseAmountUoA, uint256 borrowerClaimUoA) =
            LiquidationMath.splitCollateralAfterExtLiqUoA(
                C_leftUoA,
                B_leftUoA,
                C_LP_oldUoA,
                10_000,
                8_500,
                9_300
            );

        uint256 C_new = borrowerClaimUoA + liquidatorRewardUoA;
        console2.log("C_new:", C_new);
        console2.log("C_LP_new:", releaseAmountUoA);
    }

    //C_temp chosen cases

    function test_e_mathlib_splitCollateralAfterExtLiq_ctempChosen_case1() external noGasMetering {
        uint256 C_leftUoA = 100e18;
        uint256 C_LP_oldUoA = 17e18;
        uint256 B_leftUoA = 80e18;

        (uint256 liquidatorRewardUoA, uint256 releaseAmountUoA, uint256 borrowerClaimUoA) =
            LiquidationMath.splitCollateralAfterExtLiqUoA(
                C_leftUoA,
                B_leftUoA,
                C_LP_oldUoA,
                10_000,
                8_500,
                9_300
            );

        uint256 C_new = borrowerClaimUoA + liquidatorRewardUoA;
        console2.log("C_new:", C_new);
        console2.log("C_LP_new:", releaseAmountUoA);
    }

    function test_e_mathlib_splitCollateralAfterExtLiq_ctempChosen_case2() external noGasMetering {
        uint256 C_leftUoA = 100e18;
        uint256 C_LP_oldUoA = 17e18;
        uint256 B_leftUoA = 82e18;

        (uint256 liquidatorRewardUoA, uint256 releaseAmountUoA, uint256 borrowerClaimUoA) =
            LiquidationMath.splitCollateralAfterExtLiqUoA(
                C_leftUoA,
                B_leftUoA,
                C_LP_oldUoA,
                10_000,
                8_500,
                9_300
            );

        uint256 C_new = borrowerClaimUoA + liquidatorRewardUoA;
        console2.log("C_new:", C_new);
        console2.log("C_LP_new:", releaseAmountUoA);
        
    }

    function test_e_mathlib_splitCollateralAfterExtLiq_ctempChosen_case3() external noGasMetering {
        uint256 C_leftUoA = 100e18;
        uint256 C_LP_oldUoA = 17e18;
        uint256 B_leftUoA = 85e18;

        (uint256 liquidatorRewardUoA, uint256 releaseAmountUoA, uint256 borrowerClaimUoA) =
            LiquidationMath.splitCollateralAfterExtLiqUoA(
                C_leftUoA,
                B_leftUoA,
                C_LP_oldUoA,
                10_000,
                8_500,
                9_300
            );

        uint256 C_new = borrowerClaimUoA + liquidatorRewardUoA;
        console2.log("C_new:", C_new);
        console2.log("C_LP_new:", releaseAmountUoA);
    }

    function test_e_mathlib_splitCollateralAfterExtLiq_ctempChosen_case4() external noGasMetering {
        uint256 C_leftUoA = 100e18;
        uint256 C_LP_oldUoA = 17e18;
        uint256 B_leftUoA = 87e18;

        (uint256 liquidatorRewardUoA, uint256 releaseAmountUoA, uint256 borrowerClaimUoA) =
            LiquidationMath.splitCollateralAfterExtLiqUoA(
                C_leftUoA,
                B_leftUoA,
                C_LP_oldUoA,
                10_000,
                8_500,
                9_300
            );

        uint256 C_new = borrowerClaimUoA + liquidatorRewardUoA;
        console2.log("C_new:", C_new);
        console2.log("C_LP_new:", releaseAmountUoA);
    }

    function test_e_mathlib_splitCollateralAfterExtLiq_ctempChosen_case5() external noGasMetering {
        uint256 C_leftUoA = 100e18;
        uint256 C_LP_oldUoA = 17e18;
        uint256 B_leftUoA = 90e18;

        (uint256 liquidatorRewardUoA, uint256 releaseAmountUoA, uint256 borrowerClaimUoA) =
            LiquidationMath.splitCollateralAfterExtLiqUoA(
                C_leftUoA,
                B_leftUoA,
                C_LP_oldUoA,
                10_000,
                8_500,
                9_300
            );

        uint256 C_new = borrowerClaimUoA + liquidatorRewardUoA;
        console2.log("C_new:", C_new);
        console2.log("C_LP_new:", releaseAmountUoA);
    }

    function test_e_mathlib_splitCollateralAfterExtLiq_ctempChosen_case6() external noGasMetering {
        uint256 C_leftUoA = 100e18;
        uint256 C_LP_oldUoA = 17e18;
        uint256 B_leftUoA = 95e18;

        (uint256 liquidatorRewardUoA, uint256 releaseAmountUoA, uint256 borrowerClaimUoA) =
            LiquidationMath.splitCollateralAfterExtLiqUoA(
                C_leftUoA,
                B_leftUoA,
                C_LP_oldUoA,
                10_000,
                8_500,
                9_300
            );

        uint256 C_new = borrowerClaimUoA + liquidatorRewardUoA;
        console2.log("C_new:", C_new);
        console2.log("C_LP_new:", releaseAmountUoA);

        //C_new = 100, c_lp_new = 0
    }


    ///////////////////////////////////////////////
    //Math edge cases

    struct SplitCollateralAfterExtLiqInput {
        uint256 collateralBalance;
        uint256 userCollateralInitial;
        uint256 maxRelease;
        uint256 C_new;
        uint256 B;
        uint256 externalLiqBuffer;
        uint256 extLiqLTV;
        uint256 maxLTV_t;
    }

    function test_e_handleExternalLiquidationMath_splitCollateralAfterExtLiq_ZeroCollateral() external noGasMetering {
        SplitCollateralAfterExtLiqInput memory input = SplitCollateralAfterExtLiqInput({
            collateralBalance: 0,
            userCollateralInitial: 0,
            maxRelease: 0,
            C_new: 0,
            B: 0,
            externalLiqBuffer: 10_000,
            extLiqLTV: 8_500,
            maxLTV_t: 9_300
        });

        (uint256 liquidatorReward, uint256 releaseAmount, uint256 borrowerClaim) =
            LiquidationMath.splitCollateralAfterExtLiq(
                input.collateralBalance,
                input.userCollateralInitial,
                input.maxRelease,
                input.C_new,
                input.B,
                input.externalLiqBuffer,
                input.extLiqLTV,
                input.maxLTV_t
            );

        assertEq(liquidatorReward, 0, "liquidatorReward should be 0");
        assertEq(releaseAmount, 0, "releaseAmount should be 0");
        assertEq(borrowerClaim, 0, "borrowerClaim should be 0");
    }

    function test_e_handleExternalLiquidationMath_splitCollateralAfterExtLiq_ZeroMaxRelease() external noGasMetering {
        SplitCollateralAfterExtLiqInput memory input = SplitCollateralAfterExtLiqInput({
            collateralBalance: 1e18,
            userCollateralInitial: 1e18,
            maxRelease: 0,
            C_new: 1e18,
            B: 5e6,
            externalLiqBuffer: 10_000,
            extLiqLTV: 8_500,
            maxLTV_t: 9_300
        });

        (uint256 liquidatorReward, uint256 releaseAmount, uint256 borrowerClaim) =
            LiquidationMath.splitCollateralAfterExtLiq(
                input.collateralBalance,
                input.userCollateralInitial,
                input.maxRelease,
                input.C_new,
                input.B,
                input.externalLiqBuffer,
                input.extLiqLTV,
                input.maxLTV_t
            );

        assertEq(releaseAmount, 0, "releaseAmount should be 0");
        assertEq(liquidatorReward, input.B, "liquidatorReward should equal outstanding debt");
        assertEq(borrowerClaim, input.collateralBalance - input.B, "borrower keeps the remainder");
        assertEq(liquidatorReward + borrowerClaim + releaseAmount, input.collateralBalance, "conservation check");
    }

    function test_e_handleExternalLiquidationMath_splitCollateralAfterExtLiq_ZeroUserCollateralInitial() external noGasMetering {
        SplitCollateralAfterExtLiqInput memory input = SplitCollateralAfterExtLiqInput({
            collateralBalance: 2e18,
            userCollateralInitial: 0,
            maxRelease: 5e17,
            C_new: 15e17,
            B: 0,
            externalLiqBuffer: 10_000,
            extLiqLTV: 8_500,
            maxLTV_t: 9_300
        });

        (uint256 liquidatorReward, uint256 releaseAmount, uint256 borrowerClaim) =
            LiquidationMath.splitCollateralAfterExtLiq(
                input.collateralBalance,
                input.userCollateralInitial,
                input.maxRelease,
                input.C_new,
                input.B,
                input.externalLiqBuffer,
                input.extLiqLTV,
                input.maxLTV_t
            );

        assertEq(releaseAmount, 5e17, "maxRelease should cap release");
        assertEq(borrowerClaim, 15e17, "borrower should receive remaining collateral");
        assertEq(liquidatorReward, 0, "no debt means no reward");
    }

    function test_e_handleExternalLiquidationMath_splitCollateralAfterExtLiq_UserCollateralInitialExceedsCollateralBalance()
        external
        noGasMetering
    {
        SplitCollateralAfterExtLiqInput memory input = SplitCollateralAfterExtLiqInput({
            collateralBalance: 1e18,
            userCollateralInitial: 12e17,
            maxRelease: 4e17,
            C_new: 1e18,
            B: 1e17,
            externalLiqBuffer: 10_000,
            extLiqLTV: 8_500,
            maxLTV_t: 9_300
        });

        (uint256 liquidatorReward, uint256 releaseAmount, uint256 borrowerClaim) =
            LiquidationMath.splitCollateralAfterExtLiq(
                input.collateralBalance,
                input.userCollateralInitial,
                input.maxRelease,
                input.C_new,
                input.B,
                input.externalLiqBuffer,
                input.extLiqLTV,
                input.maxLTV_t
            );

        assertEq(releaseAmount, 0, "availableForRelease is clamped to zero");
        assertEq(borrowerClaim, input.collateralBalance - input.B, "borrower keeps collateral minus debt");
        assertEq(liquidatorReward, input.B, "liquidator receives outstanding debt");
    }

    function test_e_handleExternalLiquidationMath_splitCollateralAfterExtLiq_ZeroC_new() external noGasMetering {
        SplitCollateralAfterExtLiqInput memory input = SplitCollateralAfterExtLiqInput({
            collateralBalance: 1e18,
            userCollateralInitial: 5e17,
            maxRelease: 1e17,
            C_new: 0,
            B: 2e17,
            externalLiqBuffer: 10_000,
            extLiqLTV: 8_500,
            maxLTV_t: 9_300
        });

        (uint256 liquidatorReward, uint256 releaseAmount, uint256 borrowerClaim) =
            LiquidationMath.splitCollateralAfterExtLiq(
                input.collateralBalance,
                input.userCollateralInitial,
                input.maxRelease,
                input.C_new,
                input.B,
                input.externalLiqBuffer,
                input.extLiqLTV,
                input.maxLTV_t
            );

        assertEq(releaseAmount, 1e17, "release limited by maxRelease");
        assertEq(borrowerClaim, 0, "zero C_new implies no borrower claim");
        assertEq(liquidatorReward, 9e17, "all remaining collateral flows to liquidator");
    }

    function test_e_handleExternalLiquidationMath_splitCollateralAfterExtLiq_ZeroB() external noGasMetering {
        SplitCollateralAfterExtLiqInput memory input = SplitCollateralAfterExtLiqInput({
            collateralBalance: 1e18,
            userCollateralInitial: 8e17,
            maxRelease: 1e17,
            C_new: 9e17,
            B: 0,
            externalLiqBuffer: 10_000,
            extLiqLTV: 8_500,
            maxLTV_t: 9_300
        });

        (uint256 liquidatorReward, uint256 releaseAmount, uint256 borrowerClaim) =
            LiquidationMath.splitCollateralAfterExtLiq(
                input.collateralBalance,
                input.userCollateralInitial,
                input.maxRelease,
                input.C_new,
                input.B,
                input.externalLiqBuffer,
                input.extLiqLTV,
                input.maxLTV_t
            );

        assertEq(releaseAmount, 1e17, "releaseAmount should equal maxRelease");
        assertEq(borrowerClaim, 9e17, "borrower receives all remaining collateral");
        assertEq(liquidatorReward, 0, "no debt -> no reward");
    }

    function test_e_handleExternalLiquidationMath_splitCollateralAfterExtLiq_TinyValues() external noGasMetering {
        SplitCollateralAfterExtLiqInput memory input = SplitCollateralAfterExtLiqInput({
            collateralBalance: 1,
            userCollateralInitial: 0,
            maxRelease: 0,
            C_new: 1,
            B: 1,
            externalLiqBuffer: 10_000,
            extLiqLTV: 8_500,
            maxLTV_t: 9_300
        });

        (uint256 liquidatorReward, uint256 releaseAmount, uint256 borrowerClaim) = LiquidationMath.splitCollateralAfterExtLiq(
            input.collateralBalance,
            input.userCollateralInitial,
            input.maxRelease,
            input.C_new,
            input.B,
            input.externalLiqBuffer,
            input.extLiqLTV,
            input.maxLTV_t
        );

        assertEq(releaseAmount, 0, "releaseAmount should be zero");
        assertEq(borrowerClaim, 0, "borrowerClaim should round down to zero");
        assertEq(liquidatorReward, 1, "liquidator should receive the single unit");
    }

    function test_e_handleExternalLiquidationMath_splitCollateralAfterExtLiq_SmallReleaseClamp() external noGasMetering {
        SplitCollateralAfterExtLiqInput memory input = SplitCollateralAfterExtLiqInput({
            collateralBalance: 10,
            userCollateralInitial: 3,
            maxRelease: 4,
            C_new: 7,
            B: 2,
            externalLiqBuffer: 10_000,
            extLiqLTV: 8_500,
            maxLTV_t: 9_300
        });

        (uint256 liquidatorReward, uint256 releaseAmount, uint256 borrowerClaim) = LiquidationMath.splitCollateralAfterExtLiq(
            input.collateralBalance,
            input.userCollateralInitial,
            input.maxRelease,
            input.C_new,
            input.B,
            input.externalLiqBuffer,
            input.extLiqLTV,
            input.maxLTV_t
        );

        assertEq(releaseAmount, 4, "releaseAmount should match maxRelease");
        assertEq(borrowerClaim, 4, "borrower keeps remainder minus debt");
        assertEq(liquidatorReward, 2, "liquidator receives outstanding debt");
        assertEq(liquidatorReward + borrowerClaim + releaseAmount, 10, "conserve collateral");
    }

    function test_e_handleExternalLiquidationMath_splitCollateralAfterExtLiq_SmallZeroC_new() external noGasMetering {
        SplitCollateralAfterExtLiqInput memory input = SplitCollateralAfterExtLiqInput({
            collateralBalance: 5,
            userCollateralInitial: 2,
            maxRelease: 1,
            C_new: 0,
            B: 0,
            externalLiqBuffer: 10_000,
            extLiqLTV: 8_500,
            maxLTV_t: 9_300
        });

        (uint256 liquidatorReward, uint256 releaseAmount, uint256 borrowerClaim) = LiquidationMath.splitCollateralAfterExtLiq(
            input.collateralBalance,
            input.userCollateralInitial,
            input.maxRelease,
            input.C_new,
            input.B,
            input.externalLiqBuffer,
            input.extLiqLTV,
            input.maxLTV_t
        );

        assertEq(releaseAmount, 1, "releaseAmount should hit the cap");
        assertEq(borrowerClaim, 0, "no USD quote implies borrower gets zero");
        assertEq(liquidatorReward, 4, "remaining assets go to liquidator");
    }

    function test_e_handleExternalLiquidationMath_splitCollateralAfterExtLiq_SmallBorrowerCollateralUSDBoundary() external noGasMetering {
        uint256 externalLiqBuffer = 9_999;
        uint256 extLiqLTV = 1;
        uint256 maxLTV_t = 10_000;
        uint256 B = 1;
        uint256 C = 1;

        uint256 result = LiquidationMath.borrowerCollateralBase(B, C, externalLiqBuffer, extLiqLTV, maxLTV_t);
        assertEq(result, 0, "at boundary borrower receives zero");
    }

    function test_e_handleExternalLiquidationMath_splitCollateralAfterExtLiq_LargeNumbersConserveCollateral()
        external
        noGasMetering
    {
        uint256 collateralBalance = 1e27;
        uint256 userCollateralInitial = collateralBalance - 1e18;
        uint256 maxRelease = 1e20;
        uint256 userCollateralUSD = collateralBalance - 1e18;
        uint256 B = 1e23;

        (uint256 liquidatorReward, uint256 releaseAmount, uint256 borrowerClaim) =
            LiquidationMath.splitCollateralAfterExtLiq(
                collateralBalance,
                userCollateralInitial,
                maxRelease,
                userCollateralUSD,
                B,
                10_000,
                8_500,
                9_300
            );

        assertEq(releaseAmount, 1e18, "release capped by available collateral");
        assertEq(borrowerClaim, (collateralBalance - 1e18) - B, "borrower keeps collateral minus debt");
        assertEq(liquidatorReward, B, "remaining collateral goes to liquidator");
        assertEq(liquidatorReward + borrowerClaim + releaseAmount, collateralBalance, "collateral conserved");
    }

    function test_e_handleExternalLiquidationMath_splitCollateralAfterExtLiq_MaxReleaseClampHugeValues() external noGasMetering {
        uint256 collateralBalance = 2e30;
        uint256 userCollateralInitial = 1e18;
        uint256 maxRelease = type(uint256).max / 4;

        (uint256 liquidatorReward, uint256 releaseAmount, uint256 borrowerClaim) =
            LiquidationMath.splitCollateralAfterExtLiq(
                collateralBalance,
                userCollateralInitial,
                maxRelease,
                collateralBalance - userCollateralInitial,
                0,
                10_000,
                8_500,
                9_300
            );

        uint256 expectedRelease = collateralBalance - userCollateralInitial;
        assertEq(releaseAmount, expectedRelease, "release should clamp to available collateral");
        assertEq(borrowerClaim, userCollateralInitial, "borrower keeps remaining collateral");
        assertEq(liquidatorReward, 0, "no debt -> no liquidator reward");
    }

    function test_e_handleExternalLiquidationMath_borrowerCollateralBase_LargeFullyLiquidated() external noGasMetering {
        uint256 B = 5e30;
        uint256 maxLTV_t = 9_300;
        uint256 maxFactor = 10_000;
        uint256 C = ((maxFactor * B) / maxLTV_t) - 1;

        uint256 result = LiquidationMath.borrowerCollateralBase(B, C, 10_000, 8_500, maxLTV_t);
        assertEq(result, 0, "fully liquidated position should return zero even for large values");
    }
    /////////////////////////////////////////////////////////////////
    ///////////////// /////Fuzzing Tests /////////////////////////////
    /////////////////////////////////////////////////////////////////

    bool withoutFuzz = true;

    struct HandleExtLiqFuzzInput {
        uint8 priceDropBps;   // % drop applied before external liq
        uint8 repayPct;       // % of debt repaid by external liquidator (1–20 e.g.)
        uint8 extraCLPToggle; // 0 or 1 → whether to reserve extra CLP first
        uint16 twyneLTV;      // desired Twyne LTV (8500–9300)
        uint16 debtScaleBps;  // scales the base debt +/- 5–10%
    }

    function configureVault(HandleExtLiqFuzzInput memory f) internal {
        if(withoutFuzz) return;
        // Baseline constants: tweak if your suite uses different defaults
        uint256 baseCollateral = 5e18;
        uint256 baseCLP = f.extraCLPToggle == 0 ? 2e18 : 4e18; // toggle adds more CLP reserve
        uint256 baseDebt = 16_000e6;

        // Scale debt and CLP by fuzz input
        uint256 scaledDebt = (baseDebt * f.debtScaleBps) / 10_000;
        uint256 clpAmount = (baseCLP * f.debtScaleBps) / 10_000; // optional: keep CLP/debt ratios in sync

        // 1) build the vault
        createInitialPosition(baseCollateral, clpAmount, scaledDebt, f.twyneLTV);

        // Optional: add extra CLP if you want larger maxRelease
        if (f.extraCLPToggle == 1) {
            vm.startPrank(bob);
            IERC20(eulerWETH).approve(address(eeWETH_intermediate_vault), type(uint256).max);
            eeWETH_intermediate_vault.deposit(1e18, bob); // reserve +1 WETH worth of CLP
            vm.stopPrank();
        }

        // 2) make sure liquidator is funded & approved
        setup_approve_customSetup();
    }

    function testFuzz_handleExternalLiquidation_InterpolationWindow(HandleExtLiqFuzzInput memory f) external {
        if(withoutFuzz) return;
        // Step 1: Bound fuzz inputs to sensible ranges
        f.priceDropBps = uint8(bound(f.priceDropBps, 5, 25)); // 5% - 25%
        f.repayPct = uint8(bound(f.repayPct, 1, 20)); // 1% - 20%
        f.extraCLPToggle = uint8(f.extraCLPToggle % 2); // 0 or 1
        f.twyneLTV = uint16(bound(f.twyneLTV, 8900, 9300)); // interpolation window //TODO: better interpolation window
        f.debtScaleBps = uint16(bound(f.debtScaleBps, 9500, 10500)); // +/-5%

        // Step 2: Configure state
        configureVault(f);

        (uint256 B, uint256 C) = _getBC();
        uint256 currentLTV = (MAXFACTOR * MAXFACTOR * B) / C;
        if (currentLTV > 89_00 * MAXFACTOR && currentLTV < 93_00 * MAXFACTOR) {
            console2.log("hit target LTV", currentLTV);
            console2.log("priceDrop", f.priceDropBps);
            console2.log("repayPct", f.repayPct);
            console2.log("debtScaleBps", f.debtScaleBps);
            console2.log("extraCLPToggle", f.extraCLPToggle);
        }

        // Step 3: Apply price drop + external liquidation
        executePriceDrop(f.priceDropBps);
        vm.assume(alice_collateral_vault.canLiquidate());
        (uint256 extCollateralValueScaled, uint256 extDebtValueBefore) =
            IEVault(eulerUSDC).accountLiquidity(address(alice_collateral_vault), true);
        vm.assume(extDebtValueBefore > extCollateralValueScaled);
        try this._executeExternalLiquidationForFuzz(f.repayPct) {} catch {
            return; // skip iterations where external liquidation isn't viable
        }

        // Step 4: Ensure we’re in a meaningful state
        vm.assume(alice_collateral_vault.isExternallyLiquidated()); // skip iterations that didn’t trigger
        (uint256 extCollateralScaledByLiqLTV, uint256 extDebtValue) =
            IEVault(eulerUSDC).accountLiquidity(address(alice_collateral_vault), true);
        vm.assume(extCollateralScaledByLiqLTV >= extDebtValue);

        // Step 5: Execute handler and assert invariants
        executeHandleExternalLiquidation();

        assertEq(alice_collateral_vault.borrower(), address(0), "borrower not cleared");
        assertEq(alice_collateral_vault.maxRepay(), 0, "debt not zeroed");
        assertFalse(alice_collateral_vault.canLiquidate(), "still liquidatable");
        assertEq(alice_collateral_vault.totalAssetsDepositedOrReserved(), 0, "residual collateral");
        // Optionally verify liquidator reward + borrower claim sum to remaining collateral.
    }

    function testFuzz_findInterpolationInputs(HandleExtLiqFuzzInput memory f) external {
        if(withoutFuzz) return;
        // 1. Widen bounds so the fuzzer can explore more combinations
        f.priceDropBps = uint8(bound(f.priceDropBps, 5, 40)); // up to 40% drop
        f.repayPct = uint8(bound(f.repayPct, 1, 40));        // up to 40% repay
        f.extraCLPToggle = uint8(f.extraCLPToggle % 2);
        f.twyneLTV = uint16(bound(f.twyneLTV, 8500, 9300));  // full interpolation window
        f.debtScaleBps = uint16(bound(f.debtScaleBps, 9000, 11000)); // ±10%

        try this._configureVaultForFuzz(f.priceDropBps, f.repayPct, f.extraCLPToggle, f.twyneLTV, f.debtScaleBps) {} catch {
            return;
        }
        executePriceDrop(f.priceDropBps);
        vm.assume(alice_collateral_vault.canLiquidate());

        (uint256 extCollateralValueScaled, uint256 extDebtValueBefore) =
            IEVault(eulerUSDC).accountLiquidity(address(alice_collateral_vault), true);
        vm.assume(extDebtValueBefore > extCollateralValueScaled);

        try this._executeExternalLiquidationForFuzz(f.repayPct) {} catch {
            return;
        }

        vm.assume(alice_collateral_vault.isExternallyLiquidated());
        (uint256 B, uint256 C) = _getBC();
        uint256 currentLTV = (MAXFACTOR * MAXFACTOR * B) / C;

        vm.assume(currentLTV > 85_00 * MAXFACTOR && currentLTV < 93_00 * MAXFACTOR);

        console2.log("Found LTV", currentLTV);
        console2.log("priceDrop", f.priceDropBps);
        console2.log("repayPct", f.repayPct);
        console2.log("debtScaleBps", f.debtScaleBps);
        console2.log("extraCLPToggle", f.extraCLPToggle);
        console2.log("twyneLTV", f.twyneLTV);
        revert("CapturedInterpolationInput");
    }

    function testFuzz_handleExternalLiquidation_holistics( //TODO
        uint256 collateralAmount, // in eWETH tokens (18 decimals)
        uint256 creditAmount, // in CREDIT LP tokens (18 decimals)
        uint256 debtAmount, // in USDC (6 decimals)
        uint256 priceDropBps,
        uint256 twyneLTV
    ) public noGasMetering {
        if(withoutFuzz) return;
        // 1. Bound collateral to work with fixed 8 ether in intermediate vault
        collateralAmount = bound(collateralAmount, 1e18, 7e18); // 1 to 7 ETH
        creditAmount = bound(creditAmount, 0, collateralAmount); // 0 to 7 CREDIT LP tokens
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
        createInitialPosition(collateralAmount, creditAmount, debtAmount, twyneLTV);

        // 4. Execute price drop
        executePriceDrop(priceDropBps);

        // 5. Skip if not liquidatable
        vm.assume(alice_collateral_vault.canLiquidate());
        (uint256 extCollateralValueScaledBefore, uint256 extDebtValueBeforeLiq) =
            IEVault(eulerUSDC).accountLiquidity(address(alice_collateral_vault), true);
        vm.assume(extDebtValueBeforeLiq > extCollateralValueScaledBefore);

        // 6. Run external liquidation path (re-uses helper to manage funding/pranks)
        setup_approve_customSetup();
        try this._executeExternalLiquidationForFuzz(10) {} catch {
            return;
        }

        vm.assume(alice_collateral_vault.isExternallyLiquidated());
        (uint256 extCollateralScaledByLiqLTV, uint256 extDebtValue) =
            IEVault(eulerUSDC).accountLiquidity(address(alice_collateral_vault), true);
        vm.assume(extCollateralScaledByLiqLTV >= extDebtValue);

        // 7. Execute liquidation handling
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeHandleExternalLiquidation();

        // 7. Assert: vault fully unwinded, borrower reset
        assertEq(alice_collateral_vault.borrower(), address(0), "owner is not 0");
        assertEq(alice_collateral_vault.totalAssetsDepositedOrReserved(), 0, "totalAssetsDepositedOrReserved is not 0");
        // _assertAfterLiquidationAndRepay(snapshot);
    }

    function _configureVaultForFuzz(
        uint8 priceDropBps,
        uint8 repayPct,
        uint8 extraCLPToggle,
        uint16 twyneLTV,
        uint16 debtScaleBps
    ) external {
        require(msg.sender == address(this), "fuzz only self");
        HandleExtLiqFuzzInput memory input =
            HandleExtLiqFuzzInput(priceDropBps, repayPct, extraCLPToggle, twyneLTV, debtScaleBps);
        configureVault(input);
    }

    function _executeExternalLiquidationForFuzz(uint256 repayPct) external {
        require(msg.sender == address(this), "fuzz only self");
        executeExternalLiquidationWithPartialRepay(repayPct);
    }
    /////////////////////////////////////////////////////////////////
    ///////////////// /////LiqudationMathFUZZ Tests ////////////////////////////
    /////////////////////////////////////////////////////////////////
    struct FUZZSplitAfterExtLiqInput {
        uint128 collateralBalance;
        uint128 userCollateralInitial;
        uint128 maxRelease;
        uint128 C_new;
        uint128 B;
        uint16 externalLiqBuffer;
        uint16 extLiqLTV;
        uint16 maxLTV_t;
    }

    /// @notice Fuzz test: Conservation property - all outputs must sum to collateralBalance
    function testFuzz_splitCollateralAfterExtLiq_Conservation(
        uint128 collateralBalance,
        uint128 userCollateralInitial,
        uint128 maxRelease,
        uint128 C_new,
        uint128 B,
        uint16 externalLiqBuffer,
        uint16 extLiqLTV,
        uint16 maxLTV_t
    ) external {
        if(withoutFuzz) return;
        // Bound inputs to prevent overflows and ensure valid states
        collateralBalance = uint128(bound(collateralBalance, 1, type(uint128).max / 3));
        userCollateralInitial = uint128(bound(userCollateralInitial, 0, collateralBalance)); // Prevent underflow
        maxRelease = uint128(bound(maxRelease, 0, collateralBalance));
        C_new = uint128(bound(C_new, 1, type(uint128).max / 2)); // Must be > 0 to avoid division by zero
        B = uint128(bound(B, 0, type(uint128).max / 2));
        externalLiqBuffer = uint16(bound(externalLiqBuffer, 0, 10_000));
        extLiqLTV = uint16(bound(extLiqLTV, 0, 10_000));
        maxLTV_t = uint16(bound(maxLTV_t, 1, 10_000)); // Must be > 0

        // Skip if userCollateralInitial > collateralBalance (will revert)
        if (userCollateralInitial > collateralBalance) return;

        (uint256 liquidatorReward, uint256 releaseAmount, uint256 borrowerClaim) =
            LiquidationMath.splitCollateralAfterExtLiq(
                collateralBalance,
                userCollateralInitial,
                maxRelease,
                C_new,
                B,
                externalLiqBuffer,
                extLiqLTV,
                maxLTV_t
            );

        // Conservation check: all outputs must sum to collateralBalance
        assertEq(
            liquidatorReward + releaseAmount + borrowerClaim,
            collateralBalance,
            "Collateral must be conserved"
        );
    }

    /// @notice Fuzz test: Bounds checking - all outputs must be within expected ranges
    function testFuzz_splitCollateralAfterExtLiq_Bounds(
        uint128 collateralBalance,
        uint128 userCollateralInitial,
        uint128 maxRelease,
        uint128 C_new,
        uint128 B,
        uint16 externalLiqBuffer,
        uint16 extLiqLTV,
        uint16 maxLTV_t
    ) external {
        if(withoutFuzz) return;
        // Bound inputs to prevent overflows and ensure valid states
        collateralBalance = uint128(bound(collateralBalance, 1, type(uint128).max / 3));
        userCollateralInitial = uint128(bound(userCollateralInitial, 0, collateralBalance));
        maxRelease = uint128(bound(maxRelease, 0, collateralBalance));
        C_new = uint128(bound(C_new, 1, type(uint128).max / 2)); // Must be > 0
        B = uint128(bound(B, 0, type(uint128).max / 2));
        externalLiqBuffer = uint16(bound(externalLiqBuffer, 0, 10_000));
        extLiqLTV = uint16(bound(extLiqLTV, 0, 10_000));
        maxLTV_t = uint16(bound(maxLTV_t, 1, 10_000)); // Must be > 0

        // Skip if userCollateralInitial > collateralBalance (will revert)
        if (userCollateralInitial > collateralBalance) return;

        (uint256 liquidatorReward, uint256 releaseAmount, uint256 borrowerClaim) =
            LiquidationMath.splitCollateralAfterExtLiq(
                collateralBalance,
                userCollateralInitial,
                maxRelease,
                C_new,
                B,
                externalLiqBuffer,
                extLiqLTV,
                maxLTV_t
            );

        // All outputs must be non-negative (uint256 guarantees this, but check for sanity)
        assertGe(liquidatorReward, 0, "liquidatorReward must be >= 0");
        assertGe(releaseAmount, 0, "releaseAmount must be >= 0");
        assertGe(borrowerClaim, 0, "borrowerClaim must be >= 0");

        // releaseAmount must be <= maxRelease
        assertLe(releaseAmount, maxRelease, "releaseAmount must not exceed maxRelease");

        // All outputs must be <= collateralBalance
        assertLe(liquidatorReward, collateralBalance, "liquidatorReward must not exceed collateralBalance");
        assertLe(releaseAmount, collateralBalance, "releaseAmount must not exceed collateralBalance");
        assertLe(borrowerClaim, collateralBalance, "borrowerClaim must not exceed collateralBalance");
    }

    /// @notice Fuzz test: Relationship checks - verify internal relationships between values
    function testFuzz_splitCollateralAfterExtLiq_Relationships(
        uint128 collateralBalance,
        uint128 userCollateralInitial,
        uint128 maxRelease,
        uint128 C_new,
        uint128 B,
        uint16 externalLiqBuffer,
        uint16 extLiqLTV,
        uint16 maxLTV_t
    ) external {
        if(withoutFuzz) return;
        // Bound inputs to prevent overflows and ensure valid states
        collateralBalance = uint128(bound(collateralBalance, 1, type(uint128).max / 3));
        userCollateralInitial = uint128(bound(userCollateralInitial, 0, collateralBalance));
        maxRelease = uint128(bound(maxRelease, 0, collateralBalance));
        C_new = uint128(bound(C_new, 1, type(uint128).max / 2)); // Must be > 0
        B = uint128(bound(B, 0, type(uint128).max / 2));
        externalLiqBuffer = uint16(bound(externalLiqBuffer, 0, 10_000));
        extLiqLTV = uint16(bound(extLiqLTV, 0, 10_000));
        maxLTV_t = uint16(bound(maxLTV_t, 1, 10_000)); // Must be > 0

        // Skip if userCollateralInitial > collateralBalance (will revert)
        if (userCollateralInitial > collateralBalance) return;

        (uint256 liquidatorReward, uint256 releaseAmount, uint256 borrowerClaim) =
            LiquidationMath.splitCollateralAfterExtLiq(
                collateralBalance,
                userCollateralInitial,
                maxRelease,
                C_new,
                B,
                externalLiqBuffer,
                extLiqLTV,
                maxLTV_t
            );

        // Calculate userCollateral (should be collateralBalance - releaseAmount)
        uint256 userCollateral = collateralBalance - releaseAmount;

        // Verify: liquidatorReward = userCollateral - borrowerClaim
        assertEq(
            liquidatorReward,
            userCollateral - borrowerClaim,
            "liquidatorReward must equal userCollateral - borrowerClaim"
        );

        // Verify: borrowerClaim <= userCollateral (capped)
        assertLe(borrowerClaim, userCollateral, "borrowerClaim must not exceed userCollateral");
    }

    /// @notice Fuzz test: Small values - test with tiny amounts to catch rounding/edge cases
    function testFuzz_splitCollateralAfterExtLiq_SmallValues(
        uint128 collateralBalance,
        uint128 userCollateralInitial,
        uint128 maxRelease,
        uint128 C_new,
        uint128 B,
        uint16 externalLiqBuffer,
        uint16 extLiqLTV,
        uint16 maxLTV_t
    ) external {
        if(withoutFuzz) return;
        // Bound inputs to small values (1-1000) to test edge cases with tiny amounts
        collateralBalance = uint128(bound(collateralBalance, 1, 1000));
        userCollateralInitial = uint128(bound(userCollateralInitial, 0, collateralBalance));
        maxRelease = uint128(bound(maxRelease, 0, collateralBalance));
        C_new = uint128(bound(C_new, 1, 1000)); // Must be > 0
        B = uint128(bound(B, 0, 1000));
        externalLiqBuffer = uint16(bound(externalLiqBuffer, 0, 10_000));
        extLiqLTV = uint16(bound(extLiqLTV, 0, 10_000));
        maxLTV_t = uint16(bound(maxLTV_t, 1, 10_000)); // Must be > 0

        // Skip if userCollateralInitial > collateralBalance (will revert)
        if (userCollateralInitial > collateralBalance) return;

        (uint256 liquidatorReward, uint256 releaseAmount, uint256 borrowerClaim) =
            LiquidationMath.splitCollateralAfterExtLiq(
                collateralBalance,
                userCollateralInitial,
                maxRelease,
                C_new,
                B,
                externalLiqBuffer,
                extLiqLTV,
                maxLTV_t
            );

        // Conservation check: all outputs must sum to collateralBalance
        assertEq(
            liquidatorReward + releaseAmount + borrowerClaim,
            collateralBalance,
            "Collateral must be conserved with small values"
        );

        // All outputs must be non-negative
        assertGe(liquidatorReward, 0, "liquidatorReward must be >= 0");
        assertGe(releaseAmount, 0, "releaseAmount must be >= 0");
        assertGe(borrowerClaim, 0, "borrowerClaim must be >= 0");

        // All outputs must be <= collateralBalance
        assertLe(liquidatorReward, collateralBalance, "liquidatorReward must not exceed collateralBalance");
        assertLe(releaseAmount, collateralBalance, "releaseAmount must not exceed collateralBalance");
        assertLe(borrowerClaim, collateralBalance, "borrowerClaim must not exceed collateralBalance");

        // releaseAmount must be <= maxRelease
        assertLe(releaseAmount, maxRelease, "releaseAmount must not exceed maxRelease");
    }

    /////////////////////////////////////////////////////////////////
    ///////////////// /////Vector Attack Tests //////////////////////
    /////////////////////////////////////////////////////////////////

    function test_e_vectorAttack_handleExternalLiquidation_SendAssetAmountAfterExternalLiq() external noGasMetering {
        // 1. Arrange: build initial vault state
        createInitialPosition(5e18, 0, 16_000e6, 9000);

        // 2. Price drop
        executePriceDrop(10);

        // 3. Give liquidator approvals / balances
        setup_approve_customSetup();

        // 4. Execute external liquidation and repay batch 
        executeExternalLiquidationWithPartialRepay(10); 

        // 5. Capture state after external liquidation
        address __asset = alice_collateral_vault.asset();
        uint256 totalAssetsDepositedOrReserved = alice_collateral_vault.totalAssetsDepositedOrReserved();
        uint256 balanceAfterExtLiq = IERC20(__asset).balanceOf(address(alice_collateral_vault));
        
        console2.log("totalAssetsDepositedOrReserved:", totalAssetsDepositedOrReserved);
        console2.log("balanceAfterExtLiq:", balanceAfterExtLiq);
        console2.log("Difference (amount liquidated):", totalAssetsDepositedOrReserved - balanceAfterExtLiq);
        
        // Verify the condition that allows handleExternalLiquidation to proceed
        assertGt(totalAssetsDepositedOrReserved, balanceAfterExtLiq, "Should be externally liquidated");

        // 6. ATTACK: Attacker sends assets to vault to break the check
        address attacker = makeAddr("attacker");
        // Calculate how much to send to make balance >= totalAssetsDepositedOrReserved
        uint256 amountToSend = totalAssetsDepositedOrReserved - balanceAfterExtLiq + 1; // +1 to make it >=
        
        // Give attacker enough tokens (dealEToken handles scaling, but give extra to be safe)
        // We need to give them enough underlying to deposit and get the required eToken amount
        // dealEToken will handle the deposit, but we need to account for potential scaling
        uint256 amountToDeal = amountToSend * 2; // Give extra to account for any scaling
        dealEToken(__asset, attacker, amountToDeal);
        
        // Get the actual balance the attacker received
        uint256 attackerBalance = IERC20(__asset).balanceOf(attacker);
        console2.log("attackerBalance:", attackerBalance);
        console2.log("amountToSend needed:", amountToSend);
        
        // Transfer the required amount (or all if we don't have enough)
        uint256 transferAmount = attackerBalance >= amountToSend ? amountToSend : attackerBalance;
        vm.startPrank(attacker);
        IERC20(__asset).transfer(address(alice_collateral_vault), transferAmount);
        vm.stopPrank();
        
        uint256 balanceAfterAttack = IERC20(__asset).balanceOf(address(alice_collateral_vault));
        console2.log("balanceAfterAttack:", balanceAfterAttack);
        console2.log("totalAssetsDepositedOrReserved:", totalAssetsDepositedOrReserved);
        
        // Verify the attack succeeded: balance is now >= totalAssetsDepositedOrReserved
        assertGe(balanceAfterAttack, totalAssetsDepositedOrReserved, "Attack: balance should be >= totalAssetsDepositedOrReserved");

        // 7. Attempt to call handleExternalLiquidation - should revert
        // The check at line 239: require(totalAssetsDepositedOrReserved > amount, NotExternallyLiquidated())
        // will fail because balanceAfterAttack >= totalAssetsDepositedOrReserved
        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.NotExternallyLiquidated.selector);
        evc.call({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.handleExternalLiquidation, ())
        });
        vm.stopPrank();
        
        // 8. Note: isExternallyLiquidated() also checks the balance, so it will return false after the attack
        // This is expected - the attack breaks the detection mechanism
        // The vault WAS externally liquidated, but the check can no longer detect it due to the attack
        console2.log("isExternallyLiquidated after attack:", alice_collateral_vault.isExternallyLiquidated());
    }


    /////////////////////////////////////////////////////////////////
    ///////////////// /////Revert Tests /////////////////////////////
    /////////////////////////////////////////////////////////////////

    /// @notice Test that borrower cannot liquidate their own position
    function test_e_expectRevert_handleExternalLiquidation_NotExternallyLiquidated() external noGasMetering {
        createInitialPosition(5e18, 0, 16_000e6, 8500);

        // Borrower tries to liquidate their own position
        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.NotExternallyLiquidated.selector);
        evc.call({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.handleExternalLiquidation, ())
        });
        vm.stopPrank();
    }

    /// @notice Test that liquidate() reverts when vault is externally liquidated
    function test_e_expectRevert_handleExternalLiquidation_ExternalPositionUnhealthy() external noGasMetering {
        createInitialPosition(5e18, 0, 16_000e6, 8500);

        executePriceDrop(10);

        setup_approve_customSetup();

        executeExternalLiquidationWithPartialRepay(5);

        // Borrower tries to liquidate their own position
        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.ExternalPositionUnhealthy.selector);
        evc.call({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.handleExternalLiquidation, ())
        });
        vm.stopPrank();
    }

    /// @notice Test that liquidate() reverts when vault is healthy (not liquidatable)
    function test_e_expectRevert_handleExternalLiquidation_NoLiquidationForZeroReserve() external noGasMetering {
        createInitialPosition(5e18, 0, 16_000e6, 8500);

        executePriceDrop(5);

        setup_approve_customSetup();

        executeExternalLiquidationWithPartialRepay(10);

        // Borrower tries to liquidate their own position
        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.NoLiquidationForZeroReserve.selector);
        evc.call({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.handleExternalLiquidation, ())
        });
        vm.stopPrank();
    }

    /////////////////////////////////////////////////////////////////
    ///////////////// /////Helper Functions //////////////////////////
    /////////////////////////////////////////////////////////////////

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

        console2.log("AAAAAAAAAAAAAAAAAAAAAAAAAAA", alice_collateral_vault.maxRelease());

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

        // Enable liquidator permissions (before external liquidation)
        vm.startPrank(liquidator);
        IEVC(IEVault(eulerWETH).EVC()).enableCollateral(liquidator, address(eulerWETH));
        IEVC(IEVault(eulerUSDC).EVC()).enableController(liquidator, address(eulerUSDC));
        address evcAddress = IEVault(alice_collateral_vault.intermediateVault()).EVC();
        IEVC(evcAddress).enableCollateral(liquidator, address(alice_collateral_vault));
        IEVC(evcAddress).enableController(liquidator, address(alice_collateral_vault.intermediateVault()));
        // Also approve permit2 early to ensure it's set up correctly
        IERC20(USDC).approve(permit2, type(uint256).max);
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

    /// @notice Logs post-fallback accounting in same format as Python's post_fallback_accounting
    /// @dev Captures state before handleExternalLiquidation and calculates accounting values
    /// @dev Matches Python logic: C_left = C + C_LP (total), C_temp = min(B_left / max_liqLTV_t, C_left)
    function _logPostFallbackAccounting() internal view {
        PostFallbackAccountingData memory data;
        address uoa = IEVault(alice_collateral_vault.intermediateVault()).unitOfAccount();
        
        // Capture pre-values (before handleExternalLiquidation)
        data.pre_C = alice_collateral_vault.totalAssetsDepositedOrReserved() - alice_collateral_vault.maxRelease();
        data.pre_CLP = alice_collateral_vault.maxRelease();
        
        // Capture current state (after external liquidation, before handleExternalLiquidation)
        // Current borrower state: C (collateral) and C_LP (CLP reserved)
        uint256 current_C = IERC20(alice_collateral_vault.asset()).balanceOf(address(alice_collateral_vault));
        uint256 current_C_LP = alice_collateral_vault.maxRelease(); // Current CLP after external liquidation
        
        // C_left = C + C_LP (total remaining collateral, matching Python)
        data.C_left = current_C + current_C_LP;
        
        (, data.B_left) = IEVault(eulerUSDC).accountLiquidity(address(alice_collateral_vault), true);
        
        // Get max liquidation LTV (in 1e4 precision)
        data.max_liqLTV_t = twyneVaultManager.maxTwyneLTVs(alice_collateral_vault.asset());
        
        // Convert C_left to USD for calculation
        data.C_left_USD = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(
            data.C_left,
            alice_collateral_vault.asset(),
            uoa
        );
        
        // C_temp = min(B_left / max_liqLTV_t, C_left) in USD
        // B_left is in USD, max_liqLTV_t is in 1e4 precision
        uint256 C_temp_calc = (data.B_left * MAXFACTOR) / data.max_liqLTV_t;
        data.C_temp_USD = Math.min(C_temp_calc, data.C_left_USD);
        
        // Convert C_temp back to collateral units
        if (data.C_temp_USD > 0) {
            data.C_temp = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(
                data.C_temp_USD,
                uoa,
                alice_collateral_vault.asset()
            );
        }
        
        // C_LP_new = min(C_left - C_temp, C_LP_old)
        data.C_LP_new = Math.min(
            data.C_left > data.C_temp ? data.C_left - data.C_temp : 0,
            data.pre_CLP
        );
        
        // C_new = max(C_temp, C_left - C_LP_old)
        data.C_new = Math.max(
            data.C_temp,
            data.C_left > data.pre_CLP ? data.C_left - data.pre_CLP : 0
        );
        
        // Calculate diffs (from borrower's CURRENT state, matching Python)
        // Python: C_diff = borrower.C - C_new (current C minus new C)
        data.C_diff = current_C > data.C_new ? current_C - data.C_new : 0;
        
        // Python: C_LP_diff = borrower.C_LP - C_LP_new (current C_LP minus new C_LP, can be negative)
        // In Solidity, we can't represent negative, so we check if it would be negative
        if (current_C_LP >= data.C_LP_new) {
            data.C_LP_diff = current_C_LP - data.C_LP_new;
        } else {
            // Would be negative in Python - log as 0 but note in comment
            data.C_LP_diff = 0;
        }
        
        // Calculate CLP loss (as percentage)
        if (data.pre_CLP > 0) {
            // Python: clp_loss = max(0.0, 1 - (C_LP_new / C_LP_old))
            uint256 clp_remaining_bps = (data.C_LP_new * MAXFACTOR) / data.pre_CLP;
            if (clp_remaining_bps < MAXFACTOR) {
                data.clp_loss_bps = MAXFACTOR - clp_remaining_bps;
            }
        }
        
        // Calculate excess credit (placeholder - would need _clp_invariant calculation)
        data.excess_credit = 0;
        
        // Log in same format as Python
        console2.log("=== Post-Fallback Accounting ===");
        console2.log("C_temp=", data.C_temp);
        console2.log("C_old=", data.pre_C);
        console2.log("C_LP_old=", data.pre_CLP);
        console2.log("B_left=", data.B_left);
        console2.log("C_diff=", data.C_diff);
        console2.log("C_LP_diff=", data.C_LP_diff);
        console2.log("C_new=", data.C_new);
        console2.log("C_LP_new=", data.C_LP_new);
        console2.log("excess_credit=", data.excess_credit);
        console2.log("clp_loss_bps=", data.clp_loss_bps);
        console2.log("C_left (total)=", data.C_left);
        console2.log("C_left_USD=", data.C_left_USD);
        console2.log("C_temp_USD=", data.C_temp_USD);
        
        // Convert C_new to USD/UOA for comparison with Python (which uses UOA values)
        uint256 C_new_USD = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(
            data.C_new,
            alice_collateral_vault.asset(),
            uoa
        );
        console2.log("C_new_USD=", C_new_USD);
    }

    /// @notice Helper function to call handleExternalLiquidation after external liquidation
    /// @dev Handles both cases: when maxRelease == 0 (borrower must call) and when maxRelease > 0 (liquidator can call)
    function executeHandleExternalLiquidation() internal {
        uint256 maxReleaseAfterExtLiq = alice_collateral_vault.maxRelease();
        uint256 maxRepayAfterExtLiq = alice_collateral_vault.maxRepay();

        // If maxRelease is 0, only borrower can call handleExternalLiquidation
        if (maxReleaseAfterExtLiq == 0) {
            // Borrower must call it
            vm.startPrank(alice);
            // Approve permit2 from alice's account
            IERC20(USDC).approve(permit2, type(uint256).max);
            IERC20(USDC).approve(address(alice_collateral_vault), type(uint256).max);

            evc.call({
                targetContract: address(alice_collateral_vault),
                onBehalfOfAccount: alice,
                value: 0,
                data: abi.encodeCall(alice_collateral_vault.handleExternalLiquidation, ())
            });
        } else {
            // Liquidator can call it when there's reserve
            vm.startPrank(liquidator);
            // Ensure liquidator has enough USDC to cover maxRepay
            uint256 requiredUSDC = maxRepayAfterExtLiq + 1_000_000; // Add padding
            if (IERC20(USDC).balanceOf(liquidator) < requiredUSDC) {
                deal(address(USDC), liquidator, requiredUSDC);
            }

            // Approve USDC from liquidator (needed for handleExternalLiquidation)
            // Must approve both the vault and permit2 - do this in the same prank context
            IERC20(USDC).approve(address(alice_collateral_vault), type(uint256).max);
            IERC20(USDC).approve(permit2, type(uint256).max);

            // Verify approvals are set correctly
            assertEq(
                IERC20(USDC).allowance(liquidator, address(alice_collateral_vault)),
                type(uint256).max,
                "vault approval failed"
            );
            assertEq(IERC20(USDC).allowance(liquidator, permit2), type(uint256).max, "permit2 approval failed");

            // Verify liquidator has sufficient USDC balance
            assertGe(IERC20(USDC).balanceOf(liquidator), maxRepayAfterExtLiq, "liquidator has insufficient USDC");

            // Call handleExternalLiquidation through EVC with liquidator as onBehalfOfAccount
            IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
            items[0] = IEVC.BatchItem({
                targetContract: address(alice_collateral_vault),
                onBehalfOfAccount: liquidator,
                value: 0,
                data: abi.encodeCall(alice_collateral_vault.handleExternalLiquidation, ())
            });

            evc.batch(items);
            vm.stopPrank();
        }
    }

    function executeExternalLiquidationWithPartialRepay(uint256 repayPct) public {
        // Small warp to clear any cool-off edge (keeps this “baseline” deterministic)
        vm.warp(block.timestamp + 1);

        // ------------------------------------------------------------------------
        // 2) Prepare liquidator perms (and any balances you require for your EVK)
        //    NOTE: your baseline funds eWETH; you keep that behavior here.
        // ------------------------------------------------------------------------
        dealEToken(eulerWETH, liquidator, 100 ether);
        vm.startPrank(liquidator);

        // Sanity: not yet externally liquidated; there is collateral to seize
        assertFalse(alice_collateral_vault.isExternallyLiquidated());
        assertGt(IERC20(eulerWETH).balanceOf(address(alice_collateral_vault)), 0, "before: eWETH is zero");

        // Must be something to repay on target EVault
        assertGt(alice_collateral_vault.maxRepay(), 0);

        // --- fund liquidator with enough USDC to repay the TARGET EVault debt ---
        uint256 debtAssets = IEVault(eulerUSDC).debtOf(address(alice_collateral_vault));
        uint256 pad = 1_000_000; // +1 USDC for safety (6d)
        deal(address(USDC), liquidator, debtAssets + pad);

        // --- allow vault pull via ERC20 transferFrom path ---
        vm.startPrank(liquidator);

        IERC20(USDC).approve(address(alice_collateral_vault), type(uint256).max);
        // Also approve permit2 in case it's needed later
        IERC20(USDC).approve(permit2, type(uint256).max);

        IEVault(eulerUSDC).liquidate({
            violator: address(alice_collateral_vault),
            collateral: eulerWETH,
            repayAssets: (IEVault(eulerUSDC).debtOf(address(alice_collateral_vault)) * repayPct) / 100,
            minYieldBalance: 0
        });
        vm.stopPrank();

        assertTrue(alice_collateral_vault.isExternallyLiquidated(), "not externally liquidated");
    }

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