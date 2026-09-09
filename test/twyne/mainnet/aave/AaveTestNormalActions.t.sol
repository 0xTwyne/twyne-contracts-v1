// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {AaveTestBase} from "./AaveTestBase.t.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";
import {IPool as IAaveV3Pool} from "aave-v3/interfaces/IPool.sol";
import {IPoolAddressesProvider as IAaveV3AddressProvider} from "aave-v3/interfaces/IPoolAddressesProvider.sol";
import {IPoolConfigurator} from "aave-v3/interfaces/IPoolConfigurator.sol";
import {IRMTwyneCurve} from "src/twyne/IRMTwyneCurve.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {AaveV3LeverageOperator} from "src/operators/AaveV3LeverageOperator.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {AaveV3DeleverageOperator} from "src/operators/AaveV3DeleverageOperator.sol";
import {AaveV3CollateralVault} from "src/twyne/AaveV3CollateralVault.sol";
import {MockSwapper} from "test/mocks/MockSwapper.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {IERC20Metadata} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";

contract AaveTestNormalActions is AaveTestBase {

    function setUp() public virtual override {
        super.setUp();
    }

    // non-fuzzing unit test for single collateral
    function test_aave_creditDeposit() public noGasMetering {
        aave_creditDeposit(address(aWETHWrapper));
    }

    // fuzzing entry point for all assets
    function testFuzz_aave_creditDeposit(address collateralAssets) public noGasMetering {
        aave_creditDeposit(collateralAssets);
    }

    // non-fuzzing unit test for single collateral
    function test_aave_createWETHCollateralVault() public noGasMetering {
        aave_createCollateralVault(address(aWETHWrapper), 0.9e4);
    }

    // fuzzing entry point for all assets
    function testFuzz_aave_createCollateralVault(address collateralAssets, uint16 liqLTV) public noGasMetering {
        aave_createCollateralVault(collateralAssets, liqLTV);
    }

    // non-fuzzing unit test for single collateral
    function test_aave_totalAssetsIntermediateVault() public noGasMetering {
        aave_totalAssetsIntermediateVault(address(aWETHWrapper), 0.9e4);
    }

    // fuzzing entry point for all assets
    function testFuzz_aave_totalAssetsIntermediateVault(address collateralAssets, uint16 liqLTV) public noGasMetering {
        aave_totalAssetsIntermediateVault(collateralAssets, liqLTV);
    }

    // non-fuzzing unit test for single collateral
    function test_aave_totalAssetsCollateralVault() public noGasMetering {
        aave_totalAssetsCollateralVault(address(aWETHWrapper), 0.9e4);
    }

    // fuzzing entry point for all assets
    function testFuzz_aave_totalAssetsCollateralVault(address collateralAssets, uint16 liqLTV) public noGasMetering {
        aave_totalAssetsCollateralVault(collateralAssets, liqLTV);
    }

    // non-fuzzing unit test for single collateral
    function test_aave_supplyCap_creditDeposit() public noGasMetering {
        aave_supplyCap_creditDeposit(address(aWETHWrapper));
    }

    // fuzzing entry point for all assets
    function testFuzz_aave_supplyCap_creditDeposit(address collateralAssets) public noGasMetering {
        aave_supplyCap_creditDeposit(collateralAssets);
    }

    // non-fuzzing unit test for single collateral
    function test_aave_second_creditDeposit() public noGasMetering {
        aave_second_creditDeposit(address(aWETHWrapper));
    }

    // fuzzing entry point for all assets
    function testFuzz_aave_second_creditDeposit(address collateralAssets) public noGasMetering {
        aave_second_creditDeposit(collateralAssets);
    }

    // non-fuzzing unit test for single collateral
    function test_aave_creditWithdrawNoInterest() public noGasMetering {
        aave_creditWithdrawNoInterest(address(aWETHWrapper));
    }

    // fuzzing entry point for all assets
    function testFuzz_aave_creditWithdrawNoInterest(address collateralAssets) public noGasMetering {
        aave_creditWithdrawNoInterest(collateralAssets);
    }

    // non-fuzzing unit test for single collateral
    function test_aave_collateralDepositWithoutBorrow() public noGasMetering {
        aave_collateralDepositWithoutBorrow(address(aWETHWrapper), 0.9e4);
    }

    // fuzzing entry point for all assets
    function testFuzz_aave_collateralDepositWithoutBorrow(address collateralAssets, uint16 liqLTV) public noGasMetering {
        aave_collateralDepositWithoutBorrow(collateralAssets, liqLTV);
    }

    function test_aave_creditWithdrawWithInterestAndNoFees() public noGasMetering {
        aave_creditWithdrawWithInterestAndNoFees(address(aWETHWrapper), 500);
    }

    // fuzzing entry point for all assets
    function testFuzz_aave_creditWithdrawWithInterestAndNoFees(address /* collateralAssets */, uint warpBlockAmount) public noGasMetering {
        aave_creditWithdrawWithInterestAndNoFees(address(aWETHWrapper), warpBlockAmount); // TODO
    }

    function test_aave_creditWithdrawWithInterestAndFees() public noGasMetering {
        aave_creditWithdrawWithInterestAndFees(address(aWETHWrapper));
    }

    function testFuzz_aave_creditWithdrawWithInterestAndFees(address /* collateralAssets */) public noGasMetering {
        aave_creditWithdrawWithInterestAndFees(address(aWETHWrapper)); // TODO
    }

    // Test the case of C_LP = 0 (no reserved assets) with non-zero C and B
    // This should be identical to using the underlying protocol without Twyne
    function test_aave_collateralDepositWithBorrow() public noGasMetering {
        aave_collateralDepositWithBorrow(address(aWETHWrapper));
    }

    function testFuzz_aave_collateralDepositWithBorrow(address collateralAssets) public noGasMetering {
        aave_collateralDepositWithBorrow(collateralAssets);
    }

    // Test Permit2 deposit of eWETH (not WETH)
    function test_aave_permit2CollateralDeposit() public noGasMetering {
        aave_permit2CollateralDeposit(address(aWETHWrapper));
    }

    function testFuzz_aave_permit2CollateralDeposit(address collateralAssets) public noGasMetering {
        aave_permit2CollateralDeposit(collateralAssets);
    }

    // Test the creation of a collateral vault in a batch (the frontend does this)
    function test_aave_evcCanCreateCollateralVault() public noGasMetering {
        aave_evcCanCreateCollateralVault(address(aWETHWrapper));
    }

    function testFuzz_aave_evcCanCreateCollateralVault(address collateralAssets) public noGasMetering {
        aave_evcCanCreateCollateralVault(collateralAssets);
    }

    // Test that if time passes, the balance of aTokens in the collateral vault increases and the user can withdraw all
    function test_aave_withdrawCollateralAfterWarp() public noGasMetering {
        aave_withdrawCollateralAfterWarp(address(aWETHWrapper), 500);
    }

    // fuzzing entry point for all assets and different warp periods
    function testFuzz_aave_withdrawCollateralAfterWarp(address collateralAssets, uint warpBlockAmount) public noGasMetering {
        aave_withdrawCollateralAfterWarp(collateralAssets, warpBlockAmount);
    }

    // Test the user withdrawing WETH from the collateral vault
    function test_aave_redeemUnderlying() public noGasMetering {
        aave_redeemUnderlying(address(aWETHWrapper));
    }

    function testFuzz_aave_redeemUnderlying(address collateralAssets) public noGasMetering {
        aave_redeemUnderlying(collateralAssets);
    }

    function test_aave_firstBorrowFromDirect() public noGasMetering {
        aave_firstBorrowDirect(address(aWETHWrapper));
    }

    function testFuzz_aave_firstBorrowFromEulerDirect(address collateralAssets) public noGasMetering {
        aave_firstBorrowDirect(collateralAssets);
    }

    function test_aave_firstBorrowViaCollateral() public noGasMetering {
        aave_firstBorrowViaCollateral(address(aWETHWrapper));
    }

    function testFuzz_aave_firstBorrowViaCollateral(address collateralAssets) public noGasMetering {
        aave_firstBorrowViaCollateral(collateralAssets);
    }

    // Separate the checks that are run after the borrow operation so that they are only run once
    // instead of running on every test that runs the borrow test first
    function test_aave_postBorrowChecks() public {
        aave_postBorrowChecks(address(aWETHWrapper));
    }

    function testFuzz_aave_postBorrowChecks(address collateralAssets) public {
        aave_postBorrowChecks(collateralAssets);
    }

    // Try max borrowing from the external protocol
    // This imitates the frontend
    function test_aave_maxBorrowDirect() public noGasMetering {
        aave_maxBorrowDirect(address(aWETHWrapper), 1e4);
    }

    // fuzzing entry point for all assets and different warp periods
    function testFuzz_aave_maxBorrowFromAaveDirect(address /* collateralAssets */, uint16 collateralMultiplier) public noGasMetering {
        aave_maxBorrowDirect(address(aWETHWrapper), collateralMultiplier); // TODO
    }

    // User wishes to close their collateral vault position by repaying all and withdrawing all
    function test_aave_repayWithdrawAll() public noGasMetering {
        aave_repayWithdrawAll(address(aWETHWrapper));
    }

    // fuzzing entry point for all assets and different warp periods
    function testFuzz_aave_repayWithdrawAll(address collateralAssets) public noGasMetering {
        aave_repayWithdrawAll(collateralAssets);
    }

    // User Permit2 to repay all
    function test_aave_permit2FirstRepay() public noGasMetering {
        aave_permit2FirstRepay(address(aWETHWrapper));
    }

    function testFuzz_aave_permit2FirstRepay(address collateralAssets) public noGasMetering {
        aave_permit2FirstRepay(collateralAssets);
    }

    function test_aave_interestAccrualThenRepay() external noGasMetering {
        aave_interestAccrualThenRepay(address(aWETHWrapper));
    }

    function testFuzz_aave_interestAccrualThenRepay(address collateralAssets) external noGasMetering {
        aave_interestAccrualThenRepay(collateralAssets);
    }

    function test_aave_secondBorrow() public noGasMetering {
        aave_secondBorrow(address(aWETHWrapper));
    }

    function testFuzz_aave_secondBorrow(address collateralAssets) public noGasMetering {
        aave_secondBorrow(collateralAssets);
    }

    // user sets their custom LTV before borrowing
    function test_aave_setTwyneLiqLTVNoBorrow() public noGasMetering {
        aave_setTwyneLiqLTVNoBorrow(address(aWETHWrapper));
    }

    function testFuzz_aave_setTwyneLiqLTVNoBorrow(address collateralAssets) public noGasMetering {
        aave_setTwyneLiqLTVNoBorrow(collateralAssets);
    }

    // user sets their custom LTV after borrowing
    function test_aave_setTwyneLiqLTVWithBorrow() public noGasMetering {
        aave_setTwyneLiqLTVWithBorrow(address(aWETHWrapper));
    }

    function testFuzz_aave_setTwyneLiqLTVWithBorrow(address collateralAssets) public noGasMetering {
        aave_setTwyneLiqLTVWithBorrow(collateralAssets);
    }

    function test_aave_IRMTwyneCurve_nonLinearPoint() public noGasMetering {
        IRMTwyneCurve irm = new IRMTwyneCurve({
            minInterest_: 0,
            linearParameter_: 750,
            polynomialParameter_: 49250,
            nonlinearPoint_: 5e17
        });

        uint utilization = irm.nonlinearPoint() - 1;
        uint linearParameter = irm.linearParameter();
        uint polynomialParameter = irm.polynomialParameter();
        uint SECONDS_PER_YEAR =  365.2425 * 86400;

        uint totalAssets = 1e36;
        uint borrows = utilization * totalAssets / 1e18;
        uint ir = irm.computeInterestRateView(address(0), totalAssets - borrows, borrows);

        assertEq(ir, linearParameter * utilization * 1e9 / MAXFACTOR / SECONDS_PER_YEAR);

        utilization++;
        borrows = utilization * totalAssets / 1e18;
        ir = irm.computeInterestRateView(address(0), totalAssets - borrows, borrows);
        assertEq(ir, linearParameter * utilization * 1e9 / MAXFACTOR / SECONDS_PER_YEAR);

        utilization++;
        borrows = utilization * totalAssets / 1e18;
        ir = irm.computeInterestRateView(address(0), totalAssets - borrows, borrows);

        uint utilTemp4 = (utilization * utilization) / 1e18;
        // utilization^4
        utilTemp4 = (utilTemp4 * utilTemp4) / 1e18;
        // utilization^8
        uint utilpow = (utilTemp4 * utilTemp4) / 1e18;
        // utilization^12
        utilpow = (utilpow * utilTemp4) / 1e18;

        uint ir_expected = ((linearParameter * utilization) + (polynomialParameter * utilpow)) * (1e9 / MAXFACTOR);
        ir_expected /= SECONDS_PER_YEAR;

        assertEq(ir, ir_expected);
    }

    function testFuzz_aave_IRMTwyneCurve(uint64 _utilization) public noGasMetering {
        // Note: only do differential fuzzing if DIFFERENTIAL_FUZZ = 1 in .env file
        // User must manually set "ffi = true" in foundry.toml for this to work
        uint differentialFuzzing = vm.envUint("DIFFERENTIAL_FUZZ");
        if (differentialFuzzing == 1) {
            vm.assume(_utilization <= 1e18);
            uint utilization = uint(_utilization);
            IRMTwyneCurve irm = new IRMTwyneCurve({
                minInterest_: 0,
                linearParameter_: 750,
                polynomialParameter_: 49250,
                nonlinearPoint_: 5e17
            });

            uint totalAssets = 1e36;
            uint borrows = utilization * totalAssets / 1e18;
            uint ir1 = irm.computeInterestRateView(address(0), totalAssets - borrows, borrows);

            // Call Python script via FFI
            string[] memory cmd = new string[](3);
            cmd[0] = "python3";
            cmd[1] = "../py-fuzz/IRMTwyneCurve.py";
            cmd[2] = vm.toString(utilization);

            bytes memory res = vm.ffi(cmd);
            uint ir2 = abi.decode(res, (uint));

            assertApproxEqRel(ir1, ir2, 3e16); // 3% margin of error
        }
    }

    // Test both direct and batch calls to depositUnderlyingToIntermediateVault
    function test_aave_depositUnderlyingToIntermediateVault() public noGasMetering {
        aave_depositUnderlyingToIntermediateVault(address(aWETHWrapper));
    }

    function testFuzz_aave_depositUnderlyingToIntermediateVault(address collateralAssets) public noGasMetering {
        aave_depositUnderlyingToIntermediateVault(collateralAssets);
    }

    // Test both direct and batch calls to depositETHToIntermediateVault
    function test_aave_depositETHToIntermediateVault() public noGasMetering {
        aave_depositETHToIntermediateVault(address(aWETHWrapper));
    }

    function testFuzz_aave_depositETHToIntermediateVault(address collateralAssets) public noGasMetering {
        aave_depositETHToIntermediateVault(collateralAssets);
    }

    // Test skim function
    function test_aave_skim() public noGasMetering {
        aave_skim(address(aWETHWrapper));
    }

    function testFuzz_aave_skim(address collateralAssets) public noGasMetering {
        aave_skim(collateralAssets);
    }

    function test_aave_borrowEmode() public noGasMetering {
        aave_borrowEmode();
    }

    function test_aave_single_flow() public noGasMetering {
        aave_single_flow();
    }

    function test_aave_multiple_flow() public noGasMetering {
        aave_flow_multiple();
    }

    // ============================================================
    // Borrow-LTV feature: maxBorrow() value correctness
    // (Twyne's maxBorrow follows spec Eq. 1, converted to target-asset units via Aave's two USD
    //  prices. These two tests validate the math with and without a governance-set borrow buffer;
    //  the behavioral suite below proves maxBorrow is the BINDING constraint on Aave, not a no-op.)
    // ============================================================

    /// @dev Independent derivation of maxBorrow (spec Eq. 1 in 1e4 space) for a freshly-deposited,
    ///      debt-free vault with ample credit, so the dynamic liqLTV_t == chosen twyneLiqLTV.
    function _expectedMaxBorrow(uint borrowBuffer) internal view returns (uint) {
        uint liqLTV_e = getLiqLTV(address(aWETHWrapper)); // Aave liquidation threshold, 1e4
        uint maxTwyneLiqLTV = twyneVaultManager.maxTwyneLTVs(address(aaveEthVault), USDC);
        uint liqLTV_t = alice_aave_vault.twyneLiqLTV(); // chosen leg binds under ample credit
        uint borrowLTV_t = liqLTV_t;
        if (liqLTV_t > liqLTV_e) {
            borrowLTV_t = liqLTV_t - Math.ceilDiv(borrowBuffer * (liqLTV_t - liqLTV_e), maxTwyneLiqLTV - liqLTV_e);
        }
        uint userCollateral = alice_aave_vault.totalAssetsDepositedOrReserved() - alice_aave_vault.maxRelease();
        uint collateralPrice = uint(aWETHWrapper.latestAnswer());
        uint targetAssetPrice = getAavePrice(USDC);
        uint tenPowAssetDecimals = 10 ** uint(aWETHWrapper.decimals());
        uint tenPowVAssetDecimals = 10 ** uint(IERC20Metadata(USDC).decimals());
        // C · borrowLTV_t converted collateral → USD → target asset.
        return borrowLTV_t * userCollateral * collateralPrice * tenPowVAssetDecimals
            / (MAXFACTOR * tenPowAssetDecimals * targetAssetPrice);
    }

    /// @dev borrowBuffer == 0 ⇒ borrowLTV_t == liqLTV_t (no ramp term). The match is exact: there
    ///      is no ceilDiv, so the 1e4-space derivation equals the contract's 1e8 cross-multiplication.
    function test_aave_maxBorrow_defaultBuffer() public noGasMetering {
        aave_createCollateralVault(address(aWETHWrapper), 0.9e4);
        aave_collateralDeposit(COLLATERAL_AMOUNT);

        assertGt(alice_aave_vault.maxBorrow(), 0, "maxBorrow should be positive after deposit");
        assertEq(alice_aave_vault.maxBorrow(), _expectedMaxBorrow(0), "maxBorrow != liqLTV_t*C at default buffer");
    }

    /// @dev A non-zero borrow buffer lowers borrowLTV_t below liqLTV_t (spec Eq. 1). The independent
    ///      1e4-space derivation matches the contract's 1e8 computation exactly.
    function test_aave_maxBorrow_withBorrowBuffer() public noGasMetering {
        aave_createCollateralVault(address(aWETHWrapper), 0.9e4);
        aave_collateralDeposit(COLLATERAL_AMOUNT);

        uint maxBorrowNoBuffer = alice_aave_vault.maxBorrow();

        vm.startPrank(admin);
        twyneVaultManager.setBorrowBuffer(address(aaveEthVault), USDC, 500);
        vm.stopPrank();

        uint maxBorrowWithBuffer = alice_aave_vault.maxBorrow();
        assertLt(maxBorrowWithBuffer, maxBorrowNoBuffer, "borrowBuffer should reduce maxBorrow");
        assertEq(maxBorrowWithBuffer, _expectedMaxBorrow(500), "maxBorrow != spec Eq. 1 with buffer");
    }

    // ============================================================
    // Borrow-LTV feature: behavioral suite (Aave x Twyne)
    // ------------------------------------------------------------
    // In production Aave enforces its NATIVE borrow LTV (maxLTV) on BORROW only; on WITHDRAW it
    // enforces only the liquidation threshold (via the health factor), NOT the borrow LTV. Twyne's
    // borrow-LTV ramp (_checkBorrowLTV, inherited from CollateralVaultBase and shared with Morpho)
    // runs in checkVaultStatus on every borrower action including withdraw, so it is what supplies
    // the borrow-LTV discipline on the withdraw side that Aave itself omits.
    //
    // TESTING SIMPLIFICATION: Aave carries two native LTVs (borrow LTV < liquidation threshold), and
    // its credit-boosted borrow capacity can sit above Twyne's maxBorrow — a crossover that depends
    // on the exact gap and would force each test to thread a capacity boundary. To test the ramp impl
    // cleanly we mock Aave's ACL admin and set WETH's borrow LTV equal to its liquidation threshold,
    // collapsing Aave to a SINGLE LTV (exactly Morpho's lltv). Under that config Twyne's maxBorrow is
    // the binding constraint for any non-zero buffer, so the suite mirrors the Morpho borrow-LTV tests
    // one-for-one. The real production config (nativeBorrowLTV < liqLTV_e) — and the withdraw gap it
    // creates — is pinned by test_aave_borrowLTV_invariants, which does NOT flatten.
    // ============================================================

    /// @dev Shared setup: flatten Aave's borrow LTV to its liquidation threshold, then vault +
    ///      governance borrow buffer + collateral deposit. Leaves the vault debt-free with maxBorrow
    ///      computed under the chosen buffer.
    function _borrowLTVSetup(uint16 liqLTV, uint16 buffer) internal {
        _flattenAaveBorrowLtv();
        aave_createCollateralVault(address(aWETHWrapper), liqLTV);
        vm.startPrank(admin);
        twyneVaultManager.setBorrowBuffer(address(aaveEthVault), USDC, buffer);
        vm.stopPrank();
        aave_collateralDeposit(COLLATERAL_AMOUNT);
    }

    /// @dev Configure WETH so its borrow LTV equals its liquidation threshold (collapsing the native
    ///      gap so Aave presents a single LTV, like Morpho). Pranks Aave's ACL admin, which holds the
    ///      pool-admin role on this fork; the configurator address is hoisted before the prank because
    ///      vm.prank applies to only the next single call. See the suite header for rationale.
    function _flattenAaveBorrowLtv() internal {
        address underlying = aWETHWrapper.asset();
        (, , uint liqThreshold, uint liqBonus, , , , , , ) =
            aaveDataProvider.getReserveConfigurationData(underlying);
        IAaveV3AddressProvider ap = IAaveV3Pool(aavePool).ADDRESSES_PROVIDER();
        address configurator = ap.getPoolConfigurator();
        vm.prank(ap.getACLAdmin());
        IPoolConfigurator(configurator).configureReserveAsCollateral(
            underlying, liqThreshold, liqThreshold, liqBonus
        );
    }

    /// @dev Spec Eq. 1 maxBorrow (USDC) for an arbitrary (liqLTV_t, buffer), independent of the
    ///      vault's currently-applied twyneLiqLTV. Used where the test reasons about a not-yet-applied
    ///      twyneLiqLTV (e.g. the lower value in borrowRampBlocksLiqLTVDecrease).
    function _expectedMaxBorrowAt(uint liqLTV_t, uint buffer) internal view returns (uint) {
        uint liqLTV_e = getLiqLTV(address(aWETHWrapper));
        uint maxTwyneLiqLTV = twyneVaultManager.maxTwyneLTVs(address(aaveEthVault), USDC);
        uint borrowLTV_t = liqLTV_t;
        if (liqLTV_t > liqLTV_e) {
            borrowLTV_t = liqLTV_t - Math.ceilDiv(buffer * (liqLTV_t - liqLTV_e), maxTwyneLiqLTV - liqLTV_e);
        }
        uint userCollateral = alice_aave_vault.totalAssetsDepositedOrReserved() - alice_aave_vault.maxRelease();
        uint collateralPrice = uint(aWETHWrapper.latestAnswer());
        uint targetAssetPrice = getAavePrice(USDC);
        uint tenPowAssetDecimals = 10 ** uint(aWETHWrapper.decimals());
        uint tenPowVAssetDecimals = 10 ** uint(IERC20Metadata(USDC).decimals());
        return borrowLTV_t * userCollateral * collateralPrice * tenPowVAssetDecimals
            / (MAXFACTOR * tenPowAssetDecimals * targetAssetPrice);
    }

    /// @notice Two true Aave invariants that do NOT imply the ramp is a no-op. (1) Aave's native
    ///         borrow LTV is strictly below its liquidation threshold. (2) Twyne's borrowLTV_t floors
    ///         at liqLTV_e. Neither implies the ramp is a no-op: Aave's effective borrow capacity is
    ///         the CREDIT-BOOSTED (userCollateral + reservedCredit)·nativeBorrowLTV, which exceeds
    ///         maxBorrow under a non-zero buffer, so the ramp is the binding constraint (see the suite below).
    ///         This test pins the two invariants and clarifies why the ramp still binds.
    function test_aave_borrowLTV_invariants() public noGasMetering {
        aave_createCollateralVault(address(aWETHWrapper), 0.9e4);
        aave_collateralDeposit(COLLATERAL_AMOUNT);

        uint nativeBorrowLTV = getBorrowLTV(address(aWETHWrapper)); // Aave LTV, 1e4
        uint liqLTV_e = getLiqLTV(address(aWETHWrapper)); // Aave liquidation threshold, 1e4
        uint maxTwyneLiqLTV = twyneVaultManager.maxTwyneLTVs(address(aaveEthVault), USDC);

        // (1) Aave protocol invariant: native borrow LTV strictly below liquidation threshold.
        assertLt(nativeBorrowLTV, liqLTV_e, "Aave native borrow LTV must be below liq threshold");

        // (2) Spec Eq. 1 floor: at the maximum buffer, borrowLTV_t collapses to liqLTV_e.
        uint maxBuffer = maxTwyneLiqLTV - liqLTV_e - 1;
        uint liqLTV_t = alice_aave_vault.twyneLiqLTV();
        uint borrowLTV_t_floor =
            liqLTV_t - Math.ceilDiv(maxBuffer * (liqLTV_t - liqLTV_e), maxTwyneLiqLTV - liqLTV_e);
        assertEq(borrowLTV_t_floor, liqLTV_e, "borrowLTV_t must floor at liqLTV_e");

        // NOTE: liqLTV_e is a floor on borrowLTV_t, not a guarantee the ramp never binds. Aave's
        // credit boost lets the vault borrow against (userCollateral + reservedCredit), so Aave's
        // own capacity can sit above maxBorrow and the ramp engages — proven behaviorally below.
    }

    /// @notice Borrowing past maxBorrow reverts with the Twyne error. At buffer 500, maxBorrow sits
    ///         below Aave's credit-boosted capacity, so Aave would permit the extra borrow — the
    ///         revert is Twyne's _checkBorrowLTV, not Aave. (Aave analog of morpho_borrowBufferMaxBorrow.)
    function test_aave_borrowRampBlocksBorrowOverMaxBorrow() public noGasMetering {
        _borrowLTVSetup(0.9e4, 500);

        vm.startPrank(alice);
        uint maxBorrow = alice_aave_vault.maxBorrow();
        // maxBorrow-1: ~1 USDC unit of headroom for Aave variable-debt-share rounding.
        alice_aave_vault.borrow(maxBorrow - 1, alice);
        assertApproxEqAbs(alice_aave_vault.maxRepay(), maxBorrow - 1, 1, "at-maxBorrow debt mismatch");

        vm.expectRevert(TwyneErrors.T_BorrowExceedsMaxLTV.selector);
        alice_aave_vault.borrow(2, alice);
        vm.stopPrank();
    }

    /// @notice HEADLINE: Aave does not enforce its native borrow LTV on withdraw (only the liquidation
    ///         threshold via the health factor), so Aave alone would permit this collateral withdrawal
    ///         — the operating LTV stays far below the liquidation threshold. Twyne's _checkBorrowLTV
    ///         blocks it: the withdrawal lowers maxBorrow (borrowLTV_t·C) below the debt, so E1 > 0
    ///         while E0 == 0. This is the withdraw-side borrow-LTV protection that Aave itself lacks.
    ///         (Aave analog of morpho_borrowRampBlocksWithdraw.)
    function test_aave_borrowRampBlocksWithdraw() public noGasMetering {
        _borrowLTVSetup(0.9e4, 500);

        vm.startPrank(alice);
        uint maxBorrow = alice_aave_vault.maxBorrow();
        alice_aave_vault.borrow(maxBorrow - 1, alice);

        uint withdrawable = alice_aave_vault.balanceOf(address(alice_aave_vault));
        require(withdrawable > 0, "no withdrawable collateral at maxBorrow");
        // 1% of collateral: far below Aave's HF limit (so Aave permits it), but enough to drop
        // maxBorrow below the debt (so Twyne's ramp rejects it).
        vm.expectRevert(TwyneErrors.T_BorrowExceedsMaxLTV.selector);
        alice_aave_vault.withdraw(withdrawable / 100, alice);

        // redeemUnderlying (withdraw as underlying WETH) is Aave's second collateral-exit path; it
        // shares the same checkVaultStatus/_checkBorrowLTV gate, so it is blocked too.
        vm.expectRevert(TwyneErrors.T_BorrowExceedsMaxLTV.selector);
        alice_aave_vault.redeemUnderlying(withdrawable / 100, alice);
        vm.stopPrank();
    }

    /// @notice Non-degrading actions (collateral top-up, repay) are never blocked by the ramp, even
    ///         at maxBorrow — they raise maxBorrow / lower debt, shrinking the excess. (Aave analog
    ///         of morpho_borrowRampAllowsNonDegradingAtMaxBorrow.)
    function test_aave_borrowRampAllowsNonDegradingAtMaxBorrow() public noGasMetering {
        _borrowLTVSetup(0.9e4, 500);

        vm.startPrank(alice);
        uint maxBorrow = alice_aave_vault.maxBorrow();
        alice_aave_vault.borrow(maxBorrow - 1, alice);

        // Topping up collateral is health-improving (it raises maxBorrow, shrinking the excess), so
        // the ramp does not block it at maxBorrow. The deposit runs through an EVC batch so
        // checkVaultStatus — and thus _checkBorrowLTV — actually fires, proving the ramp PASSES
        // rather than being skipped. (Matches morpho_borrowRampAllowsNonDegradingAtMaxBorrow.)
        IERC20(WETH).approve(address(aWETHWrapper), type(uint).max);
        uint topUpShares = aWETHWrapper.deposit(COLLATERAL_AMOUNT / 10, alice);
        aWETHWrapper.approve(address(alice_aave_vault), topUpShares);
        IEVC.BatchItem[] memory topUp = new IEVC.BatchItem[](1);
        topUp[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.deposit, (topUpShares))
        });
        evc.batch(topUp); // succeeds — no T_BorrowExceedsMaxLTV
        assertGt(alice_aave_vault.maxBorrow(), maxBorrow, "top-up should raise maxBorrow");
        vm.stopPrank();
    }

    /// @notice Spec Eq. 1 monotonicity (k = buffer/(maxTwyne−liqLTV_e) < 1): raising twyneLiqLTV
    ///         raises maxBorrow (d borrowLTV_t/d liqLTV_t = 1−k > 0). A position borrowed to the old
    ///         maxBorrow-1 stays under the new, higher maxBorrow, so the gated setTwyneLiqLTV succeeds
    ///         and maxBorrow strictly increases. (Aave analog of morpho_borrowRampMonotonicInLiqLTV.)
    function test_aave_borrowRampMonotonicInLiqLTV() public noGasMetering {
        // buffer 500, maxTwyne 9300, liqLTV_e 8300 ⇒ k = 0.5 < 1. (Aave's borrow LTV is flattened to
        // liqLTV_e by _borrowLTVSetup, so Twyne's maxBorrow is the clean binding constraint.)
        _borrowLTVSetup(9000, 500);

        vm.startPrank(alice);
        uint maxBorrowBefore = alice_aave_vault.maxBorrow(); // 8650-leg
        alice_aave_vault.borrow(maxBorrowBefore - 1, alice);

        // 9000 → 9200 raises maxBorrow (8650-leg → 8750-leg); the position stays under it, so the
        // gated setTwyneLiqLTV succeeds and maxBorrow strictly increases.
        alice_aave_vault.setTwyneLiqLTV(9200);
        assertGt(alice_aave_vault.maxBorrow(), maxBorrowBefore, "maxBorrow should rise with twyneLiqLTV (k<1)");
        vm.stopPrank();
    }

    /// @notice Lowering twyneLiqLTV while over the new, lower maxBorrow grows the excess and reverts.
    ///         The new boundary (8550-leg at liqLTV 8800) still sits above the liquidation boundary
    ///         β·λ̃_e = 8300, so the ramp — not _canLiquidate — rejects it. Repaying within the new
    ///         maxBorrow first is the escape hatch. (Aave analog of morpho_borrowRampBlocksLiqLTVDecrease.)
    function test_aave_borrowRampBlocksLiqLTVDecrease() public noGasMetering {
        _borrowLTVSetup(9000, 500);

        vm.startPrank(alice);
        uint maxBorrowBefore = alice_aave_vault.maxBorrow(); // 8650-leg
        alice_aave_vault.borrow(maxBorrowBefore - 1, alice);

        // 9000 → 8800 drops maxBorrow to the 8550-leg while debt is unchanged: excess grows → revert.
        vm.expectRevert(TwyneErrors.T_BorrowExceedsMaxLTV.selector);
        alice_aave_vault.setTwyneLiqLTV(8800);

        // Escape hatch: repay within the new maxBorrow, then the same decrease succeeds.
        uint newLimit = _expectedMaxBorrowAt(8800, 500);
        IERC20(USDC).approve(address(alice_aave_vault), type(uint256).max);
        uint debt = alice_aave_vault.maxRepay();
        require(debt > newLimit, "precond: debt should exceed the new, lower maxBorrow");
        alice_aave_vault.repay(debt - newLimit + 1e6); // +1 USDC margin for Aave repay rounding

        alice_aave_vault.setTwyneLiqLTV(8800); // succeeds — excess is 0 at the new, lower maxBorrow
        assertEq(alice_aave_vault.twyneLiqLTV(), 8800, "liqLTV decrease should apply once within maxBorrow");
        assertEq(alice_aave_vault.maxBorrow(), newLimit, "maxBorrow != spec value at 8800");
        vm.stopPrank();
    }

    /// @notice A position driven over maxBorrow by a governance buffer raise (not by a vault action)
    ///         may be repaid or topped up — the excess shrinks — but not degraded by a new borrow.
    ///         (Aave analog of morpho_borrowRampOverMaxBorrowAllowsRepay.)
    function test_aave_borrowRampOverMaxBorrowAllowsRepay() public noGasMetering {
        _borrowLTVSetup(9000, 500);

        vm.startPrank(alice);
        uint maxBorrow = alice_aave_vault.maxBorrow();
        alice_aave_vault.borrow(maxBorrow - 1, alice);
        vm.stopPrank();

        // Governance raises the buffer: no vault action, no status check, so the transient excess
        // snapshot stays 0. The position is now over maxBorrow (8650-leg → 8440-leg).
        vm.startPrank(admin);
        twyneVaultManager.setBorrowBuffer(address(aaveEthVault), USDC, 800);
        vm.stopPrank();

        uint debt = alice_aave_vault.maxRepay();
        assertGt(debt, alice_aave_vault.maxBorrow(), "precond: position should be over maxBorrow");

        vm.startPrank(alice);
        // A new borrow grows the excess past the batch-start snapshot → reverts.
        vm.expectRevert(TwyneErrors.T_BorrowExceedsMaxLTV.selector);
        alice_aave_vault.borrow(1, alice);

        // Repay shrinks the excess → passes.
        IERC20(USDC).approve(address(alice_aave_vault), type(uint256).max);
        alice_aave_vault.repay(debt / 4);
        assertLt(alice_aave_vault.maxRepay(), debt, "repay should reduce debt");

        // Top up collateral raises maxBorrow, shrinking the excess → passes.
        aave_collateralDeposit(COLLATERAL_AMOUNT / 10);
        vm.stopPrank();
    }

    /// @notice An over-maxBorrow position must NOT be able to LEVERAGE UP — take a new borrow
    ///         alongside a proportional deposit in one batch — even though the excess-per-collateral
    ///         ratio alone reports "improving". The absolute-debt cap (maxRepay₁ ≤ maxRepay₀ for
    ///         E0 > 0) blocks it; amelioration (a plain top-up) still passes.
    ///         (Aave analog of morpho_borrowRampOverMaxBorrowBlocksLeverage.)
    function test_aave_borrowRampOverMaxBorrowBlocksLeverage() public noGasMetering {
        _borrowLTVSetup(9000, 500);

        vm.startPrank(alice);
        uint maxBorrow = alice_aave_vault.maxBorrow();
        alice_aave_vault.borrow(maxBorrow - 1, alice);
        vm.stopPrank();

        vm.startPrank(admin);
        twyneVaultManager.setBorrowBuffer(address(aaveEthVault), USDC, 800);
        vm.stopPrank();

        uint debt0 = alice_aave_vault.maxRepay();
        uint borrowLimit = alice_aave_vault.maxBorrow();
        uint userCollateral = alice_aave_vault.totalAssetsDepositedOrReserved() - alice_aave_vault.maxRelease();
        require(debt0 > borrowLimit, "precond: position should be over maxBorrow");

        // The leverage attempt: deposit dC (wrapper shares), then borrow dB at the lower slope. The
        // ratio metric alone would accept it (E1·C0 ≤ E0·C1); the absolute-debt cap rejects it.
        uint dC = COLLATERAL_AMOUNT / 10;
        uint dB = borrowLimit * dC / userCollateral;
        dB -= 1e6; // margin: keep E strictly non-growing through Aave debt-share rounding

        // Fund the leverage deposit: wrap WETH → wrapper shares for alice.
        vm.startPrank(alice);
        IERC20(WETH).approve(address(aWETHWrapper), type(uint).max);
        uint depositShares = aWETHWrapper.deposit(dC, alice);
        aWETHWrapper.approve(address(alice_aave_vault), depositShares);

        IEVC.BatchItem[] memory lev = new IEVC.BatchItem[](2);
        lev[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.deposit, (depositShares))
        });
        lev[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.borrow, (dB, alice))
        });
        vm.expectRevert(TwyneErrors.T_BorrowExceedsMaxLTV.selector);
        evc.batch(lev);

        // Amelioration still works on the same over-maxBorrow position: a plain top-up (debt flat).
        aave_collateralDeposit(COLLATERAL_AMOUNT / 10);
        assertEq(alice_aave_vault.maxRepay(), debt0, "top-up must not change debt");
        vm.stopPrank();
    }

    /// @notice Interest accrual can push a healthy position over maxBorrow with no vault action. Aave
    ///         accrues its variable debt lazily (the debt-token balance is stale until a borrow/repay
    ///         triggers accrueInterest), so the next action's snapshot sees the STALE pre-accrual debt
    ///         (E0 == 0). A borrow then realizes the accrual and checkVaultStatus sees E1 > 0 → blocked.
    ///         This is a different _checkBorrowLTV branch than Morpho (whose maxRepay is accrual-aware,
    ///         E0 > 0); both block the borrow. The over-maxBorrow state comes purely from debt growth.
    function test_aave_borrowRampAccrualOverMaxBorrow() public noGasMetering {
        // maxTwyne (9300) + max buffer (999): maxBorrow floors at liqLTV_e (8300-leg), far below the
        // 9300-leg liquidation point, giving interest a wide window to grow debt past maxBorrow.
        _borrowLTVSetup(9300, 999);

        vm.startPrank(alice);
        uint maxBorrow = alice_aave_vault.maxBorrow();
        // Borrow to maxBorrow − 1 (right at the limit). A +1 borrow would succeed with no accrual;
        // the over-maxBorrow state below comes purely from interest.
        alice_aave_vault.borrow(maxBorrow - 1, alice);
        vm.stopPrank();

        // Warp: Aave variable debt accrues. The debt-token balance is stale until the borrow below
        // triggers accrueInterest.
        vm.warp(block.timestamp + 365 days);

        vm.startPrank(alice);
        // A +1 borrow that would succeed with no accrual now reverts: the borrow triggers
        // accrueInterest (debt jumps past maxBorrow) and checkVaultStatus sees E1 > 0 with E0 == 0
        // (stale snapshot) → T_BorrowExceedsMaxLTV.
        vm.expectRevert(TwyneErrors.T_BorrowExceedsMaxLTV.selector);
        alice_aave_vault.borrow(1, alice);

        // Amelioration: a repay large enough to cover the accrued excess brings debt back under
        // maxBorrow (E0 == 0 stale branch requires E1 == 0). Repaying half the (stale) debt is ample.
        IERC20(USDC).approve(address(alice_aave_vault), type(uint256).max);
        alice_aave_vault.repay(alice_aave_vault.maxRepay() / 2);
        assertLt(alice_aave_vault.maxRepay(), maxBorrow, "debt should be back under maxBorrow after repay");
        vm.stopPrank();
    }

    /// @notice The enforced metric is excess-per-collateral, not absolute excess. An over-maxBorrow
    ///         position that repays dB and withdraws dC in ONE batch — holding the absolute excess
    ///         flat (or even shrinking it) while operating LTV rises — must still revert: E1·C0 >
    ///         E0·C1 because collateral fell. (Aave analog of morpho_borrowRampBlocksRepayAndWithdraw.)
    function test_aave_borrowRampBlocksRepayAndWithdraw() public noGasMetering {
        _borrowLTVSetup(9000, 500);

        vm.startPrank(alice);
        uint maxBorrow = alice_aave_vault.maxBorrow();
        alice_aave_vault.borrow(maxBorrow - 1, alice);
        vm.stopPrank();

        vm.startPrank(admin);
        twyneVaultManager.setBorrowBuffer(address(aaveEthVault), USDC, 800);
        vm.stopPrank();

        uint debt = alice_aave_vault.maxRepay();
        uint borrowLimit = alice_aave_vault.maxBorrow();
        uint userCollateral = alice_aave_vault.totalAssetsDepositedOrReserved() - alice_aave_vault.maxRelease();
        require(debt > borrowLimit, "precond: position should be over maxBorrow");

        // Pair a repay with a withdrawal: dB = borrowLimit·dC/C (+margin so the absolute excess
        // strictly shrinks). That holds the absolute excess flat-or-down, but the excess-per-
        // collateral ratio rises because collateral fell — so the ratio check reverts. dB is in
        // USDC, dC in wrapper shares; maxBorrow is linear in collateral, so the ratio holds across
        // Aave's unit conversion.
        uint dC = COLLATERAL_AMOUNT / 10;
        uint dB = borrowLimit * dC / userCollateral + 1e6;

        vm.startPrank(alice);
        IERC20(USDC).approve(address(alice_aave_vault), type(uint256).max);
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.repay, (dB))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.withdraw, (dC, alice))
        });
        vm.expectRevert(TwyneErrors.T_BorrowExceedsMaxLTV.selector);
        evc.batch(items);
        vm.stopPrank();
    }
}
