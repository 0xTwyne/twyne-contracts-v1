// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import "euler-vault-kit/EVault/shared/types/Types.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {AaveV3CollateralVault} from "src/twyne/AaveV3CollateralVault.sol";
import {LiquidationMath} from "../euler/LiquidationMath.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";
import {VaultType} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {AaveTestBase} from "./AaveTestBase.t.sol";
import {console2} from "forge-std/console2.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {IERC20Metadata} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPool as IAaveV3Pool} from "aave-v3/interfaces/IPool.sol";
import {IAaveV3ATokenWrapper} from "src/interfaces/IAaveV3ATokenWrapper.sol";
import {MockAaveFeed} from "test/mocks/MockAaveFeed.sol";
import {IAaveOracle} from "aave-v3/interfaces/IAaveOracle.sol";

interface IWETH is IERC20 {
    receive() external payable;
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

struct LiquidationSnapshot {
    uint256 borrowerAWETH;
    uint256 liquidatorAWETH;
    uint256 vaultAWETH;
    uint256 vaultUSDC;
    uint256 vaultDebt;
    address borrower;
    uint256 maxRepay;
    uint256 totalAssets;
    uint256 maxRelease;
    uint256 expectedCollateralForBorrower;
}

contract AaveTestInternalLiquidation is AaveTestBase {
    
    function setUp() public override {
        super.setUp();
    }

    /// @dev Ensure liquidator can pay `collateralForBorrower` (internal liquidation transfers collateral from liquidator to borrower)
    function _fundLiquidatorWithCollateral(uint256 amount) internal {
        // Give liquidator some extra buffer for rounding
        dealWrapperToken(address(aWETHWrapper), liquidator, amount + 1e12);
        vm.startPrank(liquidator);
        IERC20(address(aWETHWrapper)).approve(address(alice_aave_vault), type(uint256).max);
        vm.stopPrank();
    }

    function createInitialPosition(uint256 C, uint256/* CLP */, uint256 B, uint256 twyneLTV) public {
        // Pre-setup checks
        uint16 minLTV = uint16(getLiqLTV(address(aWETHWrapper), USDC));
        uint16 extLiqBuffer = twyneVaultManager.externalLiqBuffers(address(aWETHWrapper));
        require(uint256(minLTV) * uint256(extLiqBuffer) <= uint256(twyneLTV) * MAXFACTOR, "precond fail");
        require(twyneLTV <= twyneVaultManager.maxTwyneLTVs(address(aWETHWrapper)), "twyneLTV too high");

        // Bob deposits into intermediate vault to earn boosted yield
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

        vm.label(address(alice_aave_vault), "alice_aave_vault");

        // Alice approves collateral
        IERC20(address(aWETHWrapper)).approve(address(alice_aave_vault), type(uint256).max);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        
        dealWrapperToken(address(aWETHWrapper), alice, C);

        vm.startPrank(alice);
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
        // Mock Aave Oracle Price for WETH
        // Aave uses a Chainlink source. We need to mock that source.
        address wethFeed = getAaveOracleFeed(WETH);
        
        // Get current price to calculate new price
        uint256 currentPrice = getAavePrice(WETH); // 8 decimals usually for Aave v3 prices
        
        uint256 newPrice = currentPrice * (100 - bpsToPriceDrop) / 100;
        
        // Etch a mock oracle at the feed address
        // Note: This might affect other tests if they run in same fork state, but for this test file it's fine.
        MockAaveFeed mockAaveFeed = new MockAaveFeed();
        vm.etch(wethFeed, address(mockAaveFeed).code);
        MockAaveFeed(wethFeed).setPrice(newPrice);
    }

    function setup_approve_customSetup() internal {
        // Fund liquidator with USDC to repay debt
        // In Aave, debt is variableDebtUSDC.
        uint256 debt = IERC20(address(aDebtUSDC)).balanceOf(address(alice_aave_vault));
        deal(USDC, liquidator, debt + 1_000_000);
        
        // Approvals
        vm.startPrank(liquidator);
        IERC20(address(aWETHWrapper)).approve(address(alice_aave_vault), type(uint256).max);
        IERC20(USDC).approve(address(alice_aave_vault), type(uint256).max);
        vm.stopPrank();
    }

    function executeLiquidationWithRepay() internal {
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        vm.startPrank(liquidator);
        // First: liquidate (transfers ownership to liquidator)
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.liquidate, ())
        });

        // Second: repay all debt to make position healthy
        // maxRepay on Aave vault should return the current debt
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.repay, (alice_aave_vault.maxRepay()))
        });

        evc.batch(items);
        vm.stopPrank();
    }

    // --- Helper Views ---

    function _getBC() internal view returns (uint256 B, uint256 C) {
        // Aave debt
        B = IERC20(address(aDebtUSDC)).balanceOf(address(alice_aave_vault));
        
        ( , uint256 totalDebtBase, , , , ) = IAaveV3Pool(aavePool).getUserAccountData(address(alice_aave_vault));
        
        // C calculation:
        // userCollateral = totalAssets - maxRelease
        // C_new = userCollateral * price / decimals
        
        uint256 totalAssets = alice_aave_vault.totalAssetsDepositedOrReserved();
        uint256 maxRelease = alice_aave_vault.maxRelease();
        uint256 userCollateral = totalAssets - maxRelease;
        
        // Assuming standard Aave behavior:
        B = totalDebtBase; 
        
        // Calculate C manually
        // Price of awethWrapper in Base Currency
        uint256 awethWrapperPrice = uint(aWETHWrapper.latestAnswer());
        // userCollateral is in aWETHWrapper units (18 decimals)
        // C = userCollateral * price / 10^18
        C = (userCollateral * awethWrapperPrice) / 1e18;
    }

    function _assertInterpolating() internal view {
        (uint256 B, uint256 C) = _getBC();
        
        uint256 liqLTV_e = uint256(twyneVaultManager.externalLiqBuffers(address(aWETHWrapper))) 
            * uint256(getLiqLTV(address(aWETHWrapper), USDC)); 
            
        uint256 maxLTV_t = uint256(twyneVaultManager.maxTwyneLTVs(address(aWETHWrapper))); // 1e4 precision

        uint256 currentLTV = C > 0 ? (B * MAXFACTOR * MAXFACTOR) / C : 0; 

        uint256 currentLTV_1e8 = C > 0 ? (B * 1e8) / C : 0;

        bool isFullyLiquidated = MAXFACTOR * B >= maxLTV_t * C; 
        
        bool isSafeCase = MAXFACTOR * MAXFACTOR * B <= liqLTV_e * C;
        
        // Log for debugging
        console2.log("=== INTERPOLATION CHECK ===");
        console2.log("currentLTV_1e8", currentLTV_1e8);
        console2.log("liqLTV_e (1e8)", liqLTV_e);
        console2.log("maxLTV_t (1e4)", maxLTV_t);
        console2.log("isFullyLiquidated", isFullyLiquidated ? 1 : 0);
        console2.log("isSafeCase", isSafeCase ? 1 : 0);
        
        if (isFullyLiquidated || isSafeCase) {
             revert("not in interpolation band");
        }
    }

    function _snapshotBeforeLiquidation() internal view returns (LiquidationSnapshot memory snapshot) {
        snapshot.borrowerAWETH = IERC20(address(aWETHWrapper)).balanceOf(alice);
        snapshot.liquidatorAWETH = IERC20(address(aWETHWrapper)).balanceOf(liquidator);
        snapshot.vaultDebt = IERC20(address(aDebtUSDC)).balanceOf(address(alice_aave_vault));
        snapshot.borrower = alice_aave_vault.borrower();
        snapshot.maxRepay = alice_aave_vault.maxRepay();
        snapshot.totalAssets = alice_aave_vault.totalAssetsDepositedOrReserved();
        snapshot.maxRelease = alice_aave_vault.maxRelease();
        snapshot.vaultAWETH = IERC20(address(aWETHWrapper)).balanceOf(address(alice_aave_vault));
        snapshot.vaultUSDC = IERC20(USDC).balanceOf(address(alice_aave_vault));

        (uint256 B, uint256 C) = _getBC();
        snapshot.expectedCollateralForBorrower = alice_aave_vault.collateralForBorrower(B, C);
        
        // Log values for Python comparison (matching Euler test format)
        console2.log("=== SNAPSHOT DEBUG ===");
        console2.log("B (debt) at snapshot", B);
        console2.log("C (collateral) at snapshot", C);
        uint256 liquidation_ltv_bps = alice_aave_vault.twyneLiqLTV();
        console2.log("liquidation_ltv", liquidation_ltv_bps);
        console2.log("expectedCollateralForBorrower", snapshot.expectedCollateralForBorrower);
        
        // Also log price and userCollateral for USD conversion
        uint256 userCollateral = alice_aave_vault.totalAssetsDepositedOrReserved() - alice_aave_vault.maxRelease();
        uint256 awethWrapperPrice = uint(aWETHWrapper.latestAnswer());
        console2.log("userCollateral (token units)", userCollateral);
        console2.log("awethWrapperPrice (base currency)", awethWrapperPrice);
        
        // Log Aave-specific liquidation LTV for Python model
        uint256 liqLTV_e = uint256(twyneVaultManager.externalLiqBuffers(address(aWETHWrapper))) 
            * uint256(getLiqLTV(address(aWETHWrapper), USDC));
        console2.log("liqLTV_e (external liquidation LTV, 1e8)", liqLTV_e);
    }

    function _assertAfterLiquidationAndRepay(LiquidationSnapshot memory before) internal view {
        uint256 borrowerAWETHAfter = IERC20(address(aWETHWrapper)).balanceOf(alice);
        uint256 liquidatorAWETHAfter = IERC20(address(aWETHWrapper)).balanceOf(liquidator);

        uint256 actualCollateralTransferred = borrowerAWETHAfter - before.borrowerAWETH;
        
        assertApproxEqAbs(
            before.liquidatorAWETH - liquidatorAWETHAfter, 
            actualCollateralTransferred, 
            10,
            "liquidator decrease should equal borrower increase"
        );

        assertApproxEqAbs(
            actualCollateralTransferred,
            before.expectedCollateralForBorrower,
            10,
            "actual transfer should match snapshot collateralForBorrower calculation"
        );

        assertEq(alice_aave_vault.borrower(), liquidator, "vault borrower should be liquidator");
        
        // Debt reduced?
        // In `executeLiquidationWithRepay`, we call `repay`.
        uint256 vaultDebtAfter = IERC20(address(aDebtUSDC)).balanceOf(address(alice_aave_vault));
        // We repaid `maxRepay` which is total debt.
        assertEq(vaultDebtAfter, 0, "debt should be 0 after full repay");
        
        assertFalse(alice_aave_vault.canLiquidate(), "vault should not be liquidatable after repay");
    }

    /////////////////////////////////////////////////
    /// Numeric parity traces vs. python reference ///
    /// These tests isolate the pure base-currency math (B,C, penalties) and then
    /// dump every conversion step so off-chain scripts can ingest the
    /// exact Solidity dataset and reproduce it 1:1.
    /////////////////////////////////////////////////

    function _traceLiquidationMath(
        string memory label,
        uint256 priceDropPct,
        uint256 collateral,
        uint256 clp,
        uint256 borrow,
        uint256 twyneLTV
    ) internal {
        console2.log("=== LIQUIDATION MATH TRACE ===");
        console2.log("Label", label);
        createInitialPosition(collateral, clp, borrow, twyneLTV);
        executePriceDrop(priceDropPct);
        _traceLiquidationMathCurrentState(label);
    }

    function _traceLiquidationMathCurrentState(string memory label) internal view {
        console2.log("=== LIQUIDATION MATH TRACE ===");
        console2.log("Label", label);

        (uint256 B, uint256 C) = _getBC();

        uint256 rawBase = LiquidationMath.borrowerCollateralBase(
            B,
            C,
            twyneVaultManager.externalLiqBuffers(address(aWETHWrapper)),
            getLiqLTV(address(aWETHWrapper), USDC),
            twyneVaultManager.maxTwyneLTVs(address(aWETHWrapper))
        );

        console2.log("B (totalDebtBase)", B);
        console2.log("C (collateralBase)", C);
        console2.log("LiquidationMath raw base", rawBase);

        if (rawBase == 0) {
            console2.log("convertBaseToCollateral skipped (rawBase == 0)");
            return;
        }

        (
            uint256 usdValue,
            uint256 collateralAmount,
            uint256 availableUserCollateral,
            uint256 pricePerUnit,
            uint256 wrapperDecimals
        ) = _convertBaseToCollateralDebug(rawBase);

        console2.log("convertBaseToCollateral usdValue", usdValue);
        console2.log("convertBaseToCollateral collateralAmount (token units)", collateralAmount);
        console2.log("convertBaseToCollateral availableUserCollateral (token units)", availableUserCollateral);
        console2.log("convertBaseToCollateral pricePerUnit (base)", pricePerUnit);
        console2.log("convertBaseToCollateral wrapperDecimals", wrapperDecimals);
        console2.log("totalAssetsDepositedOrReserved", alice_aave_vault.totalAssetsDepositedOrReserved());
        console2.log("maxRelease", alice_aave_vault.maxRelease());
    }

    /// @notice Mirrors AaveV3CollateralVault._convertBaseToCollateral for debugging
    function _convertBaseToCollateralDebug(uint256 collateralValue)
        internal
        view
        returns (
            uint256 usdValue,
            uint256 collateralAmount,
            uint256 availableUserCollateral,
            uint256 pricePerUnit,
            uint256 wrapperDecimals
        )
    {
        usdValue = collateralValue;

        // price is base-currency per 1 token unit (8 decimals typically)
        pricePerUnit = uint256(uint(aWETHWrapper.latestAnswer()));
        wrapperDecimals = IERC20Metadata(address(aWETHWrapper)).decimals();

        // userCollateralShares (token units) = totalAssets - reserved
        availableUserCollateral = alice_aave_vault.totalAssetsDepositedOrReserved() - alice_aave_vault.maxRelease();

        // collateralAmount = collateralValue * 10**wrapperDecimals / price
        collateralAmount = pricePerUnit == 0 ? 0 : (collateralValue * (10 ** wrapperDecimals)) / pricePerUnit;

        // apply cap as in the vault
        collateralAmount = Math.min(availableUserCollateral, collateralAmount);
    }

    // --- Tests ---

    function test_a_expectRevert_internalLiquidation_case00() external noGasMetering {
        createInitialPosition(5e18, 0, 8000e6, 9000); // 8000 USDC debt
        
        // Small price drop, still healthy
        executePriceDrop(2);
        
        setup_approve_customSetup();
        
        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.HealthyNotLiquidatable.selector);
        alice_aave_vault.liquidate();
        vm.stopPrank();
    }

    // LTV at upper limit before interpolation (Aave analog of Euler case01)
    function test_a_expectRevert_internalLiquidation_case01() external noGasMetering {
        createInitialPosition(5e18, 0, 16_000e6, 9000);

        // Warp a bit to avoid edge-time assumptions in downstream integrations
        vm.warp(block.timestamp + 1);

        // This is intentionally tuned to be just below liquidation threshold for Aave base-currency math.
        // If it ever drifts (fork state changes), the `assertFalse(canLiquidate())` will catch it.
        executePriceDrop(9);

        setup_approve_customSetup();

        assertFalse(alice_aave_vault.canLiquidate(), "vault should not be liquidatable at boundary");

        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.HealthyNotLiquidatable.selector);
        alice_aave_vault.liquidate();
        vm.stopPrank();
    }

    function test_a_internalLiquidation_case10() external noGasMetering {
        createInitialPosition(5e18, 0, 12000e6, 8500);
        
        executePriceDrop(32);
        
        _assertInterpolating();
        
        setup_approve_customSetup();
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_a_internalLiquidation_case11() external noGasMetering {
        createInitialPosition(5e18, 0, 12000e6, 8500);
        
        executePriceDrop(34);
        
        _assertInterpolating();
        
        setup_approve_customSetup();
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_a_internalLiquidation_case12() external noGasMetering {
        createInitialPosition(5e18, 0, 12000e6, 8500);
        
        executePriceDrop(35);
        
        _assertInterpolating();
        
        setup_approve_customSetup();
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_a_internalLiquidation_case13() external noGasMetering {
        createInitialPosition(5e18, 0, 12000e6, 8500);
        
        executePriceDrop(36);
        
        _assertInterpolating();
        
        setup_approve_customSetup();
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    // Case 14 & 15 proof that results are the same as case 12 & 13, but different liq ltv
    // this validates the idea that interpolation is not affected by liq ltv
    function test_a_internalLiquidation_case14() external noGasMetering {
        createInitialPosition(5e18, 0, 12000e6, 9000);
        
        executePriceDrop(35);
        
        _assertInterpolating();
        
        setup_approve_customSetup();
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_a_internalLiquidation_case15() external noGasMetering {
        createInitialPosition(5e18, 0, 12000e6, 9000);
        
        executePriceDrop(36);
        
        _assertInterpolating();
        
        setup_approve_customSetup();
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_a_internalLiquidation_case20() external noGasMetering {
        createInitialPosition(5e18, 0, 12000e6, 9000);
        
        executePriceDrop(40);
        
        setup_approve_customSetup();
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_a_internalLiquidation_case21() external noGasMetering {
        createInitialPosition(5e18, 0, 12000e6, 9000);
        
        executePriceDrop(42);
        
        setup_approve_customSetup();
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_a_internalLiquidation_case22() external noGasMetering {
        createInitialPosition(5e18, 0, 12000e6, 9000);
        
        executePriceDrop(45);
        
        setup_approve_customSetup();
        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    // --- Corner cases ---

    // If current LTV > 100% (max branch), liquidation still proceeds (liquidator may lose money)
    function test_a_internalLiquidation_case_ltv_higher_than_max() external noGasMetering {
        createInitialPosition(5e18, 0, 12_000e6, 9000);

        // Large price drop to push LTV above maxLTV_t
        executePriceDrop(70);

        // Ensure we are in the "fully liquidated" branch (MAXFACTOR * B >= maxLTV_t * C)
        (uint256 B, uint256 C) = _getBC();
        uint256 maxLTV_t = uint256(twyneVaultManager.maxTwyneLTVs(address(aWETHWrapper)));
        assertTrue(MAXFACTOR * B >= maxLTV_t * C, "not in fully-liquidated branch");

        setup_approve_customSetup();
        _fundLiquidatorWithCollateral(alice_aave_vault.collateralForBorrower(B, C));

        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    // Insolvency / extreme price crash branch
    function test_a_internalLiquidation_insolvency() external noGasMetering {
        createInitialPosition(5e18, 0, 12_000e6, 9000);

        executePriceDrop(90);

        (uint256 B, uint256 C) = _getBC();
        setup_approve_customSetup();
        _fundLiquidatorWithCollateral(alice_aave_vault.collateralForBorrower(B, C));

        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_liquidationMathUSD_case10() external noGasMetering {
        _traceLiquidationMath("Case10 (32% drop)", 32, 5e18, 0, 12_000e6, 8500);
    }

    function test_liquidationMathUSD_case11() external noGasMetering {
        _traceLiquidationMath("Case11 (34% drop)", 34, 5e18, 0, 12_000e6, 8500);
    }

    function test_liquidationMathUSD_case12() external noGasMetering {
        _traceLiquidationMath("Case12 (35% drop)", 35, 5e18, 0, 12_000e6, 8500);
    }

    function test_liquidationMathUSD_case13() external noGasMetering {
        _traceLiquidationMath("Case13 (36% drop)", 36, 5e18, 0, 12_000e6, 8500);
    }

    function test_liquidationMathUSD_case20() external noGasMetering {
        _traceLiquidationMath("Case20 (40% drop, twyneLTV 90%)", 40, 5e18, 0, 12_000e6, 9000);
    }

    function test_liquidationMathUSD_case21() external noGasMetering {
        _traceLiquidationMath("Case21 (42% drop, twyneLTV 90%)", 42, 5e18, 0, 12_000e6, 9000);
    }

    function test_liquidationMathUSD_case22() external noGasMetering {
        _traceLiquidationMath("Case22 (45% drop, twyneLTV 90%)", 45, 5e18, 0, 12_000e6, 9000);
    }

    // --- Low-value precision cases (dust-scale) ---

    function test_a_internalLiquidation_lowValues_case10() external noGasMetering {
        // Dust-scale position: ~0.001 WETH collateral, ~2.2 USDC debt
        // Tuned so post-drop LTV lands in the interpolation band (β_safe*λ̃_e < LTV < λ̃_t^max).
        createInitialPosition(1e15, 0, 22e5, 8500);

        executePriceDrop(37);
        _assertInterpolating();
        assertTrue(alice_aave_vault.canLiquidate(), "vault should be liquidatable (lowValues case10)");

        setup_approve_customSetup();
        (uint256 B, uint256 C) = _getBC();
        _fundLiquidatorWithCollateral(alice_aave_vault.collateralForBorrower(B, C));

        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_a_internalLiquidation_lowValues_case11() external noGasMetering {
        createInitialPosition(1e15, 0, 22e5, 8500);

        executePriceDrop(38);
        _assertInterpolating();
        assertTrue(alice_aave_vault.canLiquidate(), "vault should be liquidatable (lowValues case11)");

        setup_approve_customSetup();
        (uint256 B, uint256 C) = _getBC();
        _fundLiquidatorWithCollateral(alice_aave_vault.collateralForBorrower(B, C));

        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_a_internalLiquidation_lowValues_case12() external noGasMetering {
        createInitialPosition(1e15, 0, 22e5, 8500);

        executePriceDrop(39);
        _assertInterpolating();
        assertTrue(alice_aave_vault.canLiquidate(), "vault should be liquidatable (lowValues case12)");

        setup_approve_customSetup();
        (uint256 B, uint256 C) = _getBC();
        _fundLiquidatorWithCollateral(alice_aave_vault.collateralForBorrower(B, C));

        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    function test_a_internalLiquidation_lowValues_case13() external noGasMetering {
        createInitialPosition(1e15, 0, 22e5, 8500);

        executePriceDrop(40);
        _assertInterpolating();
        assertTrue(alice_aave_vault.canLiquidate(), "vault should be liquidatable (lowValues case13)");

        setup_approve_customSetup();
        (uint256 B, uint256 C) = _getBC();
        _fundLiquidatorWithCollateral(alice_aave_vault.collateralForBorrower(B, C));

        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    /////////////////////////////////////////////////////////////////
    ///////////////// Python-parity-style scenarios //////////////////
    /////////////////////////////////////////////////////////////////

    /// @dev Aave-adapted version of Euler's Python V2 scenario #1 (96% LTV vs 95% threshold)
    function test_a_replicatePythonV2Liquidation_test1() external noGasMetering {
        vm.startPrank(admin);
        twyneVaultManager.setExternalLiqBuffer(address(aWETHWrapper), 0.99e4); // 99%
        twyneVaultManager.setMaxLiquidationLTV(address(aWETHWrapper), 0.97e4); // 97%
        vm.stopPrank();

        // Target: C ~= 10,000 base units, B ~= 9,600 base units, liquidation threshold 95%
        uint256 targetCollateralBase = 10_000 * 1e8;
        uint256 targetDebtUSDC = 9_600 * 1e6;
        uint256 twyneLTV = 9500;

        uint256 priceDropPct = 10; // 10%
        uint256 price0 = uint256(uint(aWETHWrapper.latestAnswer()));
        uint256 newPrice = price0 * (100 - priceDropPct) / 100;
        uint256 collateralAmount = newPrice == 0 ? 0 : (targetCollateralBase * 1e18) / newPrice;

        createInitialPosition(collateralAmount, 0, targetDebtUSDC, twyneLTV);
        executePriceDrop(priceDropPct);

        (uint256 B_final, uint256 C_final) = _getBC();
        uint256 ltv_bps = C_final > 0 ? (B_final * MAXFACTOR) / C_final : 0;
        console2.log("PythonTest1 B_final", B_final);
        console2.log("PythonTest1 C_final", C_final);
        console2.log("PythonTest1 LTV(bps)", ltv_bps);

        assertApproxEqAbs(ltv_bps, 9600, 250, "LTV should be ~96%");
        assertTrue(alice_aave_vault.canLiquidate(), "position should be liquidatable");

        setup_approve_customSetup();
        _fundLiquidatorWithCollateral(alice_aave_vault.collateralForBorrower(B_final, C_final));

        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    /// @dev Aave-adapted version of Euler's Python V2 scenario #2 (93.5% LTV vs 92% threshold)
    function test_a_replicatePythonV2Liquidation_test2() external noGasMetering {
        vm.startPrank(admin);
        twyneVaultManager.setExternalLiqBuffer(address(aWETHWrapper), 0.99e4); // 99%
        twyneVaultManager.setMaxLiquidationLTV(address(aWETHWrapper), 0.97e4); // 97%
        vm.stopPrank();

        // Target: C ~= 10,000 base units, B ~= 9,350 base units, liquidation threshold 92%
        uint256 targetCollateralBase = 10_000 * 1e8;
        uint256 targetDebtUSDC = 9_350 * 1e6;
        uint256 twyneLTV = 9200;

        uint256 priceDropPct = 10; // 10%
        uint256 price0 = uint256(uint(aWETHWrapper.latestAnswer()));
        uint256 newPrice = price0 * (100 - priceDropPct) / 100;
        uint256 collateralAmount = newPrice == 0 ? 0 : (targetCollateralBase * 1e18) / newPrice;

        createInitialPosition(collateralAmount, 0, targetDebtUSDC, twyneLTV);
        executePriceDrop(priceDropPct);

        (uint256 B_final, uint256 C_final) = _getBC();
        uint256 ltv_bps = C_final > 0 ? (B_final * MAXFACTOR) / C_final : 0;
        console2.log("PythonTest2 B_final", B_final);
        console2.log("PythonTest2 C_final", C_final);
        console2.log("PythonTest2 LTV(bps)", ltv_bps);

        assertApproxEqAbs(ltv_bps, 9350, 250, "LTV should be ~93.5%");
        assertTrue(alice_aave_vault.canLiquidate(), "position should be liquidatable");

        setup_approve_customSetup();
        _fundLiquidatorWithCollateral(alice_aave_vault.collateralForBorrower(B_final, C_final));

        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    /////////////////////////////////////////////////////////////////
    ///////////////// /////Fuzzing Tests /////////////////////////////
    /////////////////////////////////////////////////////////////////

    /// @notice Fuzz test for collateralForBorrower function (pure math + conversion caps)
    function testFuzz_collateralForBorrower(uint256 B, uint256 C) public noGasMetering {
        createInitialPosition(5e18, 0, 12_000e6, 9000);

        // Aave base currency values (typically 8 decimals)
        B = bound(B, 1e6, 1e18);
        C = bound(C, 1e6, 1e18);

        // Ensure C >= B to avoid trivially insolvent inputs for monotonic checks
        if (C < B) C = B + bound(C, 1, 1e8);

        uint256 result = alice_aave_vault.collateralForBorrower(B, C);

        // Result should never exceed available user collateral (cap in _convertBaseToCollateral)
        uint256 availableUserCollateral =
            alice_aave_vault.totalAssetsDepositedOrReserved() - alice_aave_vault.maxRelease();
        assertLe(result, availableUserCollateral, "result should be capped by user collateral");

        // If fully liquidated (LTV >= maxLTV_t), result should be 0
        uint256 maxLTV_t = uint256(twyneVaultManager.maxTwyneLTVs(address(aWETHWrapper)));
        if (MAXFACTOR * B >= maxLTV_t * C) {
            assertEq(result, 0, "fully liquidated position should return 0");
        }

        // Monotonicity (weak): increasing C should not decrease result
        if (C < type(uint256).max) {
            uint256 resultCPlus1 = alice_aave_vault.collateralForBorrower(B, C + 1);
            assertGe(resultCPlus1, result, "result should not decrease with more collateral value");
        }

        // Monotonicity (weak): increasing B should not increase result (when not in fully-liquidated branch)
        if (B < type(uint256).max && MAXFACTOR * (B + 1) < maxLTV_t * C) {
            uint256 resultBPlus1 = alice_aave_vault.collateralForBorrower(B + 1, C);
            assertLe(resultBPlus1, result, "result should not increase with more debt value");
        }
    }

    function testFuzz_liquidation_holistics(
        uint256 collateralAmount, // aWETHWrapper units (18 decimals)
        uint256 debtAmount, // USDC units (6 decimals)
        uint256 priceDropPct,
        uint256 twyneLTV
    ) public noGasMetering {
        collateralAmount = bound(collateralAmount, 1e18, 7e18);
        twyneLTV = uint16(bound(twyneLTV, 8500, 9300));

        // Conservative estimate: 1 WETH ≈ $3500
        uint256 maxDebtForCollateral = (collateralAmount * 3500e6 * twyneLTV) / (1e18 * 10000);
        uint256 minDebt = 1e6;
        uint256 maxDebt = maxDebtForCollateral < 20_000e6 ? maxDebtForCollateral : 20_000e6;
        debtAmount = bound(debtAmount, minDebt, maxDebt);

        // executePriceDrop() interprets this as percentage points (0..100)
        priceDropPct = bound(priceDropPct, 0, 90);

        createInitialPosition(collateralAmount, 0, debtAmount, twyneLTV);
        executePriceDrop(priceDropPct);

        vm.assume(alice_aave_vault.canLiquidate());

        setup_approve_customSetup();
        (uint256 B, uint256 C) = _getBC();
        _fundLiquidatorWithCollateral(alice_aave_vault.collateralForBorrower(B, C));

        LiquidationSnapshot memory snapshot = _snapshotBeforeLiquidation();
        executeLiquidationWithRepay();
        _assertAfterLiquidationAndRepay(snapshot);
    }

    /////////////////////////////////////////////////////////////////
    ///////////////// /////Revert Tests /////////////////////////////
    /////////////////////////////////////////////////////////////////

    /// @notice Test that borrower cannot liquidate their own position
    function test_a_expectRevert_selfLiquidation() external noGasMetering {
        createInitialPosition(5e18, 0, 12_000e6, 8500);

        executePriceDrop(35);

        assertTrue(alice_aave_vault.canLiquidate(), "vault should be liquidatable for self-liquidation test");

        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.SelfLiquidation.selector);
        alice_aave_vault.liquidate();
        vm.stopPrank();
    }

    /// @notice Test that liquidate() reverts when vault is externally liquidated on Aave
    function test_a_expectRevert_externallyLiquidated() external noGasMetering {
        createInitialPosition(5e18, 0, 12_000e6, 8500);

        // Make the position unhealthy enough that Aave liquidation is possible
        executePriceDrop(80);

        // to ensure vaults are out of liquidation cool off period / avoid boundary behavior
        vm.warp(block.timestamp + 2);

        assertFalse(alice_aave_vault.isExternallyLiquidated(), "vault should not be externally liquidated initially");

        // Perform an Aave external liquidation against the vault
        uint256 maxrepay = alice_aave_vault.maxRepay();
        assertGt(maxrepay, 0, "vault should have debt to liquidate externally");

        deal(USDC, liquidator, maxrepay + 1_000_000);
        vm.startPrank(liquidator);
        IERC20(USDC).approve(aavePool, type(uint256).max);
        IAaveV3Pool(aavePool).liquidationCall({
            collateralAsset: WETH,
            debtAsset: USDC,
            borrower: address(alice_aave_vault),
            debtToCover: maxrepay,
            receiveAToken: false
        });
        vm.stopPrank();

        // Now the vault should be flagged as externally liquidated (scaledBalance < tracked totalAssets)
        assertTrue(alice_aave_vault.isExternallyLiquidated(), "vault should be externally liquidated");

        // Internal liquidation should revert with ExternallyLiquidated
        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.ExternallyLiquidated.selector);
        alice_aave_vault.liquidate();
        vm.stopPrank();
    }

    /// @notice Test that liquidate() reverts when vault is healthy (not liquidatable)
    function test_a_expectRevert_healthyNotLiquidatable() external noGasMetering {
        createInitialPosition(5e18, 0, 8_000e6, 9000);

        executePriceDrop(2);

        setup_approve_customSetup();

        assertFalse(alice_aave_vault.canLiquidate(), "vault should not be liquidatable");

        vm.startPrank(liquidator);
        vm.expectRevert(TwyneErrors.HealthyNotLiquidatable.selector);
        alice_aave_vault.liquidate();
        vm.stopPrank();
    }
    
}

