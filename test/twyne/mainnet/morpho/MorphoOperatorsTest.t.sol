// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MorphoTestBase, console2} from "./MorphoTestBase.t.sol";
import {MorphoCollateralVault, CollateralVaultBase} from "src/twyne/MorphoCollateralVault.sol";
import {MorphoTeleportOperator} from "src/operators/MorphoTeleportOperator.sol";
import {MorphoLeverageOperator} from "src/operators/MorphoLeverageOperator.sol";
import {MorphoDeleverageOperator} from "src/operators/MorphoDeleverageOperator.sol";
import {MockSwapper} from "test/mocks/MockSwapper.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";
import {IEvents} from "src/interfaces/IEvents.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IMorpho, MarketParams, Id} from "morpho/interfaces/IMorpho.sol";
import {MorphoLib} from "morpho/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "morpho/libraries/periphery/MorphoBalancesLib.sol";
import {MarketParamsLib} from "morpho/libraries/MarketParamsLib.sol";
import {IOracle} from "morpho/interfaces/IOracle.sol";
import {ORACLE_PRICE_SCALE} from "morpho/libraries/ConstantsLib.sol";
import {MathLib} from "morpho/libraries/MathLib.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {BeaconProxy} from "openzeppelin-contracts/proxy/beacon/BeaconProxy.sol";
import {Create2} from "openzeppelin-contracts/utils/Create2.sol";

