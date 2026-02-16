// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import "euler-vault-kit/EVault/shared/types/Types.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {AaveV3CollateralVault} from "src/twyne/AaveV3CollateralVault.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";
import {VaultType} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {AaveTestBase} from "./AaveTestBase.t.sol";
import {console2} from "forge-std/console2.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {IPool as IAaveV3Pool} from "aave-v3/interfaces/IPool.sol";
import {IAaveOracle} from "aave-v3/interfaces/IAaveOracle.sol";
import {MockChainlinkOracle} from "test/mocks/MockChainlinkOracle.sol";
import {MockAaveFeed} from "test/mocks/MockAaveFeed.sol";
import {LiquidationMath} from "../euler/LiquidationMath.sol";

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

contract AaveTestPostFallbackAccounting is AaveTestBase {
    
    function setUp() public override {
        super.setUp();
    }

    function createInitialPosition(uint256 C, uint256, /* CLP */ uint256 B, uint256 twyneLTV) public {
        // Pre-setup checks
        uint16 minLTV = uint16(getLiqLTV(address(aWETHWrapper), USDC));
        uint16 extLiqBuffer = twyneVaultManager.externalLiqBuffers(address(aWETHWrapper));
        require(uint256(minLTV) * uint256(extLiqBuffer) <= uint256(twyneLTV) * MAXFACTOR, "precond fail");
        require(twyneLTV <= twyneVaultManager.maxTwyneLTVs(address(aWETHWrapper)), "twyneLTV too high");

        aave_creditDeposit(address(aWETHWrapper));

        vm.startPrank(alice);
        alice_aave_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _asset: address(aWETHWrapper),
                _targetVault: aavePool,
                _liqLTV: twyneLTV,
                _targetAsset: USDC
            })
        );

        IERC20(address(aWETHWrapper)).approve(address(alice_aave_vault), type(uint256).max);
        vm.stopPrank();
        dealWrapperToken(address(aWETHWrapper), alice, C);
        
        vm.startPrank(alice);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.deposit, (C))
        });

        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.borrow, (B, alice))
        });

        evc.batch(items);
        vm.stopPrank();
    }

    function executePriceDrop(uint256 bpsToPriceDrop) public {
        address wethFeed = getAaveOracleFeed(WETH);
        uint256 currentPrice = getAavePrice(WETH); 
        uint256 newPrice = currentPrice * (100 - bpsToPriceDrop) / 100;
        
        MockAaveFeed mockAaveFeed = new MockAaveFeed();
        vm.etch(wethFeed, address(mockAaveFeed).code);
        MockAaveFeed(wethFeed).setPrice(newPrice);
    }

    function setup_approve_customSetup() internal {
        uint256 debt = IERC20(address(aDebtUSDC)).balanceOf(address(alice_aave_vault));
        deal(USDC, liquidator, debt + 1_000_000);
        
        vm.startPrank(liquidator);
        IERC20(USDC).approve(aavePool, type(uint256).max); // Approve Aave Pool for liquidation
        IERC20(USDC).approve(address(alice_aave_vault), type(uint256).max); // Approve vault for handleExternalLiquidation if needed
        IERC20(USDC).approve(permit2, type(uint256).max);
        vm.stopPrank();
    }

    function executeExternalLiquidationWithPartialRepay(uint256 repayPct) public {
        vm.warp(block.timestamp + 1);

        uint256 debt = IERC20(address(aDebtUSDC)).balanceOf(address(alice_aave_vault));
        uint256 amountToRepay = debt * repayPct / 100;
        if (amountToRepay == 0) amountToRepay = type(uint256).max; 
        
        vm.startPrank(liquidator);
        
        // Aave liquidation call
        IAaveV3Pool(aavePool).liquidationCall(
            WETH, // Collateral asset (underlying)
            USDC, // Debt asset
            address(alice_aave_vault), // User
            amountToRepay, // Debt to cover
            false // receiveAToken (false = receive underlying)
        );
        
        vm.stopPrank();
        
        assertTrue(alice_aave_vault.isExternallyLiquidated(), "not externally liquidated");
    }

    function executeHandleExternalLiquidation() internal {
        uint256 maxReleaseAfterExtLiq = alice_aave_vault.maxRelease();
        uint256 maxRepayAfterExtLiq = alice_aave_vault.maxRepay();

        if (maxReleaseAfterExtLiq == 0) {
            vm.startPrank(alice);
            IERC20(USDC).approve(permit2, type(uint256).max);
            IERC20(USDC).approve(address(alice_aave_vault), type(uint256).max);

            evc.call({
                targetContract: address(alice_aave_vault),
                onBehalfOfAccount: alice,
                value: 0,
                data: abi.encodeCall(alice_aave_vault.handleExternalLiquidation, ())
            });
        } else {
            vm.startPrank(liquidator);
            uint256 requiredUSDC = maxRepayAfterExtLiq + 1_000_000;
            if (IERC20(USDC).balanceOf(liquidator) < requiredUSDC) {
                deal(USDC, liquidator, requiredUSDC);
            }

            IERC20(USDC).approve(address(alice_aave_vault), type(uint256).max);
            IERC20(USDC).approve(permit2, type(uint256).max);

            IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
            items[0] = IEVC.BatchItem({
                targetContract: address(alice_aave_vault),
                onBehalfOfAccount: liquidator,
                value: 0,
                data: abi.encodeCall(alice_aave_vault.handleExternalLiquidation, ())
            });

            evc.batch(items);
            vm.stopPrank();
        }
    }

    function _logPostFallbackAccounting() internal view {
        PostFallbackAccountingData memory data;
        address uoa = IEVault(alice_aave_vault.intermediateVault()).unitOfAccount();
        
        data.pre_C = alice_aave_vault.totalAssetsDepositedOrReserved() - alice_aave_vault.maxRelease();
        data.pre_CLP = alice_aave_vault.maxRelease();
        
        uint256 current_C = IERC20(alice_aave_vault.asset()).balanceOf(address(alice_aave_vault));
        uint256 current_C_LP = alice_aave_vault.maxRelease();
        
        data.C_left = current_C + current_C_LP;
        
        ( , uint256 totalDebtBase, , , , ) = IAaveV3Pool(aavePool).getUserAccountData(address(alice_aave_vault));
        data.B_left = totalDebtBase;
        
        data.max_liqLTV_t = twyneVaultManager.maxTwyneLTVs(alice_aave_vault.asset());
        
        data.C_left_USD = uint(aWETHWrapper.latestAnswer()) * data.C_left / 1e18;
        
        uint256 C_temp_calc = (data.B_left * MAXFACTOR) / data.max_liqLTV_t;
        data.C_temp_USD = Math.min(C_temp_calc, data.C_left_USD);
        
        if (data.C_temp_USD > 0) {
            data.C_temp = data.C_temp_USD * 1e18 / uint(aWETHWrapper.latestAnswer()); 
        }
        
        data.C_LP_new = Math.min(
            data.C_left > data.C_temp ? data.C_left - data.C_temp : 0,
            data.pre_CLP
        );
        
        data.C_new = Math.max(
            data.C_temp,
            data.C_left > data.pre_CLP ? data.C_left - data.pre_CLP : 0
        );
        
        data.C_diff = current_C > data.C_new ? current_C - data.C_new : 0;
        
        if (current_C_LP >= data.C_LP_new) {
            data.C_LP_diff = current_C_LP - data.C_LP_new;
        } else {
            data.C_LP_diff = 0;
        }
        
        if (data.pre_CLP > 0) {
            uint256 clp_remaining_bps = (data.C_LP_new * MAXFACTOR) / data.pre_CLP;
            if (clp_remaining_bps < MAXFACTOR) {
                data.clp_loss_bps = MAXFACTOR - clp_remaining_bps;
            }
        }
        
        data.excess_credit = 0;
        
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
    }

    // --- Tests ---

    function test_a_handleExternalLiquidation_case00() external noGasMetering {
        createInitialPosition(5e18, 0, 12000e6, 8500);
        executePriceDrop(32);
        setup_approve_customSetup();
        executeExternalLiquidationWithPartialRepay(50); 
        executeHandleExternalLiquidation();
        assertEq(alice_aave_vault.borrower(), address(0), "owner is not 0");
        assertEq(alice_aave_vault.totalAssetsDepositedOrReserved(), 0, "totalAssetsDepositedOrReserved is not 0");
    }

    function test_a_handleExternalLiquidation_case01() external noGasMetering {
        createInitialPosition(5e18, 0, 12000e6, 9000);
        executePriceDrop(35);
        setup_approve_customSetup();
        executeExternalLiquidationWithPartialRepay(20); 
        _logPostFallbackAccounting();
        executeHandleExternalLiquidation();
        assertEq(alice_aave_vault.borrower(), address(0), "owner is not 0");
        assertEq(alice_aave_vault.totalAssetsDepositedOrReserved(), 0, "totalAssetsDepositedOrReserved is not 0");
    }

    function test_a_handleExternalLiquidation_case10() external noGasMetering {
        createInitialPosition(5e18, 5e18, 12000e6, 9000);
        executePriceDrop(35);
        setup_approve_customSetup();
        executeExternalLiquidationWithPartialRepay(15); 
        executeHandleExternalLiquidation();
        assertEq(alice_aave_vault.borrower(), address(0), "owner is not 0");
        assertEq(alice_aave_vault.totalAssetsDepositedOrReserved(), 0, "totalAssetsDepositedOrReserved is not 0");
    }

    function test_a_handleExternalLiquidationMath_splitCollateralAfterExtLiq_ZeroCollateral() external noGasMetering {
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

    // Add basic coverage for other math cases (subset of Euler tests for brevity)
    function test_a_handleExternalLiquidationMath_splitCollateralAfterExtLiq_ZeroMaxRelease() external noGasMetering {
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
    }

    function test_a_expectRevert_handleExternalLiquidation_NotExternallyLiquidated() external noGasMetering {
        createInitialPosition(5e18, 0, 12000e6, 8500);
        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.NotExternallyLiquidated.selector);
        evc.call({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.handleExternalLiquidation, ())
        });
        vm.stopPrank();
    }

    function test_a_expectRevert_handleExternalLiquidation_ExternalPositionUnhealthy() external noGasMetering {
        createInitialPosition(5e18, 0, 12000e6, 8500);
        executePriceDrop(32);
        setup_approve_customSetup();
        executeExternalLiquidationWithPartialRepay(5);
        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.ExternalPositionUnhealthy.selector);
        evc.call({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.handleExternalLiquidation, ())
        });
        vm.stopPrank();
    }

    function test_a_expectRevert_handleExternalLiquidation_NoLiquidationForZeroReserve() external noGasMetering {
        createInitialPosition(5e18, 0, 12000e6, 8300);
        executePriceDrop(32);
        setup_approve_customSetup();
        executeExternalLiquidationWithPartialRepay(40);
        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.NoLiquidationForZeroReserve.selector);
        evc.call({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.handleExternalLiquidation, ())
        });
        vm.stopPrank();
    }
    
}
