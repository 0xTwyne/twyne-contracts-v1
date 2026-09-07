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
import "euler-vault-kit/EVault/shared/types/Types.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Post-fallback accounting data for logging
struct PostFallbackAccountingData {
    uint256 pre_C;
    uint256 pre_CLP;
    uint256 C_left;
    uint256 C_left_value;
    uint256 B_left;
    uint256 max_liqLTV_t;
    uint256 C_temp_value;
    uint256 C_temp;
    uint256 C_LP_new;
    uint256 C_new;
    uint256 C_diff;
    uint256 C_LP_diff;
    uint256 clp_loss_bps;
    uint256 excess_credit;
}

/// @notice Input for splitCollateralAfterExtLiq math tests
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

/// @title MorphoTestPostFallbackAccounting
/// @notice Post-fallback accounting tests for external liquidation handling on Morpho ETH-USDT market.
/// @dev Follows the same pattern as AaveTestPostFallbackAccounting and EulerTestPostFallbackAccounting.
///
/// Test suite overview:
///  - Case00–01: post-fallback accounting for safe cases (λ_t ≤ β_safe * λ̃_e)
///  - Case10: post-fallback accounting for higher LTV scenarios
///  - splitCollateralAfterExtLiq math edge cases: zero collateral, zero maxRelease
///  - Revert tests: NotExternallyLiquidated, NoLiquidationForZeroReserve
contract MorphoTestPostFallbackAccounting is MorphoLiquidationTest {
    using MathLib for uint;

    function setUp() public override {
        super.setUp();
    }

    // ─── Position creation ─────────────────────────────────────────────

    /// @notice Creates an initial borrowing position on Morpho via Twyne
    /// @param C Collateral amount in WETH (18 decimals)
    /// @param B Borrow amount in USDT (6 decimals)
    /// @param twyneLTV_ Twyne liquidation LTV in 1e4 precision
    function createInitialPosition(uint256 C, uint256 /* CLP */, uint256 B, uint256 twyneLTV_) public {
        // Pre-setup checks
        uint256 extLiqLTV = ETH_USDT_LLTV * 1e4 / 1e18;
        uint16 extLiqBuffer = twyneVaultManager.externalLiqBuffers(address(morpho_intermediate_vault), USDT);
        require(extLiqLTV * uint256(extLiqBuffer) <= uint256(twyneLTV_) * MAXFACTOR, "precond: LTV too low");
        require(twyneLTV_ <= twyneVaultManager.maxTwyneLTVs(address(morpho_intermediate_vault), USDT), "precond: twyneLTV too high");

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
            _liqLTV: uint16(twyneLTV_)
        });
        address[] memory aliceVaults = collateralVaultFactory.getCollateralVaults(alice);
        alice_morpho_vault = MorphoCollateralVault(aliceVaults[aliceVaults.length - 1]);
        vm.label(address(alice_morpho_vault), "alice_morpho_vault_eth_usdt");

        IERC20(WETH).approve(address(alice_morpho_vault), type(uint256).max);

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
    function executePriceDrop(uint256 pctDrop) public {
        _setMorphoOraclePrice(MAXFACTOR - pctDrop * MAXFACTOR / 100);
    }

    // ─── Liquidator helpers ────────────────────────────────────────────

    /// @notice Fund & approve liquidator for external liquidation
    function setup_approve_customSetup() internal {
        uint256 debt = alice_morpho_vault.maxRepay();
        deal(USDT, liquidator, debt + 10_000_000e6);
        deal(WETH, liquidator, 100 ether);

        vm.startPrank(liquidator);
        SafeERC20.forceApprove(IERC20_OZ(USDT), morpho, type(uint256).max);
        SafeERC20.forceApprove(IERC20_OZ(USDT), address(alice_morpho_vault), type(uint256).max);
        IERC20(WETH).approve(address(alice_morpho_vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Execute an external Morpho liquidation seizing a percentage of collateral
    /// @param seizePct Percentage of collateral to seize (e.g. 50 = 50%)
    function executeExternalLiquidationWithPartialSeize(uint256 seizePct) public {
        vm.warp(block.timestamp + 1);

        uint256 collateralBal = alice_morpho_vault.collateralBalance();
        uint256 seizeAmount = collateralBal * seizePct / 100;
        require(seizeAmount > 0, "seize=0");

        vm.startPrank(liquidator);
        IMorpho(morpho).liquidate({
            marketParams: morphoMarketParams,
            borrower: address(alice_morpho_vault),
            seizedAssets: seizeAmount,
            repaidShares: 0,
            data: ""
        });
        vm.stopPrank();

        assertTrue(alice_morpho_vault.isExternallyLiquidated(), "not externally liquidated");
    }

    /// @notice Execute handleExternalLiquidation (borrower or liquidator depending on maxRelease)
    function executeHandleExternalLiquidation() internal {
        uint256 maxReleaseAfterExtLiq = alice_morpho_vault.maxRelease();
        uint256 maxRepayAfterExtLiq = alice_morpho_vault.maxRepay();

        if (maxReleaseAfterExtLiq == 0) {
            // Only borrower can call when no reserved assets
            vm.startPrank(alice);
            SafeERC20.forceApprove(IERC20_OZ(USDT), address(alice_morpho_vault), type(uint256).max);

            evc.call({
                targetContract: address(alice_morpho_vault),
                onBehalfOfAccount: alice,
                value: 0,
                data: abi.encodeCall(alice_morpho_vault.handleExternalLiquidation, ())
            });
        } else {
            // Liquidator handles it
            vm.startPrank(liquidator);
            uint256 requiredUSDT = maxRepayAfterExtLiq + 1_000_000e6;
            if (IERC20(USDT).balanceOf(liquidator) < requiredUSDT) {
                deal(USDT, liquidator, requiredUSDT);
            }
            SafeERC20.forceApprove(IERC20_OZ(USDT), address(alice_morpho_vault), type(uint256).max);

            // Enable controller for intermediate vault (required for liquidate batch item)
            IEVC(alice_morpho_vault.EVC()).enableController(liquidator, address(alice_morpho_vault.intermediateVault()));

            IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
            items[0] = IEVC.BatchItem({
                targetContract: address(alice_morpho_vault),
                onBehalfOfAccount: liquidator,
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
        }
    }

    // ─── Logging helpers ───────────────────────────────────────────────

    /// @notice Log post-fallback accounting data before execution
    function _logPostFallbackAccounting() internal view {
        PostFallbackAccountingData memory data;

        data.pre_C = alice_morpho_vault.totalAssetsDepositedOrReserved() - alice_morpho_vault.maxRelease();
        data.pre_CLP = alice_morpho_vault.maxRelease();

        uint256 current_C_balance = alice_morpho_vault.collateralBalance();
        uint256 current_C_LP = alice_morpho_vault.maxRelease();

        data.C_left = current_C_balance + IERC20(WETH).balanceOf(address(alice_morpho_vault));
        data.B_left = alice_morpho_vault.maxRepay();
        data.max_liqLTV_t = twyneVaultManager.maxTwyneLTVs(address(alice_morpho_vault.intermediateVault()), alice_morpho_vault.targetAsset());

        uint256 price = IOracle(ETH_USDT_ORACLE).price();
        data.C_left_value = data.C_left.mulDivDown(price, ORACLE_PRICE_SCALE);

        uint256 C_temp_calc = data.B_left * MAXFACTOR / data.max_liqLTV_t;
        data.C_temp_value = Math.min(C_temp_calc, data.C_left_value);

        if (data.C_temp_value > 0) {
            data.C_temp = data.C_temp_value.mulDivDown(ORACLE_PRICE_SCALE, price);
        }

        data.C_LP_new = Math.min(
            data.C_left > data.C_temp ? data.C_left - data.C_temp : 0,
            data.pre_CLP
        );

        data.C_new = Math.max(
            data.C_temp,
            data.C_left > data.pre_CLP ? data.C_left - data.pre_CLP : 0
        );

        data.C_diff = data.pre_C > data.C_new ? data.pre_C - data.C_new : 0;

        if (current_C_LP >= data.C_LP_new) {
            data.C_LP_diff = current_C_LP - data.C_LP_new;
        }

        if (data.pre_CLP > 0) {
            uint256 clp_remaining_bps = (data.C_LP_new * MAXFACTOR) / data.pre_CLP;
            if (clp_remaining_bps < MAXFACTOR) {
                data.clp_loss_bps = MAXFACTOR - clp_remaining_bps;
            }
        }

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
        console2.log("C_left_value=", data.C_left_value);
        console2.log("C_temp_value=", data.C_temp_value);
    }

    /////////////////////////////////////////////////////////////////
    //////////////// External Liquidation + Handling /////////////////
    /////////////////////////////////////////////////////////////////

    /// @notice Case 00: moderate price drop, 50% seize, price recovery, then handle
    function test_m_handleExternalLiquidation_case00() external noGasMetering {
        createInitialPosition(5e18, 0, BORROW_USDT_AMOUNT, twyneLiqLTV);
        executePriceDrop(15);
        setup_approve_customSetup();
        executeExternalLiquidationWithPartialSeize(50);
        _setMorphoPriceForTargetHF(1.05e18);
        executeHandleExternalLiquidation();
        assertEq(alice_morpho_vault.borrower(), address(0), "owner is not 0");
        assertEq(alice_morpho_vault.totalAssetsDepositedOrReserved(), 0, "totalAssetsDepositedOrReserved is not 0");
    }

    /// @notice Case 01: higher LTV position, deeper drop, smaller seize
    function test_m_handleExternalLiquidation_case01() external noGasMetering {
        uint16 higherLTV = twyneVaultManager.maxTwyneLTVs(address(morpho_intermediate_vault), USDT);
        createInitialPosition(5e18, 0, BORROW_USDT_AMOUNT, higherLTV);
        executePriceDrop(15);
        setup_approve_customSetup();
        executeExternalLiquidationWithPartialSeize(20);
        _logPostFallbackAccounting();
        _setMorphoPriceForTargetHF(1.05e18);
        executeHandleExternalLiquidation();
        assertEq(alice_morpho_vault.borrower(), address(0), "owner is not 0");
        assertEq(alice_morpho_vault.totalAssetsDepositedOrReserved(), 0, "totalAssetsDepositedOrReserved is not 0");
    }

    /// @notice Case 10: use setupCompleteExternalLiquidation as base, partial seize
    function test_m_handleExternalLiquidation_case10() external noGasMetering {
        test_morpho_setupCompleteExternalLiquidation();

        vm.warp(block.timestamp + 1);
        deal(WETH, liquidator, 100 ether);
        deal(USDT, liquidator, 10_000_000e6);

        vm.startPrank(liquidator);
        SafeERC20.forceApprove(IERC20_OZ(USDT), morpho, type(uint256).max);
        SafeERC20.forceApprove(IERC20_OZ(USDT), address(alice_morpho_vault), type(uint256).max);
        IERC20(WETH).approve(address(alice_morpho_vault), type(uint256).max);

        IEVC(alice_morpho_vault.EVC()).enableController(liquidator, address(alice_morpho_vault.intermediateVault()));

        uint256 collateralBefore = alice_morpho_vault.collateralBalance();
        uint256 seizeAmount = collateralBefore / 2;

        IMorpho(morpho).liquidate({
            marketParams: morphoMarketParams,
            borrower: address(alice_morpho_vault),
            seizedAssets: seizeAmount,
            repaidShares: 0,
            data: ""
        });
        vm.stopPrank();

        assertTrue(alice_morpho_vault.isExternallyLiquidated(), "should be externally liquidated");

        // Recover Morpho price to make position healthy (required by handleExternalLiquidation)
        _setMorphoPriceForTargetHF(1.05e18);

        // Handle external liquidation
        vm.startPrank(liquidator);
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

        assertEq(alice_morpho_vault.borrower(), address(0), "owner is not 0");
        assertEq(alice_morpho_vault.totalAssetsDepositedOrReserved(), 0, "totalAssetsDepositedOrReserved is not 0");
    }

    /////////////////////////////////////////////////////////////////
    //////////////// splitCollateralAfterExtLiq math ////////////////
    /////////////////////////////////////////////////////////////////

    /// @notice Zero collateral → all outputs zero
    function test_m_handleExternalLiquidationMath_splitCollateralAfterExtLiq_ZeroCollateral() external noGasMetering {
        SplitCollateralAfterExtLiqInput memory input = SplitCollateralAfterExtLiqInput({
            collateralBalance: 0,
            userCollateralInitial: 0,
            maxRelease: 0,
            C_new: 0,
            B: 0,
            externalLiqBuffer: 10_000,
            extLiqLTV: 9_150,
            maxLTV_t: 9_500
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

    /// @notice Zero maxRelease → all collateral split between borrower and liquidator
    function test_m_handleExternalLiquidationMath_splitCollateralAfterExtLiq_ZeroMaxRelease() external noGasMetering {
        SplitCollateralAfterExtLiqInput memory input = SplitCollateralAfterExtLiqInput({
            collateralBalance: 1e18,
            userCollateralInitial: 1e18,
            maxRelease: 0,
            C_new: 1e18,
            B: 5e6,
            externalLiqBuffer: 10_000,
            extLiqLTV: 9_150,
            maxLTV_t: 9_500
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
    }

    /////////////////////////////////////////////////////////////////
    //////////////// Revert tests ///////////////////////////////////
    /////////////////////////////////////////////////////////////////

    /// @notice handleExternalLiquidation reverts when vault is not externally liquidated
    function test_m_expectRevert_handleExternalLiquidation_NotExternallyLiquidated() external noGasMetering {
        createInitialPosition(5e18, 0, BORROW_USDT_AMOUNT, twyneLiqLTV);
        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.NotExternallyLiquidated.selector);
        evc.call({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.handleExternalLiquidation, ())
        });
        vm.stopPrank();
    }

    /// @notice handleExternalLiquidation reverts when called by non-borrower with zero reserves
    /// @dev Uses the existing MorphoLiquidationTest setup which already covers this scenario
    function test_m_expectRevert_handleExternalLiquidation_NoLiquidationForZeroReserve() external noGasMetering {
        // Use existing test setup with minLTV (= Morpho LLTV = 9150) to ensure zero reserved assets
        test_morpho_preLiquidationSetup(getETHUSDTLTVIn1e4());

        // Verify maxRelease is 0 (no reserved assets at min LTV)
        assertEq(alice_morpho_vault.maxRelease(), 0, "should have zero reserved assets");

        // Borrow to have debt
        vm.startPrank(alice);
        SafeERC20.forceApprove(IERC20_OZ(USDT), address(alice_morpho_vault), type(uint256).max);
        if (alice_morpho_vault.maxRepay() == 0) {
            alice_morpho_vault.borrow(BORROW_USDT_AMOUNT / 2, alice);
        }
        vm.stopPrank();

        // Trigger external liquidation with moderate price drop
        _setMorphoOraclePrice(8500); // 85% of original
        vm.warp(block.timestamp + 1);

        deal(WETH, liquidator, 100 ether);
        deal(USDT, liquidator, 10_000_000e6);

        vm.startPrank(liquidator);
        SafeERC20.forceApprove(IERC20_OZ(USDT), morpho, type(uint256).max);

        uint256 collateralBal = alice_morpho_vault.collateralBalance();
        IMorpho(morpho).liquidate({
            marketParams: morphoMarketParams,
            borrower: address(alice_morpho_vault),
            seizedAssets: collateralBal / 4,
            repaidShares: 0,
            data: ""
        });
        vm.stopPrank();

        assertTrue(alice_morpho_vault.isExternallyLiquidated(), "should be externally liquidated");

        // Recover price so position is healthy on Morpho
        _setMorphoPriceForTargetHF(1.05e18);
        vm.warp(block.timestamp + 1);

        // Non-borrower should be rejected when maxRelease == 0
        vm.startPrank(liquidator);
        SafeERC20.forceApprove(IERC20_OZ(USDT), address(alice_morpho_vault), type(uint256).max);
        vm.expectRevert(TwyneErrors.NoLiquidationForZeroReserve.selector);
        evc.call({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.handleExternalLiquidation, ())
        });
        vm.stopPrank();
    }
}
