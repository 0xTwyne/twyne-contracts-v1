// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {EulerTestBase} from "./EulerTestBase.t.sol";
import {IRMTwyneCurve} from "src/twyne/IRMTwyneCurve.sol";
import {ReferenceEulerWrapper} from "test/mocks/ReferenceEulerWrapper.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

contract EulerTestNormalActions is EulerTestBase {
    function setUp() public virtual override {
        super.setUp();
    }

    // non-fuzzing unit test for single collateral
    function test_e_creditDeposit() public noGasMetering {
        e_creditDeposit(eulerYzPP);
    }

    // fuzzing entry point for all assets
    function testFuzz_e_creditDeposit(address /*collateralAssets*/) public noGasMetering {
        e_creditDeposit(eulerYzPP);
    }

    // non-fuzzing unit test for single collateral
    function test_e_createYzPPCollateralVault() public noGasMetering {
        e_createCollateralVault(eulerYzPP, 0.9e4);
    }

    // fuzzing entry point for all assets
    function testFuzz_e_createCollateralVault(address /*collateralAssets*/, uint16 liqLTV) public noGasMetering {
        e_createCollateralVault(eulerYzPP, liqLTV);
    }

    // non-fuzzing unit test for single collateral
    function test_e_totalAssetsIntermediateVault() public noGasMetering {
        e_totalAssetsIntermediateVault(eulerYzPP, 0.9e4);
    }

    // fuzzing entry point for all assets
    function testFuzz_e_totalAssetsIntermediateVault(address /*collateralAssets*/, uint16 liqLTV) public noGasMetering {
        e_totalAssetsIntermediateVault(eulerYzPP, liqLTV);
    }

    // non-fuzzing unit test for single collateral
    function test_e_totalAssetsCollateralVault() public noGasMetering {
        e_totalAssetsCollateralVault(eulerYzPP, 0.9e4);
    }

    // fuzzing entry point for all assets
    function testFuzz_e_totalAssetsCollateralVault(address /*collateralAssets*/,uint16 liqLTV) public noGasMetering {
        e_totalAssetsCollateralVault(eulerYzPP, liqLTV);
    }

    // non-fuzzing unit test for single collateral
    function test_e_supplyCap_creditDeposit() public noGasMetering {
        e_supplyCap_creditDeposit(eulerYzPP);
    }

    // non-fuzzing unit test for single collateral
    function test_e_second_creditDeposit() public noGasMetering {
        e_second_creditDeposit(eulerYzPP);
    }

    // non-fuzzing unit test for single collateral
    function test_e_creditWithdrawNoInterest() public noGasMetering {
        e_creditWithdrawNoInterest(eulerYzPP);
    }

    // non-fuzzing unit test for single collateral
    function test_e_collateralDepositWithoutBorrow() public noGasMetering {
        e_collateralDepositWithoutBorrow(eulerYzPP, 0.9e4);
    }

    // fuzzing entry point for all assets
    function testFuzz_e_collateralDepositWithoutBorrow(address /*collateralAssets*/,uint16 liqLTV) public noGasMetering {
        e_collateralDepositWithoutBorrow(eulerYzPP, liqLTV);
    }

    function test_e_creditWithdrawWithInterestAndNoFees() public noGasMetering {
        e_creditWithdrawWithInterestAndNoFees(eulerYzPP, 1000);
    }

    // fuzzing entry point for all assets
    function testFuzz_e_creditWithdrawWithInterestAndNoFees(address /* collateralAssets */, uint warpBlockAmount) public noGasMetering {
        e_creditWithdrawWithInterestAndNoFees(eulerYzPP, warpBlockAmount); // TODO
    }

    function test_e_creditWithdrawWithInterestAndFees() public noGasMetering {
        e_creditWithdrawWithInterestAndFees(eulerYzPP);
    }

    function testFuzz_e_creditWithdrawWithInterestAndFees(address /* collateralAssets */) public noGasMetering {
        e_creditWithdrawWithInterestAndFees(eulerYzPP); // TODO
    }

    // Test the case of C_LP = 0 (no reserved assets) with non-zero C and B
    // This should be identical to using the underlying protocol without Twyne
    function test_e_collateralDepositWithBorrow() public noGasMetering {
        e_collateralDepositWithBorrow(eulerYzPP);
    }

    function testFuzz_e_collateralDepositWithBorrow(address /*collateralAssets*/) public noGasMetering {
        e_collateralDepositWithBorrow(eulerYzPP);
    }

    // Deposit YzPP instead of eYzPP into Twyne
    // This allows users to bypass the Euler Finance frontend entirely
    function test_e_collateralDepositUnderlying() public noGasMetering {
        e_collateralDepositUnderlying(eulerYzPP);
    }

    function testFuzz_e_collateralDepositUnderlying(address /*collateralAssets*/) public noGasMetering {
        e_collateralDepositUnderlying(eulerYzPP);
    }

    // Test Permit2 deposit of eYzPP (not YzPP)
    function test_e_permit2CollateralDeposit() public noGasMetering {
        e_permit2CollateralDeposit(eulerYzPP);
    }

    function testFuzz_e_permit2CollateralDeposit(address /*collateralAssets*/) public noGasMetering {
        e_permit2CollateralDeposit(eulerYzPP);
    }

    // Test Permit2 deposit of YzPP (not eYzPP)
    function test_e_permit2_CollateralDepositUnderlying() public noGasMetering {
        e_permit2_CollateralDepositUnderlying(eulerYzPP);
    }

    function testFuzz_e_permit2_CollateralDepositUnderlying(address /*collateralAssets*/) public noGasMetering {
        e_permit2_CollateralDepositUnderlying(eulerYzPP);
    }

    // Test the creation of a collateral vault in a batch (the frontend does this)
    function test_e_evcCanCreateCollateralVault() public noGasMetering {
        e_evcCanCreateCollateralVault(eulerYzPP);
    }

    function testFuzz_e_evcCanCreateCollateralVault(address /*collateralAssets*/) public noGasMetering {
        e_evcCanCreateCollateralVault(eulerYzPP);
    }

    // Test that if time passes, the balance of aTokens in the collateral vault increases and the user can withdraw all
    function test_e_withdrawCollateralAfterWarp() public noGasMetering {
        e_withdrawCollateralAfterWarp(eulerYzPP, 1000);
    }

    // fuzzing entry point for all assets and different warp periods
    function testFuzz_e_withdrawCollateralAfterWarp(address /*collateralAssets*/,uint warpBlockAmount) public noGasMetering {
        e_withdrawCollateralAfterWarp(eulerYzPP, warpBlockAmount);
    }

    // Test the user withdrawing YzPP from the collateral vault
    function test_e_redeemUnderlying() public noGasMetering {
        e_redeemUnderlying(eulerYzPP);
    }

    function testFuzz_e_redeemUnderlying(address /*collateralAssets*/) public noGasMetering {
        e_redeemUnderlying(eulerYzPP);
    }

    function test_e_firstBorrowFromEulerDirect() public noGasMetering {
        e_firstBorrowFromEulerDirect(eulerYzPP);
    }

    function testFuzz_e_firstBorrowFromEulerDirect(address /*collateralAssets*/) public noGasMetering {
        e_firstBorrowFromEulerDirect(eulerYzPP);
    }

    function test_e_firstBorrowFromEulerViaCollateral() public noGasMetering {
        e_firstBorrowFromEulerViaCollateral(eulerYzPP);
    }

    function testFuzz_e_firstBorrowFromEulerViaCollateral(address /*collateralAssets*/) public noGasMetering {
        e_firstBorrowFromEulerViaCollateral(eulerYzPP);
    }

    // Separate the checks that are run after the borrow operation so that they are only run once
    // instead of running on every test that runs the borrow test first
    function test_e_postBorrowChecks() public {
        e_postBorrowChecks(eulerYzPP);
    }

    function testFuzz_e_postBorrowChecks(address /*collateralAssets*/) public {
        e_postBorrowChecks(eulerYzPP);
    }

    // Try max borrowing from the external protocol
    // This imitates the frontend
    function test_e_maxBorrowFromEulerDirect() public noGasMetering {
        e_maxBorrowFromEulerDirect(eulerYzPP, 1e4);
    }

    // fuzzing entry point for all assets and different warp periods
    function testFuzz_e_maxBorrowFromEulerDirect(address /* collateralAssets */, uint16 collateralMultiplier) public noGasMetering {
        e_maxBorrowFromEulerDirect(eulerYzPP, collateralMultiplier); // TODO
    }

    // User wishes to close their collateral vault position by repaying all and withdrawing all
    function test_e_repayWithdrawAll() public noGasMetering {
        e_repayWithdrawAll(eulerYzPP);
    }

    // fuzzing entry point for all assets and different warp periods
    function testFuzz_e_repayWithdrawAll(address /*collateralAssets*/) public noGasMetering {
        e_repayWithdrawAll(eulerYzPP);
    }

    // User Permit2 to repay all
    function test_e_permit2FirstRepay() public noGasMetering {
        e_permit2FirstRepay(eulerYzPP);
    }

    function test_e_interestAccrualThenRepay() external noGasMetering {
        e_interestAccrualThenRepay(eulerYzPP);
    }

    function test_e_secondBorrow() public noGasMetering {
        e_secondBorrow(eulerYzPP);
    }

    function testFuzz_e_secondBorrow(address /*collateralAssets*/) public noGasMetering {
        e_secondBorrow(eulerYzPP);
    }

    // user sets their custom LTV before borrowing
    function test_e_setTwyneLiqLTVNoBorrow() public noGasMetering {
        e_setTwyneLiqLTVNoBorrow(eulerYzPP);
    }

    function testFuzz_e_setTwyneLiqLTVNoBorrow(address /*collateralAssets*/) public noGasMetering {
        e_setTwyneLiqLTVNoBorrow(eulerYzPP);
    }

    // user sets their custom LTV after borrowing
    function test_e_setTwyneLiqLTVWithBorrow() public noGasMetering {
        e_setTwyneLiqLTVWithBorrow(eulerYzPP);
    }

    function testFuzz_e_setTwyneLiqLTVWithBorrow(address /*collateralAssets*/) public noGasMetering {
        e_setTwyneLiqLTVWithBorrow(eulerYzPP);
    }

    function test_e_teleportEulerPosition() public noGasMetering {
        e_teleportEulerPosition(eulerYzPP);
    }

    function testFuzz_e_teleportEulerPosition(address /* collateralAssets */) public noGasMetering {
        e_teleportEulerPosition(eulerYzPP); // TODO
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

    // Test both direct and batch calls to depositUnderlyingToIntermediateVault
    function test_e_depositUnderlyingToIntermediateVault() public noGasMetering {
        e_depositUnderlyingToIntermediateVault(eulerYzPP);
    }

    function testFuzz_e_depositUnderlyingToIntermediateVault(address /*collateralAssets*/) public noGasMetering {
        e_depositUnderlyingToIntermediateVault(eulerYzPP);
    }


    // Test skim function
    function test_e_skim() public noGasMetering {
        e_skim(eulerYzPP);
    }

    function testFuzz_e_skim(address /*collateralAssets*/) public noGasMetering {
        e_skim(eulerYzPP);
    }

    // Fuzz test comparing new EulerWrapper implementation with reference (old) implementation
    function testFuzz_EulerWrapperComparison(uint256 amount) public noGasMetering {
        amount = bound(amount, 1, 10e18);

        ReferenceEulerWrapper referenceWrapper = new ReferenceEulerWrapper(address(evc), YzPP);

        address collateralAsset = eulerYzPP;
        IEVault intermediateVault = IEVault(twyneVaultManager.getIntermediateVault(collateralAsset));

        deal(YzPP, alice, amount); // Give enough for both tests

        vm.startPrank(alice);

        // Test with reference (old) implementation
        uint256 snapshot = vm.snapshot();

        // Approve reference wrapper to spend alice's tokens
        IERC20(YzPP).approve(address(referenceWrapper), amount);

        uint256 referenceResult;
        bool referenceSuccess = true;
        try referenceWrapper.depositUnderlyingToIntermediateVault(intermediateVault, amount) returns (uint256 result) {
            referenceResult = result;
        } catch {
            referenceSuccess = false;
        }

        uint256 aliceBalanceAfterReference = IERC20(YzPP).balanceOf(alice);
        uint256 aliceSharesAfterReference = intermediateVault.balanceOf(alice);

        // Revert to snapshot for new implementation test
        vm.revertTo(snapshot);

        // Test with new implementation
        IERC20(YzPP).approve(address(eulerWrapper), amount);

        uint256 newResult;
        bool newSuccess = true;
        try eulerWrapper.depositUnderlyingToIntermediateVault(intermediateVault, amount) returns (uint256 result) {
            newResult = result;
        } catch {
            newSuccess = false;
        }

        uint256 aliceBalanceAfterNew = IERC20(YzPP).balanceOf(alice);
        uint256 aliceSharesAfterNew = intermediateVault.balanceOf(alice);

        vm.stopPrank();

        // Both implementations should have same success/failure behavior
        assertEq(newSuccess, referenceSuccess, "Success/failure behavior should match");

        if (referenceSuccess && newSuccess) {
            // Compare return values
            assertEq(newResult, referenceResult, "Return values should be equal");

            // Compare user balances after operation
            assertEq(aliceBalanceAfterNew, aliceBalanceAfterReference, "User balances should be equal");
            assertEq(aliceSharesAfterNew, aliceSharesAfterReference, "User shares should be equal");
        }
    }

    // Fuzz test comparing ETH deposit functionality between implementations
    function testFuzz_EulerWrapperETHComparison(uint256 amount) public noGasMetering {
        amount = bound(amount, 1, 10 ether);

        // Deploy reference (old) implementation
        ReferenceEulerWrapper referenceWrapper = new ReferenceEulerWrapper(address(evc), YzPP);

        // Use existing eulerYzPP as collateral and get intermediate vault
        address collateralAsset = eulerYzPP;
        IEVault intermediateVault = IEVault(twyneVaultManager.getIntermediateVault(collateralAsset));

        // Give alice enough ETH for both tests
        deal(alice, amount); // Give enough ETH for both tests

        vm.startPrank(alice);

        // Test with reference (old) implementation
        uint256 snapshot = vm.snapshot();

        uint256 referenceResult;
        bool referenceSuccess = true;
        try referenceWrapper.depositETHToIntermediateVault{value: amount}(intermediateVault) returns (uint256 result) {
            referenceResult = result;
        } catch {
            referenceSuccess = false;
        }

        uint256 aliceETHBalanceAfterReference = alice.balance;
        uint256 aliceSharesAfterReference = intermediateVault.balanceOf(alice);

        // Revert to snapshot for new implementation test
        vm.revertTo(snapshot);

        // Test with new implementation
        uint256 newResult;
        bool newSuccess = true;
        try eulerWrapper.depositETHToIntermediateVault{value: amount}(intermediateVault) returns (uint256 result) {
            newResult = result;
        } catch {
            newSuccess = false;
        }

        uint256 aliceETHBalanceAfterNew = alice.balance;
        uint256 aliceSharesAfterNew = intermediateVault.balanceOf(alice);

        vm.stopPrank();

        // Both implementations should have same success/failure behavior
        assertEq(newSuccess, referenceSuccess, "ETH deposit success/failure behavior should match");

        if (referenceSuccess && newSuccess) {
            // Compare return values
            assertEq(newResult, referenceResult, "ETH deposit return values should be equal");

            // Compare user balances after operation
            assertEq(aliceETHBalanceAfterNew, aliceETHBalanceAfterReference, "Alice ETH balances should be equal");
            assertEq(aliceSharesAfterNew, aliceSharesAfterReference, "Alice shares from ETH deposit should be equal");
        }
    }
}
