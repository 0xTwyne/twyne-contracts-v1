// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {EulerTestBase} from "./EulerTestBase.t.sol";
import {IRMTwyneCurve} from "src/twyne/IRMTwyneCurve.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";

contract EulerTestNormalActions is EulerTestBase {
    function setUp() public virtual override {
        super.setUp();
    }

    // non-fuzzing unit test for single collateral
    function test_e_creditDeposit() public noGasMetering {
        e_creditDeposit(eulerWETH);
    }

    // fuzzing entry point for all assets
    function testFuzz_e_creditDeposit(address collateralAssets) public noGasMetering {
        e_creditDeposit(collateralAssets);
    }

    // non-fuzzing unit test for single collateral
    function test_e_createWETHCollateralVault() public noGasMetering {
        e_createCollateralVault(eulerWETH);
    }

    // fuzzing entry point for all assets
    function testFuzz_e_createCollateralVault(address collateralAssets) public noGasMetering {
        e_createCollateralVault(collateralAssets);
    }

    // non-fuzzing unit test for single collateral
    function test_e_totalAssetsIntermediateVault() public noGasMetering {
        e_totalAssetsIntermediateVault(eulerWETH);
    }

    // fuzzing entry point for all assets
    function testFuzz_e_totalAssetsIntermediateVault(address collateralAssets) public noGasMetering {
        e_totalAssetsIntermediateVault(collateralAssets);
    }

    // non-fuzzing unit test for single collateral
    function test_e_totalAssetsCollateralVault() public noGasMetering {
        e_totalAssetsCollateralVault(eulerWETH);
    }

    // fuzzing entry point for all assets
    function testFuzz_e_totalAssetsCollateralVault(address collateralAssets) public noGasMetering {
        e_totalAssetsCollateralVault(collateralAssets);
    }

    // non-fuzzing unit test for single collateral
    function test_e_supplyCap_creditDeposit() public noGasMetering {
        e_supplyCap_creditDeposit(eulerWETH);
    }

    // fuzzing entry point for all assets
    function testFuzz_e_supplyCap_creditDeposit(address collateralAssets) public noGasMetering {
        e_supplyCap_creditDeposit(collateralAssets);
    }

    // non-fuzzing unit test for single collateral
    function test_e_second_creditDeposit() public noGasMetering {
        e_second_creditDeposit(eulerWETH);
    }

    // fuzzing entry point for all assets
    function testFuzz_e_second_creditDeposit(address collateralAssets) public noGasMetering {
        e_second_creditDeposit(collateralAssets);
    }

    // non-fuzzing unit test for single collateral
    function test_e_creditWithdrawNoInterest() public noGasMetering {
        e_creditWithdrawNoInterest(eulerWETH);
    }

    // fuzzing entry point for all assets
    function testFuzz_e_creditWithdrawNoInterest(address collateralAssets) public noGasMetering {
        e_creditWithdrawNoInterest(collateralAssets);
    }

    // non-fuzzing unit test for single collateral
    function test_e_collateralDepositWithoutBorrow() public noGasMetering {
        e_collateralDepositWithoutBorrow(eulerWETH);
    }

    // fuzzing entry point for all assets
    function testFuzz_e_collateralDepositWithoutBorrow(address collateralAssets) public noGasMetering {
        e_collateralDepositWithoutBorrow(collateralAssets);
    }

    function test_e_creditWithdrawWithInterestAndNoFees() public noGasMetering {
        e_creditWithdrawWithInterestAndNoFees(eulerWETH, 1000);
    }

    // fuzzing entry point for all assets
    function testFuzz_e_creditWithdrawWithInterestAndNoFees(address collateralAssets, uint warpBlockAmount) public noGasMetering {
        e_creditWithdrawWithInterestAndNoFees(eulerWETH, warpBlockAmount); // TODO
    }

    function test_e_creditWithdrawWithInterestAndFees() public noGasMetering {
        e_creditWithdrawWithInterestAndFees(eulerWETH);
    }

    function testFuzz_e_creditWithdrawWithInterestAndFees(address collateralAssets) public noGasMetering {
        e_creditWithdrawWithInterestAndFees(eulerWETH); // TODO
    }

    // Test the case of C_LP = 0 (no reserved assets) with non-zero C and B
    // This should be identical to using the underlying protocol without Twyne
    function test_e_collateralDepositWithBorrow() public noGasMetering {
        e_collateralDepositWithBorrow(eulerWETH);
    }

    function testFuzz_e_collateralDepositWithBorrow(address collateralAssets) public noGasMetering {
        e_collateralDepositWithBorrow(collateralAssets);
    }

    // Deposit WETH instead of eWETH into Twyne
    // This allows users to bypass the Euler Finance frontend entirely
    function test_e_collateralDepositUnderlying() public noGasMetering {
        e_collateralDepositUnderlying(eulerWETH);
    }

    function testFuzz_e_collateralDepositUnderlying(address collateralAssets) public noGasMetering {
        e_collateralDepositUnderlying(collateralAssets);
    }

    // Test Permit2 deposit of eWETH (not WETH)
    function test_e_permit2CollateralDeposit() public noGasMetering {
        e_permit2CollateralDeposit(eulerWETH);
    }

    function testFuzz_e_permit2CollateralDeposit(address collateralAssets) public noGasMetering {
        e_permit2CollateralDeposit(collateralAssets);
    }

    // Test Permit2 deposit of WETH (not eWETH)
    function test_e_permit2_CollateralDepositUnderlying() public noGasMetering {
        e_permit2_CollateralDepositUnderlying(eulerWETH);
    }

    function testFuzz_e_permit2_CollateralDepositUnderlying(address collateralAssets) public noGasMetering {
        e_permit2_CollateralDepositUnderlying(collateralAssets);
    }

    // Test the creation of a collateral vault in a batch (the frontend does this)
    function test_e_evcCanCreateCollateralVault() public noGasMetering {
        e_evcCanCreateCollateralVault(eulerWETH);
    }

    function testFuzz_e_evcCanCreateCollateralVault(address collateralAssets) public noGasMetering {
        e_evcCanCreateCollateralVault(collateralAssets);
    }

    // Test that if time passes, the balance of aTokens in the collateral vault increases and the user can withdraw all
    function test_e_withdrawCollateralAfterWarp() public noGasMetering {
        e_withdrawCollateralAfterWarp(eulerWETH, 1000);
    }

    // fuzzing entry point for all assets and different warp periods
    function testFuzz_e_withdrawCollateralAfterWarp(address collateralAssets, uint warpBlockAmount) public noGasMetering {
        e_withdrawCollateralAfterWarp(collateralAssets, warpBlockAmount);
    }

    // Test the user withdrawing WETH from the collateral vault
    function test_e_redeemUnderlying() public noGasMetering {
        e_redeemUnderlying(eulerWETH);
    }

    function testFuzz_e_redeemUnderlying(address collateralAssets) public noGasMetering {
        e_redeemUnderlying(collateralAssets);
    }

    function test_e_firstBorrowFromEulerDirect() public noGasMetering {
        e_firstBorrowFromEulerDirect(eulerWETH);
    }

    function testFuzz_e_firstBorrowFromEulerDirect(address collateralAssets) public noGasMetering {
        e_firstBorrowFromEulerDirect(collateralAssets);
    }

    function test_e_firstBorrowFromEulerViaCollateral() public noGasMetering {
        e_firstBorrowFromEulerViaCollateral(eulerWETH);
    }

    function testFuzz_e_firstBorrowFromEulerViaCollateral(address collateralAssets) public noGasMetering {
        e_firstBorrowFromEulerViaCollateral(collateralAssets);
    }

    // Separate the checks that are run after the borrow operation so that they are only run once
    // instead of running on every test that runs the borrow test first
    function test_e_postBorrowChecks() public {
        e_postBorrowChecks(eulerWETH);
    }

    function testFuzz_e_postBorrowChecks(address collateralAssets) public {
        e_postBorrowChecks(collateralAssets);
    }

    // Try max borrowing from the external protocol
    // This imitates the frontend
    function test_e_maxBorrowFromEulerDirect() public noGasMetering {
        e_maxBorrowFromEulerDirect(eulerWETH, 1e4);
    }

    // fuzzing entry point for all assets and different warp periods
    function testFuzz_e_maxBorrowFromEulerDirect(address collateralAssets, uint16 collateralMultiplier) public noGasMetering {
        e_maxBorrowFromEulerDirect(eulerWETH, collateralMultiplier); // TODO
    }

    // User wishes to close their collateral vault position by repaying all and withdrawing all
    function test_e_repayWithdrawAll() public noGasMetering {
        e_repayWithdrawAll(eulerWETH);
    }

    // fuzzing entry point for all assets and different warp periods
    function testFuzz_e_repayWithdrawAll(address collateralAssets) public noGasMetering {
        e_repayWithdrawAll(collateralAssets);
    }

    // User Permit2 to repay all
    function test_e_permit2FirstRepay() public noGasMetering {
        e_permit2FirstRepay(eulerWETH);
    }

    function testFuzz_e_permit2FirstRepay(address collateralAssets) public noGasMetering {
        e_permit2FirstRepay(collateralAssets);
    }

    function test_e_interestAccrualThenRepay() external noGasMetering {
        e_interestAccrualThenRepay(eulerWETH);
    }

    function testFuzz_e_interestAccrualThenRepay(address collateralAssets) external noGasMetering {
        e_interestAccrualThenRepay(collateralAssets);
    }

    function test_e_secondBorrow() public noGasMetering {
        e_secondBorrow(eulerWETH);
    }

    function testFuzz_e_secondBorrow(address collateralAssets) public noGasMetering {
        e_secondBorrow(collateralAssets);
    }

    // user sets their custom LTV before borrowing
    function test_e_setTwyneLiqLTVNoBorrow() public noGasMetering {
        e_setTwyneLiqLTVNoBorrow(eulerWETH);
    }

    function testFuzz_e_setTwyneLiqLTVNoBorrow(address collateralAssets) public noGasMetering {
        e_setTwyneLiqLTVNoBorrow(collateralAssets);
    }

    // user sets their custom LTV after borrowing
    function test_e_setTwyneLiqLTVWithBorrow() public noGasMetering {
        e_setTwyneLiqLTVWithBorrow(eulerWETH);
    }

    function testFuzz_e_setTwyneLiqLTVWithBorrow(address collateralAssets) public noGasMetering {
        e_setTwyneLiqLTVWithBorrow(collateralAssets);
    }

    function test_e_teleportEulerPosition() public noGasMetering {
        e_teleportEulerPosition(eulerWETH);
    }

    function testFuzz_e_teleportEulerPosition(address collateralAssets) public noGasMetering {
        e_teleportEulerPosition(eulerWETH); // TODO
    }

    function test_e_IRMTwyneCurve_nonLinearPoint() public noGasMetering {
        IRMTwyneCurve irm = new IRMTwyneCurve({
            idealKinkInterestRate_: 600, // 6%
            linearKinkUtilizationRate_: 8000, // 80%
            maxInterestRate_: 50000, // 500%
            nonlinearPoint_: 5e17 // 50%
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

    function testFuzz_e_IRMTwyneCurve(uint64 _utilization) public noGasMetering {
        // Note: only do differential fuzzing if DIFFERENTIAL_FUZZ = 1 in .env file
        // User must manually set "ffi = true" in foundry.toml for this to work
        uint differentialFuzzing = vm.envUint("DIFFERENTIAL_FUZZ");
        if (differentialFuzzing == 1) {
            vm.assume(_utilization <= 1e18);
            uint utilization = uint(_utilization);
            IRMTwyneCurve irm = new IRMTwyneCurve({
                idealKinkInterestRate_: 600, // 6%
                linearKinkUtilizationRate_: 8000, // 80%
                maxInterestRate_: 50000, // 500%
                nonlinearPoint_: 5e17 // 50%
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
}
