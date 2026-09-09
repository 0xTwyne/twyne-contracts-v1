// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {MorphoTestBase} from "./MorphoTestBase.t.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";
import {IRMTwyneCurve} from "src/twyne/IRMTwyneCurve.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {MarketParams} from "morpho/interfaces/IMorpho.sol";
import {IMorpho} from "morpho/interfaces/IMorpho.sol";
import {MorphoLib} from "morpho/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "morpho/libraries/periphery/MorphoBalancesLib.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {MockDivergentMorphoIRM} from "test/mocks/MockDivergentMorphoIRM.sol";

contract MorphoTestNormalActions is MorphoTestBase {

    function setUp() public virtual override {
        super.setUp();
    }

    // Credit deposit tests
    function test_morpho_creditDeposit() public noGasMetering {
        morpho_creditDeposit(MO_COLLATERAL_TOKEN);
    }

    // Create collateral vault tests
    // Note: LTV must be >= morphoLTV * extLiqBuffer / 1e4 = 9650 * 10000 / 10000 = 9650
    function test_morpho_createCollateralVault() public noGasMetering {
        morpho_createCollateralVault(MO_COLLATERAL_TOKEN, twyneLiqLTV);
    }

    function testFuzz_morpho_createCollateralVault(uint16 liqLTV) public noGasMetering {
        morpho_createCollateralVault(MO_COLLATERAL_TOKEN, liqLTV);
    }

    // Total assets tests
    function test_morpho_totalAssetsIntermediateVault() public noGasMetering {
        morpho_totalAssetsIntermediateVault(MO_COLLATERAL_TOKEN, twyneLiqLTV);
    }

    function testFuzz_morpho_totalAssetsIntermediateVault(uint16 liqLTV) public noGasMetering {
        morpho_totalAssetsIntermediateVault(MO_COLLATERAL_TOKEN, liqLTV);
    }

    function test_morpho_totalAssetsCollateralVault() public noGasMetering {
        morpho_totalAssetsCollateralVault(MO_COLLATERAL_TOKEN, twyneLiqLTV);
    }

    function testFuzz_morpho_totalAssetsCollateralVault(uint16 liqLTV) public noGasMetering {
        morpho_totalAssetsCollateralVault(MO_COLLATERAL_TOKEN, liqLTV);
    }

    // Supply cap tests
    function test_morpho_supplyCap_creditDeposit() public noGasMetering {
        morpho_supplyCap_creditDeposit(MO_COLLATERAL_TOKEN);
    }

    // Second credit deposit tests
    function test_morpho_second_creditDeposit() public noGasMetering {
        morpho_second_creditDeposit(MO_COLLATERAL_TOKEN);
    }

    // Credit withdraw tests
    function test_morpho_creditWithdrawNoInterest() public noGasMetering {
        morpho_creditWithdrawNoInterest(MO_COLLATERAL_TOKEN);
    }

    // Collateral deposit without borrow tests
    function test_morpho_collateralDepositWithoutBorrow() public noGasMetering {
        morpho_collateralDepositWithoutBorrow(MO_COLLATERAL_TOKEN, twyneLiqLTV);
    }

    function testFuzz_morpho_collateralDepositWithoutBorrow(uint16 liqLTV) public noGasMetering {
        morpho_collateralDepositWithoutBorrow(MO_COLLATERAL_TOKEN, liqLTV);
    }

    // Credit withdraw with interest tests
    function test_morpho_creditWithdrawWithInterestAndNoFees() public noGasMetering {
        morpho_creditWithdrawWithInterestAndNoFees(MO_COLLATERAL_TOKEN, 1000);
    }

    function testFuzz_morpho_creditWithdrawWithInterestAndNoFees(uint warpBlockAmount) public noGasMetering {
        morpho_creditWithdrawWithInterestAndNoFees(MO_COLLATERAL_TOKEN, warpBlockAmount);
    }

    function test_morpho_creditWithdrawWithInterestAndFees() public noGasMetering {
        morpho_creditWithdrawWithInterestAndFees(MO_COLLATERAL_TOKEN);
    }

    // Collateral deposit with borrow tests
    function test_morpho_collateralDepositWithBorrow() public noGasMetering {
        morpho_collateralDepositWithBorrow(MO_COLLATERAL_TOKEN);
    }

    // Permit2 collateral deposit tests
    function test_morpho_permit2CollateralDeposit() public noGasMetering {
        morpho_permit2CollateralDeposit(MO_COLLATERAL_TOKEN);
    }

    // EVC create vault tests
    function test_morpho_evcCanCreateCollateralVault() public noGasMetering {
        morpho_evcCanCreateCollateralVault(MO_COLLATERAL_TOKEN);
    }

    // Withdraw after warp tests
    function test_morpho_withdrawCollateralAfterWarp() public noGasMetering {
        morpho_withdrawCollateralAfterWarp(MO_COLLATERAL_TOKEN, 1000);
    }

    function testFuzz_morpho_withdrawCollateralAfterWarp(uint warpBlockAmount) public noGasMetering {
        morpho_withdrawCollateralAfterWarp(MO_COLLATERAL_TOKEN, warpBlockAmount);
    }

    // First borrow tests
    function test_morpho_firstBorrowDirect() public noGasMetering {
        morpho_firstBorrowDirect(MO_COLLATERAL_TOKEN);
    }

    // Post borrow checks
    function test_morpho_postBorrowChecks() public noGasMetering {
        morpho_postBorrowChecks(MO_COLLATERAL_TOKEN);
    }

    // Max borrow tests
    function test_morpho_maxBorrowDirect() public noGasMetering {
        morpho_maxBorrowDirect(MO_COLLATERAL_TOKEN, 1e4);
    }

    function testFuzz_morpho_maxBorrowDirect(uint16 collateralMultiplier) public noGasMetering {
        morpho_maxBorrowDirect(MO_COLLATERAL_TOKEN, collateralMultiplier);
    }

    // Repay and withdraw all tests
    function test_morpho_repayWithdrawAll() public noGasMetering {
        morpho_repayWithdrawAll(MO_COLLATERAL_TOKEN);
    }

    // Permit2 repay tests
    function test_morpho_permit2FirstRepay() public noGasMetering {
        morpho_permit2FirstRepay(MO_COLLATERAL_TOKEN);
    }

    // Interest accrual and repay tests
    function test_morpho_interestAccrualThenRepay() external noGasMetering {
        morpho_interestAccrualThenRepay(MO_COLLATERAL_TOKEN);
    }

    /// @notice A full repay refunds any un-consumed excess to the borrower.
    /// @dev Twyne forwards `maxRepay()`, derived from `MorphoBalancesLib.expectedBorrowAssets` (accrues via
    ///      `borrowRateView`), but `IMorpho.repay` accrues via `borrowRate`. With a divergent IRM the forwarded
    ///      amount exceeds what Morpho consumes and the difference is returned to the borrower.
    function test_morpho_repay_refundsDustToBorrower() public noGasMetering {
        // IRM whose view rate exceeds its mutate rate (same address => same market id, existing setup reused).
        vm.etch(MO_IRM, type(MockDivergentMorphoIRM).runtimeCode);

        morpho_firstBorrowDirect(MO_COLLATERAL_TOKEN);

        // Accrue interest so the view debt outruns the real debt.
        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 1000);

        uint256 maxRepayBefore = alice_morpho_vault.maxRepay();
        assertGt(maxRepayBefore, 0, "no debt to repay");

        vm.startPrank(alice);
        IERC20(MO_LOAN_TOKEN).approve(address(alice_morpho_vault), type(uint256).max);
        uint256 before = IERC20(MO_LOAN_TOKEN).balanceOf(alice);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.repay, (type(uint256).max))
        });
        evc.batch(items);

        uint256 afterBal = IERC20(MO_LOAN_TOKEN).balanceOf(alice);
        vm.stopPrank();

        // dust = forwarded (maxRepay) minus actually consumed (balance lost)
        assertGt(maxRepayBefore - (before - afterBal), 0, "borrower should receive dust refund");
        assertEq(alice_morpho_vault.maxRepay(), 0, "Morpho debt should be fully repaid");
    }

    // Second borrow tests
    function test_morpho_secondBorrow() public noGasMetering {
        morpho_secondBorrow(MO_COLLATERAL_TOKEN);
    }

    // Set LTV tests
    function test_morpho_setTwyneLiqLTVNoBorrow() public noGasMetering {
        morpho_setTwyneLiqLTVNoBorrow(MO_COLLATERAL_TOKEN);
    }

    function test_morpho_setTwyneLiqLTVWithBorrow() public noGasMetering {
        morpho_setTwyneLiqLTVWithBorrow(MO_COLLATERAL_TOKEN);
    }

    // Skim tests
    function test_morpho_skim() public noGasMetering {
        morpho_skim(MO_COLLATERAL_TOKEN);
    }

    // IRM curve test
    function test_morpho_IRMTwyneCurve_nonLinearPoint() public noGasMetering {
        IRMTwyneCurve irm = new IRMTwyneCurve({
            minInterest_: 0,
            linearParameter_: 750,
            polynomialParameter_: 49250,
            nonlinearPoint_: 5e17 // 50%
        });

        uint utilization = irm.nonlinearPoint() - 1;
        uint linearParameter = irm.linearParameter();
        uint polynomialParameter = irm.polynomialParameter();
        uint SECONDS_PER_YEAR = 365.2425 * 86400;

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
        utilTemp4 = (utilTemp4 * utilTemp4) / 1e18;
        uint utilpow = (utilTemp4 * utilTemp4) / 1e18;
        utilpow = (utilpow * utilTemp4) / 1e18;

        uint ir_expected = ((linearParameter * utilization) + (polynomialParameter * utilpow)) * (1e9 / MAXFACTOR);
        ir_expected /= SECONDS_PER_YEAR;

        assertEq(ir, ir_expected);
    }

    function testFuzz_morpho_IRMTwyneCurve(uint64 _utilization) public noGasMetering {
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

            string[] memory cmd = new string[](3);
            cmd[0] = "python3";
            cmd[1] = "../py-fuzz/IRMTwyneCurve.py";
            cmd[2] = vm.toString(utilization);

            bytes memory res = vm.ffi(cmd);
            uint ir2 = abi.decode(res, (uint));

            assertApproxEqRel(ir1, ir2, 3e16);
        }
    }

    // Test market params getter
    function test_morpho_marketParams() public noGasMetering {
        morpho_createCollateralVault(MO_COLLATERAL_TOKEN, twyneLiqLTV);

        MarketParams memory mp = alice_morpho_vault.marketParams();
        assertEq(mp.loanToken, MO_LOAN_TOKEN, "Loan token mismatch");
        assertEq(mp.collateralToken, MO_COLLATERAL_TOKEN, "Collateral token mismatch");
        assertEq(mp.oracle, MO_ORACLE, "Oracle mismatch");
        assertEq(mp.irm, MO_IRM, "IRM mismatch");
        assertEq(mp.lltv, MO_LLTV, "LLTV mismatch");
    }

    // Test collateral balance getter
    function test_morpho_collateralBalance() public noGasMetering {
        morpho_firstBorrowDirect(MO_COLLATERAL_TOKEN);

        uint256 balance = alice_morpho_vault.collateralBalance();
        assertGt(balance, 0, "Should have collateral in Morpho");
    }

    // Test that redeemUnderlying reverts for Morpho
    function test_morpho_redeemUnderlying_reverts() public noGasMetering {
        morpho_creditDeposit(MO_COLLATERAL_TOKEN);
        morpho_createCollateralVault(MO_COLLATERAL_TOKEN, twyneLiqLTV);

        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.T_MorphoNotImplemented.selector);
        alice_morpho_vault.redeemUnderlying(1 ether, alice);
        vm.stopPrank();
    }

    // ============================================================
    // Full repay / full withdraw: Twyne and Morpho must agree
    // ============================================================

    /// @notice Repaying the full Morpho debt zeroes maxRepay(), and Morpho's own state
    ///         (borrow shares + expected borrow assets) agrees it is fully repaid.
    function test_morpho_fullRepay_zeroDebt_bothProtocolsAgree() public noGasMetering {
        morpho_firstBorrowDirect(MO_COLLATERAL_TOKEN);
        assertGt(alice_morpho_vault.maxRepay(), 0, "should start with Morpho debt");
        assertGt(
            MorphoLib.borrowShares(IMorpho(morpho), morphoMarketId, address(alice_morpho_vault)),
            0,
            "Morpho should report borrow shares before repay"
        );

        // Repay the full Morpho debt
        vm.startPrank(alice);
        IERC20(MO_LOAN_TOKEN).approve(address(alice_morpho_vault), type(uint256).max);
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.repay, (type(uint256).max))
        });
        evc.batch(items);
        vm.stopPrank();

        // Twyne view: no Morpho debt
        assertEq(alice_morpho_vault.maxRepay(), 0, "Twyne maxRepay should be 0 after full repay");

        // Morpho protocol agrees: zero borrow shares and zero expected borrow assets
        assertEq(
            MorphoLib.borrowShares(IMorpho(morpho), morphoMarketId, address(alice_morpho_vault)),
            0,
            "Morpho borrow shares should be 0"
        );
        assertEq(
            MorphoBalancesLib.expectedBorrowAssets(IMorpho(morpho), morphoMarketParams, address(alice_morpho_vault)),
            0,
            "Morpho expected borrow assets should be 0"
        );
    }

    /// @notice After repaying all debt and withdrawing all collateral, the vault is fully wound
    ///         down: totalAssetsDepositedOrReserved == 0 and Morpho reports zero collateral
    ///         and zero debt for the vault.
    function test_morpho_fullWithdraw_zeroCollateral_bothProtocolsAgree() public noGasMetering {
        morpho_firstBorrowDirect(MO_COLLATERAL_TOKEN);
        assertGt(alice_morpho_vault.collateralBalance(), 0, "should start with Morpho collateral");

        vm.startPrank(alice);
        IERC20(MO_LOAN_TOKEN).approve(address(alice_morpho_vault), type(uint256).max);
        IERC20(MO_COLLATERAL_TOKEN).approve(address(alice_morpho_vault), type(uint256).max);

        // 1. Repay all Morpho debt
        IEVC.BatchItem[] memory repayItems = new IEVC.BatchItem[](1);
        repayItems[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.repay, (type(uint256).max))
        });
        evc.batch(repayItems);

        // 2. Withdraw all collateral
        IEVC.BatchItem[] memory withdrawItems = new IEVC.BatchItem[](1);
        withdrawItems[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.withdraw, (type(uint).max, alice))
        });
        evc.batch(withdrawItems);
        vm.stopPrank();

        // Twyne view: vault fully wound down
        assertEq(alice_morpho_vault.totalAssetsDepositedOrReserved(), 0, "totalAssetsDepositedOrReserved should be 0");
        assertEq(alice_morpho_vault.maxRepay(), 0, "maxRepay should be 0");
        assertEq(alice_morpho_vault.maxRelease(), 0, "maxRelease should be 0");

        // Morpho protocol agrees: zero collateral and zero debt for this vault
        assertEq(
            MorphoLib.collateral(IMorpho(morpho), morphoMarketId, address(alice_morpho_vault)),
            0,
            "Morpho collateral should be 0"
        );
        assertEq(
            MorphoLib.borrowShares(IMorpho(morpho), morphoMarketId, address(alice_morpho_vault)),
            0,
            "Morpho borrow shares should be 0"
        );
    }
    // Borrow buffer maxBorrow tests
    function test_morpho_borrowBufferMaxBorrow() public noGasMetering {
        morpho_borrowBufferMaxBorrow(MO_COLLATERAL_TOKEN);
    }

    // With no governance-set borrow buffer (x = 0), Twyne applies no maxBorrow discount, preserving
    // existing behavior: borrowing is bounded only by the borrower's liqLTV_t and Morpho's own lltv.
    function test_morpho_borrowBufferDefaultsToNone() public noGasMetering {
        morpho_borrowBufferDefaultsToNone(MO_COLLATERAL_TOKEN);
    }

    // The ramp is enforced on collateral withdraw, not only borrow: at maxBorrow a 1-wei withdraw
    // reverts with the Twyne error.
    function test_morpho_borrowRampBlocksWithdraw() public noGasMetering {
        morpho_borrowRampBlocksWithdraw(MO_COLLATERAL_TOKEN);
    }

    // Spec Eq. 1 monotonicity (k<1): raising twyneLiqLTV raises maxBorrow, so the gated action
    // succeeds and maxBorrow strictly increases.
    function test_morpho_borrowRampMonotonicInLiqLTV() public noGasMetering {
        morpho_borrowRampMonotonicInLiqLTV(MO_COLLATERAL_TOKEN);
    }

    // Non-degrading actions (deposit) are never blocked by the ramp.
    function test_morpho_borrowRampAllowsNonDegradingAtMaxBorrow() public noGasMetering {
        morpho_borrowRampAllowsNonDegradingAtMaxBorrow(MO_COLLATERAL_TOKEN);
    }

    // An over-maxBorrow position may be repaid/topped up but not degraded by a new borrow;
    // the checkVaultStatus snapshot delta is what makes this possible.
    function test_morpho_borrowRampOverMaxBorrowAllowsRepay() public noGasMetering {
        morpho_borrowRampOverMaxBorrowAllowsRepay(MO_COLLATERAL_TOKEN);
    }

    // Lowering twyneLiqLTV while over the new, lower maxBorrow grows the excess and reverts (below the
    // liquidation boundary, so the ramp — not _canLiquidate — rejects); repaying within the new maxBorrow first
    // is the escape hatch.
    function test_morpho_borrowRampBlocksLiqLTVDecrease() public noGasMetering {
        morpho_borrowRampBlocksLiqLTVDecrease(MO_COLLATERAL_TOKEN);
    }

    // The enforced metric is excess-per-collateral, not absolute excess: pairing a repay with a
    // withdrawal in one batch holds the absolute excess flat (or shrinking) while LTV rises, yet the
    // ratio check still reverts.
    function test_morpho_borrowRampBlocksRepayAndWithdraw() public noGasMetering {
        morpho_borrowRampBlocksRepayAndWithdraw(MO_COLLATERAL_TOKEN);
    }

    // An over-maxBorrow position cannot leverage up (borrow + proportional deposit in one batch);
    // the absolute-debt cap (maxRepay₁ ≤ maxRepay₀) blocks it while amelioration still passes.
    function test_morpho_borrowRampOverMaxBorrowBlocksLeverage() public noGasMetering {
        morpho_borrowRampOverMaxBorrowBlocksLeverage(MO_COLLATERAL_TOKEN);
    }

    // Interest accrual pushes a healthy position over maxBorrow; the ramp then blocks further
    // borrows and allows repay (over-maxBorrow regime via debt growth, not a buffer raise).
    function test_morpho_borrowRampAccrualOverMaxBorrow() public noGasMetering {
        morpho_borrowRampAccrualOverMaxBorrow(MO_COLLATERAL_TOKEN);
    }
}
