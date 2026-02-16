// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {AaveTestBase} from "./AaveTestBase.t.sol";
import {IRMTwyneCurve} from "src/twyne/IRMTwyneCurve.sol";
import {ReferenceEulerWrapper} from "test/mocks/ReferenceEulerWrapper.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {AaveV3LeverageOperator} from "src/operators/AaveV3LeverageOperator.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {AaveV3DeleverageOperator} from "src/operators/AaveV3DeleverageOperator.sol";
import {AaveV3CollateralVault} from "src/twyne/AaveV3CollateralVault.sol";
import {VaultType} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {MockSwapper} from "test/mocks/MockSwapper.sol";
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
        aave_creditWithdrawWithInterestAndNoFees(address(aWETHWrapper), 1000);
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

    // Deposit WETH instead of eWETH into Twyne
    // This allows users to bypass the Euler Finance frontend entirely
    function test_aave_collateralDepositUnderlying() public noGasMetering {
        aave_collateralDepositUnderlying(address(aWETHWrapper));
    }

    function testFuzz_aave_collateralDepositUnderlying(address collateralAssets) public noGasMetering {
        aave_collateralDepositUnderlying(collateralAssets);
    }

    // Test Permit2 deposit of eWETH (not WETH)
    function test_aave_permit2CollateralDeposit() public noGasMetering {
        aave_permit2CollateralDeposit(address(aWETHWrapper));
    }

    function testFuzz_aave_permit2CollateralDeposit(address collateralAssets) public noGasMetering {
        aave_permit2CollateralDeposit(collateralAssets);
    }

    // Test Permit2 deposit of WETH (not eWETH)
    function test_aave_permit2_CollateralDepositUnderlying() public noGasMetering {
        aave_permit2_CollateralDepositUnderlying(address(aWETHWrapper));
    }

    function testFuzz_aave_permit2_CollateralDepositUnderlying(address collateralAssets) public noGasMetering {
        aave_permit2_CollateralDepositUnderlying(collateralAssets);
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
        aave_withdrawCollateralAfterWarp(address(aWETHWrapper), 1000);
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

    function testFuzz_aave_IRMTwyneCurve(uint64 _utilization) public noGasMetering {
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
}