contract MorphoOperatorsTest is MorphoTestBase, IEvents {
    using MathLib for uint;

    MorphoTeleportOperator morphoTeleportOperator;
    MorphoLeverageOperator morphoLeverageOperator;
    MorphoDeleverageOperator morphoDeleverageOperator;
    address mockSwapperAddr;

    // Alice's direct Morpho position parameters
    uint constant DIRECT_COLLATERAL = 10 ether; // 10 WSTETH
    uint directDebt; // Calculated in setUp based on oracle price

    function setUp() public override {
        super.setUp();

        // Deploy MockSwapper and etch it at a fixed address for predictability
        MockSwapper mockSwapper = new MockSwapper();
        mockSwapperAddr = address(mockSwapper);
        vm.label(mockSwapperAddr, "mockSwapper");

        // Deploy MorphoTeleportOperator
        morphoTeleportOperator = new MorphoTeleportOperator(
            address(evc),
            morpho,
            address(collateralVaultFactory)
        );
        vm.label(address(morphoTeleportOperator), "morphoTeleportOperator");

        // Deploy MorphoLeverageOperator
        morphoLeverageOperator = new MorphoLeverageOperator(
            address(evc),
            mockSwapperAddr,
            morpho,
            address(collateralVaultFactory),
            permit2
        );
        vm.label(address(morphoLeverageOperator), "morphoLeverageOperator");

        // Deploy MorphoDeleverageOperator
        morphoDeleverageOperator = new MorphoDeleverageOperator(
            address(evc),
            mockSwapperAddr,
            morpho,
            address(collateralVaultFactory)
        );
        vm.label(address(morphoDeleverageOperator), "morphoDeleverageOperator");

        // Calculate a safe borrow amount (80% of max)
        uint collateralPrice = IOracle(MO_ORACLE).price();
        directDebt = DIRECT_COLLATERAL.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).wMulDown(MO_LLTV) * 80 / 100;
    }

    /// @dev Helper: Create a direct Morpho Blue position for alice
    function _createDirectMorphoPosition() internal {
        vm.startPrank(alice);
        IERC20(MO_COLLATERAL_TOKEN).approve(morpho, DIRECT_COLLATERAL);
        IMorpho(morpho).supplyCollateral(morphoMarketParams, DIRECT_COLLATERAL, alice, "");
        IMorpho(morpho).borrow(morphoMarketParams, directDebt, 0, alice, alice);
        vm.stopPrank();

        // Verify position
        assertEq(MorphoLib.collateral(IMorpho(morpho), morphoMarketId, alice), DIRECT_COLLATERAL, "Direct collateral mismatch");
        assertGt(MorphoLib.borrowShares(IMorpho(morpho), morphoMarketId, alice), 0, "Should have borrow shares");
    }

    /// @dev Helper: Create collateral vault + set approvals for teleport
    function _setupTeleport() internal {
        // Credit deposit first
        morpho_creditDeposit(MO_COLLATERAL_TOKEN);

        // Create direct Morpho position
        _createDirectMorphoPosition();

        // Create MorphoCollateralVault for alice
        vm.startPrank(alice);
        collateralVaultFactory.createMorphoCollateralVault({
            _intermediateVault: address(morpho_intermediate_vault),
            _targetVault: morpho,
            _marketParams: morphoMarketParams,
            _liqLTV: twyneLiqLTV
        });
        address[] memory vaults = collateralVaultFactory.getCollateralVaults(alice);
        alice_morpho_vault = MorphoCollateralVault(vaults[vaults.length - 1]);
        vm.label(address(alice_morpho_vault), "alice_morpho_vault");

        // Authorize teleport operator on Morpho (required for withdrawCollateral onBehalf)
        IMorpho(morpho).setAuthorization(address(morphoTeleportOperator), true);

        // Enable teleport operator on EVC
        evc.setAccountOperator(alice, address(morphoTeleportOperator), true);
        vm.stopPrank();
    }

    /// @dev Helper: Create direct Morpho collateral-only position + set approvals for teleport
    function _setupTeleportNoDebt() internal {
        morpho_creditDeposit(MO_COLLATERAL_TOKEN);

        vm.startPrank(alice);
        IERC20(MO_COLLATERAL_TOKEN).approve(morpho, DIRECT_COLLATERAL);
        IMorpho(morpho).supplyCollateral(morphoMarketParams, DIRECT_COLLATERAL, alice, "");

        collateralVaultFactory.createMorphoCollateralVault({
            _intermediateVault: address(morpho_intermediate_vault),
            _targetVault: morpho,
            _marketParams: morphoMarketParams,
            _liqLTV: twyneLiqLTV
        });
        address[] memory vaults = collateralVaultFactory.getCollateralVaults(alice);
        alice_morpho_vault = MorphoCollateralVault(vaults[vaults.length - 1]);

        IMorpho(morpho).setAuthorization(address(morphoTeleportOperator), true);
        evc.setAccountOperator(alice, address(morphoTeleportOperator), true);
        vm.stopPrank();
    }

    // ==========================================
    // Happy path tests
    // ==========================================

    /// @notice Full teleport: migrate entire Morpho position to CollateralVault
    function test_morpho_teleport_success() public noGasMetering {
        _setupTeleport();

        uint collateralBefore = MorphoLib.collateral(IMorpho(morpho), morphoMarketId, alice);
        uint debtBefore = MorphoBalancesLib.expectedBorrowAssets(IMorpho(morpho), morphoMarketParams, alice);

        vm.startPrank(alice);
        morphoTeleportOperator.executeTeleport(
            address(alice_morpho_vault),
            type(uint).max, // full collateral
            type(uint).max // full debt
        );
        vm.stopPrank();

        // Verify direct Morpho position is closed
        assertEq(MorphoLib.collateral(IMorpho(morpho), morphoMarketId, alice), 0, "Direct collateral should be zero");
        assertEq(MorphoLib.borrowShares(IMorpho(morpho), morphoMarketId, alice), 0, "Direct borrow shares should be zero");

        // Verify position migrated to collateral vault
        uint vaultUserCollateral = alice_morpho_vault.totalAssetsDepositedOrReserved() - alice_morpho_vault.maxRelease();
        assertApproxEqAbs(vaultUserCollateral, collateralBefore, 1, "Vault should have migrated collateral");
        assertApproxEqAbs(alice_morpho_vault.maxRepay(), debtBefore, 2, "Vault should have migrated debt");

        // Verify vault has collateral in Morpho
        assertGt(alice_morpho_vault.collateralBalance(), 0, "Vault should have Morpho collateral position");
    }

    /// @notice Teleport with explicit amounts (not type(uint).max)
    function test_morpho_teleport_explicitAmounts() public noGasMetering {
        _setupTeleport();

        uint collateralBefore = MorphoLib.collateral(IMorpho(morpho), morphoMarketId, alice);
        uint debtBefore = MorphoBalancesLib.expectedBorrowAssets(IMorpho(morpho), morphoMarketParams, alice);

        vm.startPrank(alice);
        morphoTeleportOperator.executeTeleport(
            address(alice_morpho_vault),
            collateralBefore,
            debtBefore
        );
        vm.stopPrank();

        // Verify direct position is closed
        assertEq(MorphoLib.collateral(IMorpho(morpho), morphoMarketId, alice), 0, "Direct collateral should be zero");
        assertEq(MorphoLib.borrowShares(IMorpho(morpho), morphoMarketId, alice), 0, "Direct borrow shares should be zero");

        // Verify vault state
        uint vaultUserCollateral = alice_morpho_vault.totalAssetsDepositedOrReserved() - alice_morpho_vault.maxRelease();
        assertApproxEqAbs(vaultUserCollateral, collateralBefore, 1, "Vault collateral mismatch");
        assertApproxEqAbs(alice_morpho_vault.maxRepay(), debtBefore, 2, "Vault debt mismatch");
    }

    /// @notice Teleport with partial debt migrates only requested debt amount
    function test_morpho_teleport_partialDebt_migratesPartialDebt() public noGasMetering {
        _setupTeleport();

        uint collateralBefore = MorphoLib.collateral(IMorpho(morpho), morphoMarketId, alice);
        uint debtBefore = MorphoBalancesLib.expectedBorrowAssets(IMorpho(morpho), morphoMarketParams, alice);

        uint collateralToTeleport = collateralBefore / 2;
        uint debtToTeleport = debtBefore / 2;

        vm.startPrank(alice);
        morphoTeleportOperator.executeTeleport(
            address(alice_morpho_vault),
            collateralToTeleport,
            debtToTeleport
        );
        vm.stopPrank();

        uint directCollateralAfter = MorphoLib.collateral(IMorpho(morpho), morphoMarketId, alice);
        uint directDebtAfter = MorphoBalancesLib.expectedBorrowAssets(IMorpho(morpho), morphoMarketParams, alice);

        // Direct position should remain open with the non-migrated portion.
        assertApproxEqAbs(directCollateralAfter, collateralBefore - collateralToTeleport, 1, "Direct collateral mismatch");
        assertApproxEqAbs(directDebtAfter, debtBefore - debtToTeleport, 2, "Direct debt mismatch");

        // Vault should only take on the requested migrated debt amount.
        uint vaultUserCollateral = alice_morpho_vault.totalAssetsDepositedOrReserved() - alice_morpho_vault.maxRelease();
        assertApproxEqAbs(vaultUserCollateral, collateralToTeleport, 1, "Vault collateral mismatch");
        assertApproxEqAbs(alice_morpho_vault.maxRepay(), debtToTeleport, 2, "Vault debt mismatch");
    }

    /// @notice Teleport with explicit debt above actual debt should not over-borrow
    function test_morpho_teleport_explicitDebtAboveActual_noOverborrow() public noGasMetering {
        _setupTeleport();

        uint collateralBefore = MorphoLib.collateral(IMorpho(morpho), morphoMarketId, alice);
        uint debtBefore = MorphoBalancesLib.expectedBorrowAssets(IMorpho(morpho), morphoMarketParams, alice);
        uint explicitDebtInput = debtBefore + 0.1 ether;

        vm.startPrank(alice);
        morphoTeleportOperator.executeTeleport(
            address(alice_morpho_vault),
            collateralBefore,
            explicitDebtInput
        );
        vm.stopPrank();

        // Verify direct position is closed
        assertEq(MorphoLib.collateral(IMorpho(morpho), morphoMarketId, alice), 0, "Direct collateral should be zero");
        assertEq(MorphoLib.borrowShares(IMorpho(morpho), morphoMarketId, alice), 0, "Direct borrow shares should be zero");

        // Vault debt should match actual repaid debt, not oversized explicit input
        assertApproxEqAbs(alice_morpho_vault.maxRepay(), debtBefore, 2, "Vault debt mismatch");
        assertEq(
            IERC20(MO_LOAN_TOKEN).balanceOf(address(morphoTeleportOperator)),
            0,
            "Operator should not keep loan token leftovers"
        );
    }

    /// @notice Teleport after interest accrual
    function test_morpho_teleport_withInterestAccrued() public noGasMetering {
        _setupTeleport();

        // Warp to accrue interest (keep within oracle staleness window)
        vm.roll(block.number + 100);
        vm.warp(block.timestamp + 1 hours);

        uint debtAfterAccrual = MorphoBalancesLib.expectedBorrowAssets(IMorpho(morpho), morphoMarketParams, alice);
        assertGt(debtAfterAccrual, directDebt, "Debt should have grown from interest");

        uint collateralAmount = MorphoLib.collateral(IMorpho(morpho), morphoMarketId, alice);

        vm.startPrank(alice);
        morphoTeleportOperator.executeTeleport(
            address(alice_morpho_vault),
            type(uint).max,
            type(uint).max
        );
        vm.stopPrank();

        // Verify migration
        assertEq(MorphoLib.collateral(IMorpho(morpho), morphoMarketId, alice), 0, "Direct collateral should be zero");
        assertEq(MorphoLib.borrowShares(IMorpho(morpho), morphoMarketId, alice), 0, "Direct borrow shares should be zero");

        uint vaultUserCollateral = alice_morpho_vault.totalAssetsDepositedOrReserved() - alice_morpho_vault.maxRelease();
        assertApproxEqAbs(vaultUserCollateral, collateralAmount, 1, "Vault collateral mismatch");
        assertApproxEqAbs(alice_morpho_vault.maxRepay(), debtAfterAccrual, 2, "Vault debt mismatch");
    }

    /// @notice Teleport via EVC single batch: create vault, enable operator, teleport, disable operator
    function test_morpho_teleport_singleBatch() public noGasMetering {
        morpho_creditDeposit(MO_COLLATERAL_TOKEN);
        _createDirectMorphoPosition();

        vm.startPrank(alice);

        // Authorize teleport operator on Morpho (must be done before batch)
        IMorpho(morpho).setAuthorization(address(morphoTeleportOperator), true);

        // Predict the vault address using CREATE2
        address beacon = collateralVaultFactory.collateralVaultBeacon(morpho);
        uint currentNonce = collateralVaultFactory.nonce(alice);
        bytes32 salt = keccak256(abi.encodePacked(alice, currentNonce));
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(beacon, ""))
        );
        address predictedVault = Create2.computeAddress(salt, bytecodeHash, address(collateralVaultFactory));

        uint collateralAmount = MorphoLib.collateral(IMorpho(morpho), morphoMarketId, alice);
        uint debtAmount = MorphoBalancesLib.expectedBorrowAssets(IMorpho(morpho), morphoMarketParams, alice);

        // Build batch: create vault → enable operator → teleport → disable operator
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](4);

        items[0] = IEVC.BatchItem({
            targetContract: address(collateralVaultFactory),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(
                collateralVaultFactory.createMorphoCollateralVault,
                (address(morpho_intermediate_vault), morpho, morphoMarketParams, twyneLiqLTV)
            )
        });

        items[1] = IEVC.BatchItem({
            targetContract: address(evc),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeCall(IEVC.setAccountOperator, (alice, address(morphoTeleportOperator), true))
        });

        items[2] = IEVC.BatchItem({
            targetContract: address(morphoTeleportOperator),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(
                morphoTeleportOperator.executeTeleport,
                (predictedVault, collateralAmount, debtAmount)
            )
        });

        items[3] = IEVC.BatchItem({
            targetContract: address(evc),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeCall(IEVC.setAccountOperator, (alice, address(morphoTeleportOperator), false))
        });

        evc.batch(items);

        // Verify vault was created at predicted address
        assertTrue(collateralVaultFactory.isCollateralVault(predictedVault), "Vault should exist at predicted address");
        alice_morpho_vault = MorphoCollateralVault(predictedVault);

        // Verify teleport success
        assertEq(MorphoLib.collateral(IMorpho(morpho), morphoMarketId, alice), 0, "Direct collateral should be zero");
        assertEq(MorphoLib.borrowShares(IMorpho(morpho), morphoMarketId, alice), 0, "Direct borrow shares should be zero");

        uint vaultUserCollateral = alice_morpho_vault.totalAssetsDepositedOrReserved() - alice_morpho_vault.maxRelease();
        assertApproxEqAbs(vaultUserCollateral, collateralAmount, 1, "Vault collateral mismatch");
        assertApproxEqAbs(alice_morpho_vault.maxRepay(), debtAmount, 2, "Vault debt mismatch");

        // Verify operator is disabled
        assertFalse(evc.isAccountOperatorAuthorized(alice, address(morphoTeleportOperator)), "Operator should be disabled");

        vm.stopPrank();
    }

    /// @notice Verify position is functional after teleport (can borrow more, repay, withdraw)
    function test_morpho_teleport_positionFunctionalAfter() public noGasMetering {
        _setupTeleport();

        vm.startPrank(alice);
        morphoTeleportOperator.executeTeleport(
            address(alice_morpho_vault),
            type(uint).max,
            type(uint).max
        );

        // Verify we can still interact with the vault
        uint maxRepayBefore = alice_morpho_vault.maxRepay();
        assertGt(maxRepayBefore, 0, "Should have debt");

        // Repay all and withdraw
        IERC20(MO_LOAN_TOKEN).approve(address(alice_morpho_vault), type(uint).max);

        IEVC.BatchItem[] memory repayItems = new IEVC.BatchItem[](1);
        repayItems[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.repay, (type(uint).max))
        });
        evc.batch(repayItems);

        assertEq(alice_morpho_vault.maxRepay(), 0, "Debt should be zero after repay");

        // Withdraw all
        IEVC.BatchItem[] memory withdrawItems = new IEVC.BatchItem[](1);
        withdrawItems[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.withdraw, (type(uint).max, alice))
        });
        evc.batch(withdrawItems);

        assertEq(alice_morpho_vault.maxRelease(), 0, "No intermediate vault debt");
        assertEq(alice_morpho_vault.totalAssetsDepositedOrReserved(), 0, "No assets in vault");

        vm.stopPrank();
    }

    // ==========================================
    // Access control tests
    // ==========================================

    /// @notice Non-borrower cannot execute teleport
    function test_morpho_teleport_unauthorized() public {
        _setupTeleport();

        // Bob tries to teleport to Alice's vault
        vm.startPrank(bob);
        vm.expectRevert(TwyneErrors.T_CallerNotBorrower.selector);
        morphoTeleportOperator.executeTeleport(
            address(alice_morpho_vault),
            1 ether,
            1 ether
        );
        vm.stopPrank();
    }

    /// @notice Invalid collateral vault address reverts
    function test_morpho_teleport_invalidVault() public {
        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.T_InvalidCollateralVault.selector);
        morphoTeleportOperator.executeTeleport(
            address(0xdead),
            1 ether,
            1 ether
        );
        vm.stopPrank();
    }

    /// @notice Direct callback call reverts
    function test_morpho_teleport_callbackAccessControl() public {
        vm.expectRevert(TwyneErrors.T_CallerNotMorpho.selector);
        morphoTeleportOperator.onMorphoFlashLoan(1 ether, "");
    }

    /// @notice Teleport fails if operator not authorized on Morpho
    function test_morpho_teleport_noMorphoAuth() public {
        morpho_creditDeposit(MO_COLLATERAL_TOKEN);
        _createDirectMorphoPosition();

        // Create vault but do NOT authorize operator on Morpho
        vm.startPrank(alice);
        collateralVaultFactory.createMorphoCollateralVault({
            _intermediateVault: address(morpho_intermediate_vault),
            _targetVault: morpho,
            _marketParams: morphoMarketParams,
            _liqLTV: twyneLiqLTV
        });
        address[] memory vaults = collateralVaultFactory.getCollateralVaults(alice);
        alice_morpho_vault = MorphoCollateralVault(vaults[vaults.length - 1]);

        // Enable on EVC but NOT on Morpho
        evc.setAccountOperator(alice, address(morphoTeleportOperator), true);

        // Should revert because operator can't withdrawCollateral on behalf of alice
        vm.expectRevert();
        morphoTeleportOperator.executeTeleport(
            address(alice_morpho_vault),
            type(uint).max,
            type(uint).max
        );
        vm.stopPrank();
    }

    /// @notice Teleport fails if operator not set on EVC
    function test_morpho_teleport_noEVCOperator() public {
        morpho_creditDeposit(MO_COLLATERAL_TOKEN);
        _createDirectMorphoPosition();

        vm.startPrank(alice);
        collateralVaultFactory.createMorphoCollateralVault({
            _intermediateVault: address(morpho_intermediate_vault),
            _targetVault: morpho,
            _marketParams: morphoMarketParams,
            _liqLTV: twyneLiqLTV
        });
        address[] memory vaults = collateralVaultFactory.getCollateralVaults(alice);
        alice_morpho_vault = MorphoCollateralVault(vaults[vaults.length - 1]);

        // Authorize on Morpho but NOT on EVC
        IMorpho(morpho).setAuthorization(address(morphoTeleportOperator), true);

        // Should revert because EVC batch calls skim/borrow onBehalfOfAccount=alice
        // but operator is not authorized on EVC
        vm.expectRevert();
        morphoTeleportOperator.executeTeleport(
            address(alice_morpho_vault),
            type(uint).max,
            type(uint).max
        );
        vm.stopPrank();
    }

    // ==========================================
    // Edge case tests
    // ==========================================

    /// @notice No leftover tokens in operator after teleport
    function test_morpho_teleport_noLeftoverTokens() public noGasMetering {
        _setupTeleport();

        vm.startPrank(alice);
        morphoTeleportOperator.executeTeleport(
            address(alice_morpho_vault),
            type(uint).max,
            type(uint).max
        );
        vm.stopPrank();

        assertEq(
            IERC20(MO_LOAN_TOKEN).balanceOf(address(morphoTeleportOperator)),
            0,
            "Operator should have no loan token leftover"
        );
        assertEq(
            IERC20(MO_COLLATERAL_TOKEN).balanceOf(address(morphoTeleportOperator)),
            0,
            "Operator should have no collateral token leftover"
        );
    }

    /// @notice Teleport with zero debt input migrates collateral without opening Twyne debt
    function test_morpho_teleport_zeroDebt_movesCollateral() public noGasMetering {
        _setupTeleportNoDebt();

        uint collateralBefore = MorphoLib.collateral(IMorpho(morpho), morphoMarketId, alice);

        vm.startPrank(alice);
        morphoTeleportOperator.executeTeleport(
            address(alice_morpho_vault),
            type(uint).max,
            0
        );
        vm.stopPrank();

        assertEq(MorphoLib.collateral(IMorpho(morpho), morphoMarketId, alice), 0, "Direct collateral should be zero");
        assertEq(MorphoLib.borrowShares(IMorpho(morpho), morphoMarketId, alice), 0, "Direct borrow shares should stay zero");

        uint vaultUserCollateral = alice_morpho_vault.totalAssetsDepositedOrReserved() - alice_morpho_vault.maxRelease();
        assertApproxEqAbs(vaultUserCollateral, collateralBefore, 1, "Vault should have migrated collateral");
        assertEq(alice_morpho_vault.maxRepay(), 0, "Vault should not open debt");
    }

    /// @notice Teleport emits T_Teleport event with correct parameters
    function test_morpho_teleport_emitsEvent() public noGasMetering {
        _setupTeleport();

        uint collateralAmount = MorphoLib.collateral(IMorpho(morpho), morphoMarketId, alice);
        // expectedBorrowAssets + 1 buffer for rounding when repaying by shares
        uint debtAmount = MorphoBalancesLib.expectedBorrowAssets(IMorpho(morpho), morphoMarketParams, alice) + 1;

        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true, address(morphoTeleportOperator));
        emit T_Teleport(collateralAmount, debtAmount);
        morphoTeleportOperator.executeTeleport(
            address(alice_morpho_vault),
            type(uint).max,
            type(uint).max
        );
        vm.stopPrank();
    }

    // ==========================================
    // Leverage/Deleverage helpers
    // ==========================================

    /// @dev Helper: Create an empty collateral vault + enable leverage operator
    /// @dev No initial deposit — leverage operator handles depositing via skim.
    /// For Morpho vaults, user collateral gets supplied to Morpho during deposit,
    /// so the vault's token balance only holds reserved assets. skim() would underflow
    /// if totalAssetsDepositedOrReserved > token balance. Starting empty avoids this.
    function _setupLeverage() internal {
        morpho_creditDeposit(MO_COLLATERAL_TOKEN);

        vm.startPrank(alice);
        collateralVaultFactory.createMorphoCollateralVault({
            _intermediateVault: address(morpho_intermediate_vault),
            _targetVault: morpho,
            _marketParams: morphoMarketParams,
            _liqLTV: twyneLiqLTV
        });
        address[] memory vaults = collateralVaultFactory.getCollateralVaults(alice);
        alice_morpho_vault = MorphoCollateralVault(vaults[vaults.length - 1]);
        vm.label(address(alice_morpho_vault), "alice_morpho_vault");

        // Enable leverage operator on EVC
        evc.setAccountOperator(alice, address(morphoLeverageOperator), true);
        vm.stopPrank();
    }

    // ==========================================
    // Leverage tests
    // ==========================================

    /// @dev Helper: Execute a leverage operation on the vault (user provides collateral + flashloan)
    function _doLeverage(uint userCollateralAmount, uint flashloanAmount, uint minAmountOut) internal {
        // Deal WSTETH to swapper for swap simulation (WETH -> WSTETH)
        deal(MO_COLLATERAL_TOKEN, mockSwapperAddr, minAmountOut + 1 ether);

        // Approve operator to pull user collateral
        if (userCollateralAmount > 0) {
            IERC20(MO_COLLATERAL_TOKEN).approve(address(morphoLeverageOperator), userCollateralAmount);
        }

        bytes memory swapCall = abi.encodeCall(
            MockSwapper.swap,
            (MO_LOAN_TOKEN, MO_COLLATERAL_TOKEN, flashloanAmount, minAmountOut, address(morphoLeverageOperator))
        );
        bytes[] memory multicallData = new bytes[](1);
        multicallData[0] = swapCall;

        morphoLeverageOperator.executeLeverage(
            address(alice_morpho_vault),
            userCollateralAmount,
            flashloanAmount,
            minAmountOut,
            block.timestamp + 1000,
            multicallData
        );
    }

    /// @notice Full leverage + deleverage end-to-end flow
    function test_morpho_leverageAndDeleverage_success() public noGasMetering {
        _setupLeverage();

        vm.startPrank(alice);

        // === LEVERAGE PHASE ===
        // User provides initial collateral + flashloan for leverage
        uint userCollateralAmount = COLLATERAL_AMOUNT;
        uint flashloanAmount = 2 ether;
        uint minAmountOut = 1.5 ether;

        _doLeverage(userCollateralAmount, flashloanAmount, minAmountOut);

        // Verify leverage success
        uint leveragedCollateral = alice_morpho_vault.totalAssetsDepositedOrReserved() - alice_morpho_vault.maxRelease();
        assertGt(leveragedCollateral, userCollateralAmount, "Leverage should give more collateral than user provided");
        assertApproxEqAbs(alice_morpho_vault.maxRepay(), flashloanAmount, 1, "Vault should have debt from leverage");

        // === DELEVERAGE PHASE ===
        uint currentDebt = alice_morpho_vault.maxRepay();
        uint currentCollateral = alice_morpho_vault.totalAssetsDepositedOrReserved() - alice_morpho_vault.maxRelease();
        uint debtToRepay = currentDebt / 2; // Repay half the debt
        // Flashloan collateral, swap it to loan token to repay debt, then withdraw collateral to repay flashloan
        // withdrawCollateralAmount must be >= flashloanAmount to cover flashloan repayment
        uint deleverageFlashloanAmount = currentCollateral / 4;
        uint withdrawCollateralAmount = deleverageFlashloanAmount; // Withdraw enough to repay flashloan

        // Deal WETH to swapper for deleverage swap simulation (WSTETH -> WETH)
        deal(MO_LOAN_TOKEN, mockSwapperAddr, currentDebt + 1 ether);

        bytes memory deleverageSwapCall = abi.encodeCall(
            MockSwapper.swap,
            (
                MO_COLLATERAL_TOKEN,
                MO_LOAN_TOKEN,
                deleverageFlashloanAmount,
                debtToRepay + 1, // enough to repay the target amount
                address(morphoDeleverageOperator)
            )
        );
        bytes[] memory deleverageMulticallData = new bytes[](1);
        deleverageMulticallData[0] = deleverageSwapCall;

        // Enable deleverage operator on EVC
        evc.setAccountOperator(alice, address(morphoDeleverageOperator), true);

        uint maxDebt = currentDebt - debtToRepay + 10; // allow small buffer for rounding
        morphoDeleverageOperator.executeDeleverage(
            address(alice_morpho_vault),
            deleverageFlashloanAmount,
            maxDebt,
            withdrawCollateralAmount,
            deleverageMulticallData
        );

        // Verify deleverage success
        assertLt(
            alice_morpho_vault.totalAssetsDepositedOrReserved() - alice_morpho_vault.maxRelease(),
            currentCollateral,
            "Deleverage should reduce collateral"
        );
        assertLe(alice_morpho_vault.maxRepay(), maxDebt, "Deleverage should reduce debt");

        vm.stopPrank();
    }

    /// @notice Operators stay in sync with the borrow-LTV restriction: under a non-zero
    ///         borrowBuffer (the production regime), a HEALTHY leverage (final LTV well within
    ///         maxBorrow) and any deleverage (debt flat/down) must both still succeed. The fix caps net
    ///         debt growth only for OVER-maxBorrow positions, which these flows never create.
    function test_morpho_leverageAndDeleverage_withBorrowBuffer() public noGasMetering {
        _setupLeverage();

        // Enable Twyne's borrow-LTV discount (buffer 500 ⇒ maxBorrow ≈ 95% of liq value).
        vm.startPrank(admin);
        twyneVaultManager.setBorrowBuffer(address(morpho_intermediate_vault), MO_LOAN_TOKEN, 500);
        vm.stopPrank();

        vm.startPrank(alice);

        // === LEVERAGE === final LTV ~25% of collateral value, well under maxBorrow.
        uint userCollateralAmount = COLLATERAL_AMOUNT;
        uint flashloanAmount = 2 ether;
        uint minAmountOut = 1.5 ether;
        _doLeverage(userCollateralAmount, flashloanAmount, minAmountOut);

        assertApproxEqAbs(alice_morpho_vault.maxRepay(), flashloanAmount, 1, "Leverage debt mismatch");
        // Sanity: the leveraged position sits within maxBorrow, so the borrow-LTV check passes.
        assertLe(
            alice_morpho_vault.maxRepay(), alice_morpho_vault.maxBorrow(), "position should be within maxBorrow"
        );

        // === DELEVERAGE === repay half the debt (debt never grows ⇒ unaffected by the new cap).
        uint currentDebt = alice_morpho_vault.maxRepay();
        uint currentCollateral = alice_morpho_vault.totalAssetsDepositedOrReserved() - alice_morpho_vault.maxRelease();
        uint debtToRepay = currentDebt / 2;
        uint deleverageFlashloanAmount = currentCollateral / 4;
        uint withdrawCollateralAmount = deleverageFlashloanAmount;

        deal(MO_LOAN_TOKEN, mockSwapperAddr, currentDebt + 1 ether);
        bytes memory deleverageSwapCall = abi.encodeCall(
            MockSwapper.swap,
            (
                MO_COLLATERAL_TOKEN,
                MO_LOAN_TOKEN,
                deleverageFlashloanAmount,
                debtToRepay + 1,
                address(morphoDeleverageOperator)
            )
        );
        bytes[] memory deleverageMulticallData = new bytes[](1);
        deleverageMulticallData[0] = deleverageSwapCall;

        evc.setAccountOperator(alice, address(morphoDeleverageOperator), true);

        uint maxDebt = currentDebt - debtToRepay + 10; // rounding buffer
        morphoDeleverageOperator.executeDeleverage(
            address(alice_morpho_vault),
            deleverageFlashloanAmount,
            maxDebt,
            withdrawCollateralAmount,
            deleverageMulticallData
        );

        assertLe(alice_morpho_vault.maxRepay(), maxDebt, "Deleverage should reduce debt");

        vm.stopPrank();
    }

    /// @notice Leverage with user providing collateral alongside flashloan
    function test_morpho_leverage_withUserCollateral() public noGasMetering {
        _setupLeverage();

        vm.startPrank(alice);

        uint userCollateralAmount = 2 ether; // User provides 2 WSTETH
        uint flashloanAmount = 2 ether; // Flashloan 2 WETH
        uint minAmountOut = 1.5 ether;

        _doLeverage(userCollateralAmount, flashloanAmount, minAmountOut);

        // Collateral should be user contribution + swap output
        uint newCollateral = alice_morpho_vault.totalAssetsDepositedOrReserved() - alice_morpho_vault.maxRelease();
        assertGt(newCollateral, userCollateralAmount, "Should include user collateral + swap output");
        assertApproxEqAbs(alice_morpho_vault.maxRepay(), flashloanAmount, 1, "Debt should match flashloan");

        // Route returning part of the flashloan: the drain step (a plain swap payout)
        // leaves exactly the change-back in the swapper and sweep delivers it. Debt must
        // grow by the consumed part only and nothing may strand in the operator.
        uint debtBefore = alice_morpho_vault.maxRepay();
        uint returned = 0.5 ether;
        address leftoverSink = makeAddr("leftoverSink");
        // Drain and sweep move the swapper's full loan-token balance: zero out the
        // previous leverage's unconsumed flashloan so the amounts below are exact.
        deal(MO_LOAN_TOKEN, mockSwapperAddr, 0);
        deal(MO_COLLATERAL_TOKEN, mockSwapperAddr, minAmountOut + 1 ether);
        bytes[] memory sweepMulticallData = new bytes[](3);
        sweepMulticallData[0] = abi.encodeCall(
            MockSwapper.swap,
            (MO_LOAN_TOKEN, MO_COLLATERAL_TOKEN, flashloanAmount, minAmountOut, address(morphoLeverageOperator))
        );
        sweepMulticallData[1] = abi.encodeCall(
            MockSwapper.swap,
            (MO_COLLATERAL_TOKEN, MO_LOAN_TOKEN, 0.4 ether, flashloanAmount - returned - 10, leftoverSink)
        );
        sweepMulticallData[2] =
            abi.encodeCall(MockSwapper.sweep, (MO_LOAN_TOKEN, returned, address(morphoLeverageOperator)));

        morphoLeverageOperator.executeLeverage(
            address(alice_morpho_vault), 0, flashloanAmount, minAmountOut, block.timestamp + 1000, sweepMulticallData
        );

        assertApproxEqAbs(
            alice_morpho_vault.maxRepay(), debtBefore + flashloanAmount - returned, 1, "Debt grew by unconsumed flashloan"
        );
        assertEq(IERC20(MO_LOAN_TOKEN).balanceOf(address(morphoLeverageOperator)), 0, "Loan tokens stranded in operator");
        assertEq(IERC20(MO_COLLATERAL_TOKEN).balanceOf(address(morphoLeverageOperator)), 0, "Collateral stranded in operator");

        vm.stopPrank();
    }

    /// @notice Full deleverage: unwind position completely
    function test_morpho_deleverage_fullUnwind() public noGasMetering {
        _setupLeverage();

        vm.startPrank(alice);

        // First leverage up with user collateral
        _doLeverage(COLLATERAL_AMOUNT, 2 ether, 1.5 ether);

        // Now deleverage fully
        uint currentDebt = alice_morpho_vault.maxRepay();
        // Flashloan some collateral, swap to loan token, repay all debt, withdraw collateral to cover flashloan
        uint deleverageFlashAmount = 2 ether;
        // Must withdraw at least flashloan amount to cover repayment
        uint withdrawAmount = deleverageFlashAmount;

        // Deal WETH to swapper to cover full debt repayment
        deal(MO_LOAN_TOKEN, mockSwapperAddr, currentDebt + 1 ether);

        bytes memory delSwapCall = abi.encodeCall(
            MockSwapper.swap,
            (MO_COLLATERAL_TOKEN, MO_LOAN_TOKEN, deleverageFlashAmount, currentDebt, address(morphoDeleverageOperator))
        );
        bytes[] memory delMulticallData = new bytes[](1);
        delMulticallData[0] = delSwapCall;

        evc.setAccountOperator(alice, address(morphoDeleverageOperator), true);

        morphoDeleverageOperator.executeDeleverage(
            address(alice_morpho_vault), deleverageFlashAmount, 0, withdrawAmount, delMulticallData
        );

        // Debt should be zero after full unwind
        assertEq(alice_morpho_vault.maxRepay(), 0, "Debt should be fully repaid");

        vm.stopPrank();
    }

    // ==========================================
    // Leverage/Deleverage access control tests
    // ==========================================

    /// @notice Non-borrower cannot execute leverage
    function test_morpho_leverage_unauthorized() public {
        _setupLeverage();

        bytes[] memory swapData = new bytes[](0);

        vm.startPrank(bob);
        vm.expectRevert(TwyneErrors.T_CallerNotBorrower.selector);
        morphoLeverageOperator.executeLeverage(address(alice_morpho_vault), 0, 0, 0, block.timestamp, swapData);
        vm.stopPrank();
    }

    /// @notice Non-borrower cannot execute deleverage
    function test_morpho_deleverage_unauthorized() public {
        _setupLeverage();

        bytes[] memory swapData = new bytes[](0);

        vm.startPrank(bob);
        vm.expectRevert(TwyneErrors.T_CallerNotBorrower.selector);
        morphoDeleverageOperator.executeDeleverage(address(alice_morpho_vault), 0, 0, 0, swapData);
        vm.stopPrank();
    }

    /// @notice Invalid vault address reverts for leverage
    function test_morpho_leverage_invalidVault() public {
        vm.startPrank(alice);
        bytes[] memory swapData = new bytes[](0);
        vm.expectRevert(TwyneErrors.T_InvalidCollateralVault.selector);
        morphoLeverageOperator.executeLeverage(address(0xdead), 0, 0, 0, block.timestamp, swapData);
        vm.stopPrank();
    }

    /// @notice Invalid vault address reverts for deleverage
    function test_morpho_deleverage_invalidVault() public {
        vm.startPrank(alice);
        bytes[] memory swapData = new bytes[](0);
        vm.expectRevert(TwyneErrors.T_InvalidCollateralVault.selector);
        morphoDeleverageOperator.executeDeleverage(address(0xdead), 0, 0, 0, swapData);
        vm.stopPrank();
    }

    /// @notice Direct callback calls revert for leverage/deleverage operators
    function test_morpho_leverageDeleverage_callbackAccessControl() public {
        vm.expectRevert(TwyneErrors.T_CallerNotMorpho.selector);
        morphoLeverageOperator.onMorphoFlashLoan(1 ether, "");

        vm.expectRevert(TwyneErrors.T_CallerNotMorpho.selector);
        morphoDeleverageOperator.onMorphoFlashLoan(1 ether, "");
    }

    /// @notice Leverage slippage check fails when swap output is too low
    function test_morpho_leverage_slippageCheckFails() public noGasMetering {
        _setupLeverage();

        vm.startPrank(alice);

        uint flashloanAmount = 2 ether;
        uint minAmountOut = 10 ether; // Unrealistically high minimum

        // Deal only a small amount to swapper (less than minAmountOut)
        deal(MO_COLLATERAL_TOKEN, mockSwapperAddr, 1 ether);

        bytes memory swapCall = abi.encodeCall(
            MockSwapper.swap,
            (MO_LOAN_TOKEN, MO_COLLATERAL_TOKEN, flashloanAmount, 0.5 ether, address(morphoLeverageOperator))
        );
        bytes[] memory multicallData = new bytes[](1);
        multicallData[0] = swapCall;

        vm.expectRevert(TwyneErrors.T_SlippageCheckFailed.selector);
        morphoLeverageOperator.executeLeverage(
            address(alice_morpho_vault), 0, flashloanAmount, minAmountOut, block.timestamp + 1000, multicallData
        );

        // minAmountOut applies to the swap output only: the user's collateral contribution
        // must not count toward it. Swap pays 1 ether + 10 wei, user contributes 1 ether, and
        // minAmountOut (1.5 ether) sits between swap output and swap output + user collateral,
        // so only a check diluted with user collateral would pass.
        uint userCollateralAmount = 1 ether;
        IERC20(MO_COLLATERAL_TOKEN).approve(address(morphoLeverageOperator), userCollateralAmount);
        deal(MO_COLLATERAL_TOKEN, mockSwapperAddr, 1 ether + 10);

        bytes memory userCollateralSwapCall = abi.encodeCall(
            MockSwapper.swap,
            (MO_LOAN_TOKEN, MO_COLLATERAL_TOKEN, flashloanAmount, 1 ether, address(morphoLeverageOperator))
        );
        bytes[] memory userCollateralMulticallData = new bytes[](1);
        userCollateralMulticallData[0] = userCollateralSwapCall;

        vm.expectRevert(TwyneErrors.T_SlippageCheckFailed.selector);
        morphoLeverageOperator.executeLeverage(
            address(alice_morpho_vault),
            userCollateralAmount,
            flashloanAmount,
            1.5 ether,
            block.timestamp + 1000,
            userCollateralMulticallData
        );

        vm.stopPrank();
    }

    /// @notice Leverage deadline check fails when expired
    function test_morpho_leverage_deadlineExpired() public noGasMetering {
        _setupLeverage();

        vm.startPrank(alice);

        uint flashloanAmount = 2 ether;
        uint minAmountOut = 1.5 ether;

        deal(MO_COLLATERAL_TOKEN, mockSwapperAddr, minAmountOut + 1 ether);

        bytes memory swapCall = abi.encodeCall(
            MockSwapper.swap,
            (MO_LOAN_TOKEN, MO_COLLATERAL_TOKEN, flashloanAmount, minAmountOut, address(morphoLeverageOperator))
        );
        bytes[] memory multicallData = new bytes[](1);
        multicallData[0] = swapCall;

        vm.expectRevert(TwyneErrors.T_DeadlineExpired.selector);
        morphoLeverageOperator.executeLeverage(
            address(alice_morpho_vault), 0, flashloanAmount, minAmountOut, block.timestamp - 1, multicallData
        );

        vm.stopPrank();
    }

    /// @notice Deleverage maxDebt check fails when remaining debt exceeds max
    function test_morpho_deleverage_debtExceedsMax() public noGasMetering {
        _setupLeverage();

        vm.startPrank(alice);

        // First leverage up with user collateral
        _doLeverage(COLLATERAL_AMOUNT, 2 ether, 1.5 ether);

        assertGt(alice_morpho_vault.maxRepay(), 0, "Should have debt after leverage");
        uint deleverageFlashAmount = 0.5 ether;

        // Deal only a tiny amount of WETH to swapper (not enough to bring debt below maxDebt)
        deal(MO_LOAN_TOKEN, mockSwapperAddr, 0.1 ether);

        bytes memory delSwapCall = abi.encodeCall(
            MockSwapper.swap,
            (MO_COLLATERAL_TOKEN, MO_LOAN_TOKEN, deleverageFlashAmount, 0.05 ether, address(morphoDeleverageOperator))
        );
        bytes[] memory delMulticallData = new bytes[](1);
        delMulticallData[0] = delSwapCall;

        evc.setAccountOperator(alice, address(morphoDeleverageOperator), true);

        // maxDebt = 0 but debt won't be fully repaid
        vm.expectRevert(TwyneErrors.T_DebtMoreThanMax.selector);
        morphoDeleverageOperator.executeDeleverage(
            address(alice_morpho_vault), deleverageFlashAmount, 0, 0, delMulticallData
        );

        vm.stopPrank();
    }

    /// @notice No leftover tokens in operators after leverage/deleverage
    function test_morpho_leverageDeleverage_noLeftoverTokens() public noGasMetering {
        _setupLeverage();

        vm.startPrank(alice);

        // Leverage with user collateral
        _doLeverage(COLLATERAL_AMOUNT, 2 ether, 1.5 ether);

        // Leverage operator should have no tokens
        assertEq(
            IERC20(MO_LOAN_TOKEN).balanceOf(address(morphoLeverageOperator)),
            0,
            "Leverage operator should have no loan token"
        );
        assertEq(
            IERC20(MO_COLLATERAL_TOKEN).balanceOf(address(morphoLeverageOperator)),
            0,
            "Leverage operator should have no collateral token"
        );

        // Deleverage — fully repay debt, withdraw enough to cover flashloan
        uint currentDebt = alice_morpho_vault.maxRepay();
        uint deleverageFlashAmount = 1 ether;
        deal(MO_LOAN_TOKEN, mockSwapperAddr, currentDebt + 1 ether);

        bytes memory delSwapCall = abi.encodeCall(
            MockSwapper.swap,
            (
                MO_COLLATERAL_TOKEN,
                MO_LOAN_TOKEN,
                deleverageFlashAmount,
                currentDebt,
                address(morphoDeleverageOperator)
            )
        );
        bytes[] memory delMulticallData = new bytes[](1);
        delMulticallData[0] = delSwapCall;

        evc.setAccountOperator(alice, address(morphoDeleverageOperator), true);
        morphoDeleverageOperator.executeDeleverage(
            address(alice_morpho_vault), deleverageFlashAmount, 0, deleverageFlashAmount, delMulticallData
        );

        // Deleverage operator should have no tokens
        assertEq(
            IERC20(MO_LOAN_TOKEN).balanceOf(address(morphoDeleverageOperator)),
            0,
            "Deleverage operator should have no loan token"
        );
        assertEq(
            IERC20(MO_COLLATERAL_TOKEN).balanceOf(address(morphoDeleverageOperator)),
            0,
            "Deleverage operator should have no collateral token"
        );

        vm.stopPrank();
    }

    /// @notice Leverage emits T_LeverageUpExecuted event
    function test_morpho_leverage_emitsEvent() public noGasMetering {
        _setupLeverage();

        vm.startPrank(alice);

        uint userCollateralAmount = COLLATERAL_AMOUNT;
        uint flashloanAmount = 2 ether;
        uint minAmountOut = 1.5 ether;

        deal(MO_COLLATERAL_TOKEN, mockSwapperAddr, minAmountOut + 1 ether);
        IERC20(MO_COLLATERAL_TOKEN).approve(address(morphoLeverageOperator), userCollateralAmount);

        bytes memory swapCall = abi.encodeCall(
            MockSwapper.swap,
            (MO_LOAN_TOKEN, MO_COLLATERAL_TOKEN, flashloanAmount, minAmountOut, address(morphoLeverageOperator))
        );
        bytes[] memory multicallData = new bytes[](1);
        multicallData[0] = swapCall;

        vm.expectEmit(true, true, true, true, address(morphoLeverageOperator));
        emit T_LeverageUpExecuted(address(alice_morpho_vault));

        morphoLeverageOperator.executeLeverage(
            address(alice_morpho_vault),
            userCollateralAmount,
            flashloanAmount,
            minAmountOut,
            block.timestamp + 1000,
            multicallData
        );

        vm.stopPrank();
    }

    /// @notice Deleverage emits T_LeverageDownExecuted event
    function test_morpho_deleverage_emitsEvent() public noGasMetering {
        _setupLeverage();

        vm.startPrank(alice);

        // First leverage up with user collateral
        _doLeverage(COLLATERAL_AMOUNT, 2 ether, 1.5 ether);

        // Deleverage
        uint currentDebt = alice_morpho_vault.maxRepay();
        uint deleverageFlashAmount = 1 ether;
        deal(MO_LOAN_TOKEN, mockSwapperAddr, currentDebt + 1 ether);

        bytes memory delSwapCall = abi.encodeCall(
            MockSwapper.swap,
            (
                MO_COLLATERAL_TOKEN,
                MO_LOAN_TOKEN,
                deleverageFlashAmount,
                currentDebt,
                address(morphoDeleverageOperator)
            )
        );
        bytes[] memory delMulticallData = new bytes[](1);
        delMulticallData[0] = delSwapCall;

        evc.setAccountOperator(alice, address(morphoDeleverageOperator), true);

        vm.expectEmit(true, true, true, true, address(morphoDeleverageOperator));
        emit T_LeverageDownExecuted(address(alice_morpho_vault));

        morphoDeleverageOperator.executeDeleverage(
            address(alice_morpho_vault), deleverageFlashAmount, 0, deleverageFlashAmount, delMulticallData
        );

        vm.stopPrank();
    }
}
