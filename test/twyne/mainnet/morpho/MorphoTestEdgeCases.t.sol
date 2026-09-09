// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {MorphoTestBase, console2} from "./MorphoTestBase.t.sol";
import {BridgeHookTarget} from "src/TwyneFactory/BridgeHookTarget.sol";
import "euler-vault-kit/EVault/shared/types/Types.sol";
import {Pausable} from "openzeppelin-contracts/utils/Pausable.sol";
import {PauseState} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {Initializable} from "openzeppelin-upgradeable/proxy/utils/Initializable.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {Errors as EVCErrors} from "ethereum-vault-connector/Errors.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {MorphoCollateralVault, CollateralVaultBase} from "src/twyne/MorphoCollateralVault.sol";
import {Errors} from "euler-vault-kit/EVault/shared/Errors.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {IRMTwyneCurve} from "src/twyne/IRMTwyneCurve.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IMorpho, MarketParams, Id} from "morpho/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho/libraries/MarketParamsLib.sol";
import {IOracle} from "morpho/interfaces/IOracle.sol";
import {MathLib} from "morpho/libraries/MathLib.sol";
import {ORACLE_PRICE_SCALE} from "morpho/libraries/ConstantsLib.sol";
import {SafeERC20, IERC20 as IERC20_OZ} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20 as IERC20_Base} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

contract NewImplementation {
    uint constant public version = 953;
}

contract MorphoTestEdgeCases is MorphoTestBase {
    using MathLib for uint;

    function setUp() public override {
        super.setUp();
    }

    // ============================================================
    // Vault creation edge cases
    // ============================================================

    // Confirm a user can have multiple identical collateral vaults at any given time
    function test_morpho_secondVaultCreationSameUser() public noGasMetering {
        morpho_createCollateralVault(MO_COLLATERAL_TOKEN, twyneLiqLTV);

        vm.startPrank(alice);
        collateralVaultFactory.createMorphoCollateralVault({
            _intermediateVault: address(morpho_intermediate_vault),
            _targetVault: morpho,
            _marketParams: morphoMarketParams,
            _liqLTV: twyneLiqLTV
        });
        vm.stopPrank();

        address[] memory vaults = collateralVaultFactory.getCollateralVaults(alice);
        assertGe(vaults.length, 2, "Alice should have at least 2 vaults");
    }

    // Creating a vault with an unsupported Morpho market should revert
    function test_morpho_createMismatchCollateralVault() public noGasMetering {
        morpho_creditDeposit(MO_COLLATERAL_TOKEN);

        // Use wrong market params (swap loan and collateral tokens)
        MarketParams memory badMarketParams = MarketParams({
            loanToken: MO_COLLATERAL_TOKEN,
            collateralToken: MO_LOAN_TOKEN,
            oracle: MO_ORACLE,
            irm: MO_IRM,
            lltv: MO_LLTV
        });

        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.NotIntermediateVault.selector);
        collateralVaultFactory.createMorphoCollateralVault({
            _intermediateVault: address(morpho_intermediate_vault),
            _targetVault: morpho,
            _marketParams: badMarketParams,
            _liqLTV: twyneLiqLTV
        });
        vm.stopPrank();
    }

    // Creating a vault with a different market than what the intermediate vault is configured for should revert
    function test_morpho_createVault_revert_wrongMarketForIntermediateVault() public noGasMetering {
        morpho_creditDeposit(MO_COLLATERAL_TOKEN);

        // Use a different market (different LLTV produces a different market ID)
        MarketParams memory differentMarketParams = MarketParams({
            loanToken: MO_LOAN_TOKEN,
            collateralToken: MO_COLLATERAL_TOKEN,
            oracle: MO_ORACLE,
            irm: MO_IRM,
            lltv: 900000000000000000 // 90% — different from MO_LLTV (96.5%)
        });

        // Verify this produces a different market ID than the one configured
        Id differentMarketId = MarketParamsLib.id(differentMarketParams);
        assertTrue(Id.unwrap(differentMarketId) != Id.unwrap(morphoMarketId), "market IDs should differ");

        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.NotIntermediateVault.selector);
        collateralVaultFactory.createMorphoCollateralVault({
            _intermediateVault: address(morpho_intermediate_vault),
            _targetVault: morpho,
            _marketParams: differentMarketParams,
            _liqLTV: twyneLiqLTV
        });
        vm.stopPrank();
    }

    // Morpho deployment requires the intermediate vault to be self-denominated (unitOfAccount == asset)
    function test_morpho_createVault_revert_unitOfAccountMismatch() public noGasMetering {
        vm.startPrank(admin);
        // Create intermediate vault with mismatched unitOfAccount (not self-denominated)
        IEVault badIntermediate = IEVault(
            factory.createProxy(address(0), true, abi.encodePacked(MO_COLLATERAL_TOKEN, address(oracleRouter), MO_LOAN_TOKEN))
        );
        badIntermediate.setHookConfig(
            address(new BridgeHookTarget(address(collateralVaultFactory))),
            OP_BORROW | OP_LIQUIDATE | OP_FLASHLOAN | OP_PULL_DEBT
        );
        badIntermediate.setGovernorAdmin(address(twyneVaultManager));
        twyneVaultManager.setIntermediateVault(badIntermediate, true);
        twyneVaultManager.setMaxLiquidationLTV(address(badIntermediate), MO_LOAN_TOKEN, maxLTVInitial, 0);
        twyneVaultManager.setExternalLiqBuffer(address(badIntermediate), MO_LOAN_TOKEN, externalLiqBufferInitial, 0);
        twyneVaultManager.setAllowedMorphoMarket(morpho, address(badIntermediate), morphoMarketId, true);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.UnitOfAccountMismatch.selector);
        collateralVaultFactory.createMorphoCollateralVault({
            _intermediateVault: address(badIntermediate),
            _targetVault: morpho,
            _marketParams: morphoMarketParams,
            _liqLTV: twyneLiqLTV
        });
        vm.stopPrank();
    }

    // Creating a vault with invalid LTV should revert
    function test_morpho_CV_init_error() public noGasMetering {
        morpho_creditDeposit(MO_COLLATERAL_TOKEN);

        // LTV too low — below minimum allowed by external LTV * buffer
        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.ValueOutOfRange.selector);
        collateralVaultFactory.createMorphoCollateralVault({
            _intermediateVault: address(morpho_intermediate_vault),
            _targetVault: morpho,
            _marketParams: morphoMarketParams,
            _liqLTV: 1000 // way too low
        });
        vm.stopPrank();
    }

    // ============================================================
    // Access control edge cases
    // ============================================================

    // Eve cannot deposit into Alice's vault
    function test_morpho_eveCantDepositIntoAliceVault() public noGasMetering {
        morpho_createCollateralVault(MO_COLLATERAL_TOKEN, twyneLiqLTV);

        vm.startPrank(eve);
        IERC20(MO_COLLATERAL_TOKEN).approve(address(alice_morpho_vault), type(uint256).max);

        assertEq(alice_morpho_vault.borrower(), alice);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_morpho_vault.deposit(COLLATERAL_AMOUNT);
        vm.stopPrank();

        // Even if Alice allows Eve to be an operator, Eve still cannot deposit
        vm.startPrank(alice);
        evc.setAccountOperator(alice, eve, true);
        vm.stopPrank();

        vm.startPrank(eve);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_morpho_vault.deposit(COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    // Collateral vault does not support standard ERC20 functions (transfer, transferFrom, approve)
    function test_morpho_aliceCantTransferCollateralShares() public noGasMetering {
        morpho_createCollateralVault(MO_COLLATERAL_TOKEN, twyneLiqLTV);

        vm.startPrank(alice);

        vm.expectRevert();
        IERC20(address(alice_morpho_vault)).transferFrom(address(alice_morpho_vault), alice, 1 ether);

        vm.expectRevert();
        IERC20(address(alice_morpho_vault)).transfer(eve, 1 ether);

        vm.expectRevert();
        IERC20(address(alice_morpho_vault)).approve(eve, 1 ether);
        vm.stopPrank();

        vm.startPrank(eve);
        vm.expectRevert();
        IERC20(address(alice_morpho_vault)).transferFrom(alice, eve, 1 ether);
        vm.stopPrank();
    }

    // ============================================================
    // Repay edge cases
    // ============================================================

    // Anyone can repay intermediate vault debt on behalf of a collateral vault
    function test_morpho_anyoneCanRepayIntermediateVault() external noGasMetering {
        morpho_firstBorrowDirect(MO_COLLATERAL_TOKEN);

        // Move forward in time to accrue interest
        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 12);

        assertGt(alice_morpho_vault.maxRelease(), 0, "Should have intermediate vault debt");
        uint256 aliceCurrentDebt = alice_morpho_vault.maxRelease();

        // Deal assets to a random third party
        address someone = makeAddr("someone");
        deal(MO_COLLATERAL_TOKEN, someone, INITIAL_DEALT_ERC20);

        // Someone repays all intermediate vault debt on behalf of Alice's collateral vault
        vm.startPrank(someone);
        IERC20(MO_COLLATERAL_TOKEN).approve(address(morpho_intermediate_vault), type(uint).max);
        uint repaid = morpho_intermediate_vault.repay(type(uint).max, address(alice_morpho_vault));
        vm.stopPrank();

        assertEq(alice_morpho_vault.maxRelease(), 0, "Intermediate vault debt should be 0");
        assertEq(aliceCurrentDebt, repaid, "Repaid amount mismatch");
    }

    // Repaying more than max should revert
    function test_morpho_collateralVaultWithBorrowReverts() public noGasMetering {
        morpho_firstBorrowDirect(MO_COLLATERAL_TOKEN);

        vm.startPrank(alice);

        vm.expectRevert(TwyneErrors.RepayingMoreThanMax.selector);
        alice_morpho_vault.repay(type(uint256).max - 1);

        vm.expectRevert(TwyneErrors.NotCollateralVault.selector);
        collateralVaultFactory.setCollateralVaultLiquidated(address(this));

        vm.stopPrank();
    }

    // Zero-value actions on Morpho vault should be no-ops and not revert.
    function test_morpho_zeroValueActions_noRevert() public noGasMetering {
        morpho_collateralDepositWithoutBorrow(MO_COLLATERAL_TOKEN, twyneLiqLTV);

        uint assetsBefore = alice_morpho_vault.totalAssetsDepositedOrReserved();
        uint debtBefore = alice_morpho_vault.maxRepay();

        vm.startPrank(alice);
        IERC20(MO_LOAN_TOKEN).approve(address(alice_morpho_vault), type(uint).max);

        alice_morpho_vault.deposit(0);
        alice_morpho_vault.withdraw(0, alice);
        alice_morpho_vault.borrow(0, alice);
        alice_morpho_vault.repay(0);
        alice_morpho_vault.skim();
        vm.stopPrank();

        assertEq(alice_morpho_vault.totalAssetsDepositedOrReserved(), assetsBefore, "assets should be unchanged");
        assertEq(alice_morpho_vault.maxRepay(), debtBefore, "debt should be unchanged");
    }

    // ============================================================
    // Pause protocol
    // ============================================================

    // Pausing the protocol blocks new vault creation, deposits, skim, and borrow
    function test_morpho_pauseProtocol() public noGasMetering {
        morpho_collateralDepositWithoutBorrow(MO_COLLATERAL_TOKEN, twyneLiqLTV);

        vm.startPrank(bob);
        morpho_intermediate_vault.deposit(1 ether, bob);
        vm.stopPrank();

        // Pause the protocol
        vm.startPrank(admin);
        collateralVaultFactory.pause();
        vm.stopPrank();

        // Cannot create new vaults
        vm.startPrank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        collateralVaultFactory.createMorphoCollateralVault({
            _intermediateVault: address(morpho_intermediate_vault),
            _targetVault: morpho,
            _marketParams: morphoMarketParams,
            _liqLTV: twyneLiqLTV
        });

        // Cannot deposit
        IERC20(MO_COLLATERAL_TOKEN).approve(address(alice_morpho_vault), type(uint).max);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        alice_morpho_vault.deposit(1 ether);

        // Cannot skim
        vm.expectRevert(Pausable.EnforcedPause.selector);
        alice_morpho_vault.skim();
        vm.stopPrank();

        // Unpause
        vm.startPrank(admin);
        collateralVaultFactory.setPauseState(PauseState.Active);
        vm.stopPrank();

        // After unpause, deposit works again
        vm.startPrank(alice);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.deposit, (1 ether))
        });
        evc.batch(items);
        vm.stopPrank();
    }

    // Pause blocks handleExternalLiquidation() on the collateral vault.
    function test_morpho_pause_blocksHandleExternalLiquidation() public noGasMetering {
        morpho_firstBorrowDirect(MO_COLLATERAL_TOKEN);

        vm.prank(admin);
        collateralVaultFactory.pause();

        vm.prank(liquidator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        alice_morpho_vault.handleExternalLiquidation();
    }

    // ============================================================
    // Pull debt blocked
    // ============================================================

    // pullDebt is blocked on intermediate vault via BridgeHookTarget
    function test_morpho_pullDebtBlocked() public noGasMetering {
        morpho_firstBorrowDirect(MO_COLLATERAL_TOKEN);

        vm.startPrank(alice);
        evc.enableController(alice, address(morpho_intermediate_vault));

        vm.expectRevert(TwyneErrors.T_OperationDisabled.selector);
        morpho_intermediate_vault.pullDebt(1, address(alice_morpho_vault));
        vm.stopPrank();
    }

    // ============================================================
    // Flashloan blocked
    // ============================================================

    // Flashloan is blocked on intermediate vault via BridgeHookTarget
    function test_morpho_flashloanBlocked() public noGasMetering {
        morpho_createCollateralVault(MO_COLLATERAL_TOKEN, twyneLiqLTV);

        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.T_OperationDisabled.selector);
        morpho_intermediate_vault.flashLoan(1, abi.encode(""));
        vm.stopPrank();
    }

    // ============================================================
    // Governance / proxy upgrade
    // ============================================================

    // Governance upgrades the beacon proxy implementation
    function test_morpho_proxyUpgrade() public noGasMetering {
        morpho_createCollateralVault(MO_COLLATERAL_TOKEN, twyneLiqLTV);
        assertEq(alice_morpho_vault.version(), 0);

        UpgradeableBeacon beacon = UpgradeableBeacon(collateralVaultFactory.collateralVaultBeacon(morpho));
        vm.startPrank(admin);
        beacon.upgradeTo(address(new NewImplementation()));
        assertEq(alice_morpho_vault.version(), 953);
        vm.stopPrank();
    }

    // ============================================================
    // Revert edge cases
    // ============================================================

    // handleExternalLiquidation reverts when not externally liquidated
    function test_morpho_collateralVaultReverts() public noGasMetering {
        morpho_createCollateralVault(MO_COLLATERAL_TOKEN, twyneLiqLTV);

        vm.startPrank(alice);

        // Not externally liquidated — should revert
        vm.expectRevert(TwyneErrors.NotExternallyLiquidated.selector);
        alice_morpho_vault.handleExternalLiquidation();

        // Flashloan blocked
        vm.expectRevert(TwyneErrors.T_OperationDisabled.selector);
        morpho_intermediate_vault.flashLoan(1, abi.encode(""));

        // Non-CV caller cannot borrow from intermediate vault
        evc.enableController(alice, address(morpho_intermediate_vault));
        evc.enableCollateral(alice, address(alice_morpho_vault));
        vm.expectRevert(TwyneErrors.CallerNotCollateralVault.selector);
        morpho_intermediate_vault.borrow(1, alice);

        vm.stopPrank();
    }

    // Re-initialization should revert
    function test_morpho_doubleInitReverts() public noGasMetering {
        morpho_createCollateralVault(MO_COLLATERAL_TOKEN, twyneLiqLTV);

        vm.startPrank(alice);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        alice_morpho_vault.initialize(
            address(morpho_intermediate_vault),
            alice,
            twyneLiqLTV,
            twyneVaultManager,
            morphoMarketParams
        );
        vm.stopPrank();
    }

    // ============================================================
    // VaultManager setter edge cases
    // ============================================================

    // Non-owner cannot call VaultManager setters
    function test_morpho_vaultManagerSetterReverts() public noGasMetering {
        morpho_collateralDepositWithoutBorrow(MO_COLLATERAL_TOKEN, twyneLiqLTV);

        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.CallerNotOwnerOrCollateralVaultFactory.selector);
        twyneVaultManager.setLTV(morpho_intermediate_vault, address(alice_morpho_vault), 6500, 7500, 0);
        vm.stopPrank();

        vm.startPrank(admin);
        twyneVaultManager.setMaxLiquidationLTV(address(morpho_intermediate_vault), MO_LOAN_TOKEN, 1e4, 0);
        twyneVaultManager.setExternalLiqBuffer(address(morpho_intermediate_vault), MO_LOAN_TOKEN, 1e4, 0);

        vm.expectRevert(TwyneErrors.ValueOutOfRange.selector);
        twyneVaultManager.setMaxLiquidationLTV(address(morpho_intermediate_vault), MO_LOAN_TOKEN, 1e4 + 1, 0);

        vm.expectRevert(TwyneErrors.ValueOutOfRange.selector);
        twyneVaultManager.setExternalLiqBuffer(address(morpho_intermediate_vault), MO_LOAN_TOKEN, 1e4 + 1, 0);
        vm.stopPrank();
    }

    // ============================================================
    // LTV ramping
    // ============================================================

    // Governance sets LTV ramping on intermediate vault for collateral vault
    function test_morpho_LTVRamping() public noGasMetering {
        morpho_firstBorrowDirect(MO_COLLATERAL_TOKEN);

        assertEq(morpho_intermediate_vault.LTVLiquidation(address(alice_morpho_vault)), 1e4, "unexpected liquidation LTV");
        assertEq(morpho_intermediate_vault.LTVBorrow(address(alice_morpho_vault)), 1e4, "unexpected borrow LTV");

        vm.startPrank(twyneVaultManager.owner());
        twyneVaultManager.setLTV(morpho_intermediate_vault, address(alice_morpho_vault), 0.08e4, 0.999e4, 100);
        vm.stopPrank();
    }

    // ============================================================
    // Operator / EVC edge cases
    // ============================================================

    // An operator can change twyneLiqLTV on behalf of the vault owner
    function test_morpho_setOperatorChangeTwyneLiqLTVNoBorrow() public noGasMetering {
        morpho_createCollateralVault(MO_COLLATERAL_TOKEN, twyneLiqLTV);

        // Set bob as operator for alice
        vm.startPrank(alice);
        evc.setAccountOperator(alice, bob, true);
        vm.stopPrank();

        vm.startPrank(bob);
        uint16 newLTV = twyneVaultManager.maxTwyneLTVs(address(morpho_intermediate_vault), alice_morpho_vault.targetAsset());
        assertNotEq(alice_morpho_vault.twyneLiqLTV(), newLTV);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.setTwyneLiqLTV, newLTV)
        });
        evc.batch(items);
        vm.stopPrank();

        assertEq(alice_morpho_vault.twyneLiqLTV(), newLTV, "LTV not updated by operator");
    }

    // Collateral vaults cannot be enabled as controller
    function test_morpho_cannotEnableAsController() public noGasMetering {
        morpho_createCollateralVault(MO_COLLATERAL_TOKEN, twyneLiqLTV);

        vm.startPrank(alice);
        vm.expectRevert();
        evc.enableController(alice, address(alice_morpho_vault));
        vm.stopPrank();
    }

    // ============================================================
    // Non-CV borrow blocked by hook
    // ============================================================

    // Non-collateral vault accounts are blocked by BridgeHookTarget from borrowing
    function test_morpho_NonCollateralVaultBorrowBlockedByHook() public noGasMetering {
        morpho_creditDeposit(MO_COLLATERAL_TOKEN);

        // Alice (not a collateral vault) tries to borrow from intermediate vault
        vm.startPrank(alice);
        evc.enableController(alice, address(morpho_intermediate_vault));

        // Blocked by BridgeHookTarget — caller is not a collateral vault
        vm.expectRevert(TwyneErrors.CallerNotCollateralVault.selector);
        morpho_intermediate_vault.borrow(1e18, alice);

        // Create a vault, but alice herself still cannot borrow directly
        collateralVaultFactory.createMorphoCollateralVault({
            _intermediateVault: address(morpho_intermediate_vault),
            _targetVault: morpho,
            _marketParams: morphoMarketParams,
            _liqLTV: twyneLiqLTV
        });
        address[] memory vaults = collateralVaultFactory.getCollateralVaults(alice);
        address vault = vaults[vaults.length - 1];

        vm.expectRevert(TwyneErrors.CallerNotCollateralVault.selector);
        morpho_intermediate_vault.borrow(1e18, vault);

        vm.stopPrank();

        // Random actor also cannot borrow
        address randomActor = makeAddr("randomActor");
        vm.startPrank(randomActor);
        evc.enableController(randomActor, address(morpho_intermediate_vault));
        vm.expectRevert(TwyneErrors.CallerNotCollateralVault.selector);
        morpho_intermediate_vault.borrow(1e18, vault);
        vm.stopPrank();
    }

    // ============================================================
    // Rebalance
    // ============================================================

    // After time passes, vault should be rebalanceable
    function test_morpho_rebalance() public noGasMetering {
        morpho_collateralDepositWithoutBorrow(MO_COLLATERAL_TOKEN, twyneLiqLTV);

        vm.warp(block.timestamp + 1000);

        vm.startPrank(alice);
        assertGt(alice_morpho_vault.canRebalance(), 0);
        alice_morpho_vault.rebalance();
        vm.stopPrank();
    }

    // ============================================================
    // Invalid withdraw
    // ============================================================

    // Withdrawing more than allowed should revert
    function test_morpho_invalid_withdraw() public noGasMetering {
        morpho_collateralDepositWithoutBorrow(MO_COLLATERAL_TOKEN, twyneLiqLTV);

        vm.startPrank(alice);

        uint balance = alice_morpho_vault.balanceOf(address(alice_morpho_vault));
        // Try withdrawing balance - 1 (leaving dust) — should revert due to vault status check
        vm.expectRevert();
        alice_morpho_vault.withdraw(balance - 1, alice);
        vm.stopPrank();
    }

    // ============================================================
    // redeemUnderlying not supported for Morpho
    // ============================================================

    // redeemUnderlying reverts since Morpho doesn't use wrapped tokens
    function test_morpho_redeemUnderlyingReverts() public noGasMetering {
        morpho_creditDeposit(MO_COLLATERAL_TOKEN);
        morpho_createCollateralVault(MO_COLLATERAL_TOKEN, twyneLiqLTV);

        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.T_MorphoNotImplemented.selector);
        alice_morpho_vault.redeemUnderlying(1 ether, alice);
        vm.stopPrank();
    }

    // ============================================================
    // Full utilization intermediate vault
    // ============================================================

    // When intermediate vault has insufficient cash, deposits requiring
    // credit reservation should revert
    function test_morpho_fullUtilizationIntermediateVault() public noGasMetering {
        // Create vault with minimal credit in intermediate vault
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
        vm.stopPrank();

        // Bob deposits just enough to cover the reserved assets needed for COLLATERAL_AMOUNT
        uint exactIntermediateDeposit = getReservedAssetsForMorpho(COLLATERAL_AMOUNT, alice_morpho_vault);
        vm.startPrank(bob);
        IERC20(MO_COLLATERAL_TOKEN).approve(address(morpho_intermediate_vault), type(uint256).max);
        morpho_intermediate_vault.deposit(exactIntermediateDeposit, bob);
        vm.stopPrank();

        // Alice deposits COLLATERAL_AMOUNT (consuming all intermediate vault liquidity)
        vm.startPrank(alice);
        IERC20(MO_COLLATERAL_TOKEN).approve(address(alice_morpho_vault), type(uint).max);
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.deposit, (COLLATERAL_AMOUNT))
        });
        evc.batch(items);
        vm.stopPrank();

        assertEq(IERC20(MO_COLLATERAL_TOKEN).balanceOf(address(morpho_intermediate_vault)), 0, "Intermediate vault should be empty");

        // Bob cannot withdraw when at 100% utilization
        vm.startPrank(bob);
        vm.expectRevert(Errors.E_InsufficientCash.selector);
        morpho_intermediate_vault.withdraw(1, bob, bob);
        vm.stopPrank();
    }

    // ============================================================
    // HealthStatViewer
    // ============================================================

    // NOTE: MorphoHealthStatViewer is Morpho-specific and should be validated in dedicated viewer tests.

    // ============================================================
    // EVC features
    // ============================================================

    // Alice can modify her own EVC settings but cannot influence her vault's EVC settings
    function test_morpho_evcFeatures() public noGasMetering {
        morpho_firstBorrowDirect(MO_COLLATERAL_TOKEN);

        vm.startPrank(alice);
        bytes19 alice_prefix = bytes19(uint152(uint160(address(alice)) >> 8));
        evc.setLockdownMode(alice_prefix, true);
        assertTrue(evc.isLockdownMode(alice_prefix), "lockdown didn't happen as expected");

        // Alice cannot influence her vault's EVC prefix
        vm.expectRevert(EVCErrors.EVC_NotAuthorized.selector);
        evc.setLockdownMode(bytes19(uint152(uint160(address(alice_morpho_vault)) >> 8)), true);
        vm.stopPrank();
    }

    // ============================================================
    // Freeze state (PauseState.Frozen)
    // Frozen allows repay/withdraw (wind-down) but blocks new exposure
    // (deposit, borrow, skim, setTwyneLiqLTV, vault creation).
    // ============================================================

    // Freeze allows repay() so borrowers can deleverage existing positions during wind-down.
    function test_morpho_freeze_allowsRepay() public noGasMetering {
        morpho_firstBorrowDirect(MO_COLLATERAL_TOKEN);

        vm.prank(admin);
        collateralVaultFactory.setPauseState(PauseState.Frozen);

        vm.startPrank(alice);
        IERC20(MO_LOAN_TOKEN).approve(address(alice_morpho_vault), type(uint256).max);
        alice_morpho_vault.repay(1);
        vm.stopPrank();
    }

    // Freeze allows withdraw() so depositors can exit existing positions during wind-down.
    function test_morpho_freeze_allowsWithdraw() public noGasMetering {
        morpho_collateralDepositWithoutBorrow(MO_COLLATERAL_TOKEN, twyneLiqLTV);

        vm.prank(admin);
        collateralVaultFactory.setPauseState(PauseState.Frozen);

        vm.prank(alice);
        alice_morpho_vault.withdraw(1, alice);
    }

    // Freeze blocks borrow() to prevent new exposure on an existing collateral position.
    function test_morpho_freeze_blocksBorrow() public noGasMetering {
        morpho_collateralDepositWithoutBorrow(MO_COLLATERAL_TOKEN, twyneLiqLTV);

        vm.prank(admin);
        collateralVaultFactory.setPauseState(PauseState.Frozen);

        vm.startPrank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        alice_morpho_vault.borrow(1, alice);
        vm.stopPrank();
    }

    // Freeze blocks deposit() — no new exposure during wind-down.
    function test_morpho_freeze_blocksDeposit() public noGasMetering {
        morpho_collateralDepositWithoutBorrow(MO_COLLATERAL_TOKEN, twyneLiqLTV);

        vm.prank(admin);
        collateralVaultFactory.setPauseState(PauseState.Frozen);

        vm.startPrank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        alice_morpho_vault.deposit(1);
        vm.stopPrank();
    }

    // Freeze blocks skim().
    function test_morpho_freeze_blocksSkim() public noGasMetering {
        morpho_collateralDepositWithoutBorrow(MO_COLLATERAL_TOKEN, twyneLiqLTV);

        vm.prank(admin);
        collateralVaultFactory.setPauseState(PauseState.Frozen);

        vm.startPrank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        alice_morpho_vault.skim();
        vm.stopPrank();
    }

    // Freeze blocks setTwyneLiqLTV() so risk config cannot change during wind-down.
    function test_morpho_freeze_blocksSetTwyneLiqLTV() public noGasMetering {
        morpho_collateralDepositWithoutBorrow(MO_COLLATERAL_TOKEN, twyneLiqLTV);

        vm.prank(admin);
        collateralVaultFactory.setPauseState(PauseState.Frozen);

        vm.startPrank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        alice_morpho_vault.setTwyneLiqLTV(twyneLiqLTV);
        vm.stopPrank();
    }

    // Freeze blocks new vault creation.
    function test_morpho_freeze_blocksVaultCreation() public noGasMetering {
        morpho_creditDeposit(MO_COLLATERAL_TOKEN);

        vm.prank(admin);
        collateralVaultFactory.setPauseState(PauseState.Frozen);

        vm.startPrank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        collateralVaultFactory.createMorphoCollateralVault({
            _intermediateVault: address(morpho_intermediate_vault),
            _targetVault: morpho,
            _marketParams: morphoMarketParams,
            _liqLTV: twyneLiqLTV
        });
        vm.stopPrank();
    }

    // ============================================================
    // Pause granularity (PauseState.Paused blocks every mutation)
    // ============================================================

    // Paused blocks repay().
    function test_morpho_pause_blocksRepay() public noGasMetering {
        morpho_firstBorrowDirect(MO_COLLATERAL_TOKEN);

        vm.prank(admin);
        collateralVaultFactory.setPauseState(PauseState.Paused);

        vm.startPrank(alice);
        IERC20(MO_LOAN_TOKEN).approve(address(alice_morpho_vault), type(uint256).max);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        alice_morpho_vault.repay(1);
        vm.stopPrank();
    }

    // Paused blocks withdraw().
    function test_morpho_pause_blocksWithdraw() public noGasMetering {
        morpho_collateralDepositWithoutBorrow(MO_COLLATERAL_TOKEN, twyneLiqLTV);

        vm.prank(admin);
        collateralVaultFactory.setPauseState(PauseState.Paused);

        vm.startPrank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        alice_morpho_vault.withdraw(1, alice);
        vm.stopPrank();
    }

    // Paused blocks liquidate().
    function test_morpho_pause_blocksLiquidate() public noGasMetering {
        morpho_firstBorrowDirect(MO_COLLATERAL_TOKEN);

        vm.prank(admin);
        collateralVaultFactory.setPauseState(PauseState.Paused);

        vm.startPrank(liquidator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        alice_morpho_vault.liquidate();
        vm.stopPrank();
    }

    // Paused blocks rebalance().
    function test_morpho_pause_blocksRebalance() public noGasMetering {
        morpho_collateralDepositWithoutBorrow(MO_COLLATERAL_TOKEN, twyneLiqLTV);
        vm.warp(block.timestamp + 1000);

        vm.prank(admin);
        collateralVaultFactory.setPauseState(PauseState.Paused);

        vm.startPrank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        alice_morpho_vault.rebalance();
        vm.stopPrank();
    }

    // ============================================================
    // Pause guardian access control
    // ============================================================

    // Guardian's only lever is pause(); setPauseState is admin-only.
    function test_morpho_guardian_cannot_setPauseState() public noGasMetering {
        address guardian = makeAddr("guardian");
        vm.prank(admin);
        collateralVaultFactory.setPauseGuardian(guardian);

        // Guardian can trigger an emergency pause
        vm.prank(guardian);
        collateralVaultFactory.pause();
        assertTrue(collateralVaultFactory.pauseState() == PauseState.Paused);

        // Guardian cannot set arbitrary pause states (e.g. Frozen) — admin only
        vm.prank(guardian);
        vm.expectRevert();
        collateralVaultFactory.setPauseState(PauseState.Frozen);
    }

    // Admin can cycle through every pause level via setPauseState.
    function test_morpho_admin_can_cycle_pause_states() public noGasMetering {
        vm.startPrank(admin);
        collateralVaultFactory.setPauseState(PauseState.Frozen);
        assertTrue(collateralVaultFactory.pauseState() == PauseState.Frozen);

        collateralVaultFactory.setPauseState(PauseState.Paused);
        assertTrue(collateralVaultFactory.pauseState() == PauseState.Paused);

        collateralVaultFactory.setPauseState(PauseState.Active);
        assertTrue(collateralVaultFactory.pauseState() == PauseState.Active);
        vm.stopPrank();
    }

    // ============================================================
    // MVP retirement (wind down an intermediate vault)
    // ============================================================

    // Retire an intermediate vault: block new deposits, boost interest rate, set 100% fee.
    // Mirrors the Euler MVP retirement flow using the EVK intermediate vault directly.
    function test_morpho_MVPRetirement() public noGasMetering {
        morpho_firstBorrowDirect(MO_COLLATERAL_TOKEN);

        vm.startPrank(morpho_intermediate_vault.governorAdmin());
        // 1. prevent deposits by disabling the deposit operation
        morpho_intermediate_vault.setHookConfig(address(0), OP_DEPOSIT);
        // 2. boost interest rate via IRM
        morpho_intermediate_vault.setInterestRateModel(address(new IRMTwyneCurve(0, 750, 49250, 5e17)));
        // 3. set reserve factor to 100%
        morpho_intermediate_vault.setInterestFee(1e4);
        vm.stopPrank();

        // New deposits are now blocked
        vm.startPrank(bob);
        IERC20(MO_COLLATERAL_TOKEN).approve(address(morpho_intermediate_vault), type(uint256).max);
        vm.expectRevert(Errors.E_OperationDisabled.selector);
        morpho_intermediate_vault.deposit(1 ether, bob);
        vm.stopPrank();
    }

    // ============================================================
    // Morpho holds collateral (no receipt token to the CV)
    // ============================================================

    /// @notice Unlike Aave/Euler (where the CV holds the receipt token and can base accounting on
    ///         its own balanceOf), a Morpho CV keeps collateral inside Morpho and must query Morpho
    ///         for state. Prove that the CV does NOT rely on its own token balance for any accounting
    ///         or health view: an unsolicited collateral airdrop directly to the CV leaves every view
    ///         unchanged. Only skim() is allowed to read the local balance.
    function test_morpho_airdropToVaultDoesNotAffectAccounting() public noGasMetering {
        morpho_firstBorrowDirect(MO_COLLATERAL_TOKEN);

        // Snapshot every accounting / health view
        uint256 balBefore = alice_morpho_vault.balanceOf(address(alice_morpho_vault));
        uint256 totalBefore = alice_morpho_vault.totalAssetsDepositedOrReserved();
        uint256 releaseBefore = alice_morpho_vault.maxRelease();
        uint256 repayBefore = alice_morpho_vault.maxRepay();
        uint256 morphoCollateralBefore = alice_morpho_vault.collateralBalance();
        bool canLiqBefore = alice_morpho_vault.canLiquidate();
        bool extLiqBefore = alice_morpho_vault.isExternallyLiquidated();

        // Airdrop collateral directly to the CV (NOT via deposit / supplyCollateral).
        // This inflates IERC20(asset).balanceOf(CV) without touching Morpho or accounting.
        uint256 airdrop = 3 ether;
        uint256 localBefore = IERC20(MO_COLLATERAL_TOKEN).balanceOf(address(alice_morpho_vault));
        deal(MO_COLLATERAL_TOKEN, address(alice_morpho_vault), localBefore + airdrop);
        assertEq(
            IERC20(MO_COLLATERAL_TOKEN).balanceOf(address(alice_morpho_vault)),
            localBefore + airdrop,
            "setup: local balance should reflect airdrop"
        );

        // None of these views may read the local balance — they must be unchanged.
        assertEq(alice_morpho_vault.balanceOf(address(alice_morpho_vault)), balBefore, "balanceOf must not depend on local balance");
        assertEq(alice_morpho_vault.totalAssetsDepositedOrReserved(), totalBefore, "totalAssets must not depend on local balance");
        assertEq(alice_morpho_vault.maxRelease(), releaseBefore, "maxRelease must not depend on local balance");
        assertEq(alice_morpho_vault.maxRepay(), repayBefore, "maxRepay must not depend on local balance");
        assertEq(alice_morpho_vault.collateralBalance(), morphoCollateralBefore, "Morpho collateral must be unchanged by a local airdrop");
        assertEq(alice_morpho_vault.canLiquidate(), canLiqBefore, "canLiquidate must not depend on local balance");
        assertEq(alice_morpho_vault.isExternallyLiquidated(), extLiqBefore, "external-liquidation detection must not depend on local balance");

        // skim() is the sole legitimate local-balance reader: it sweeps the airdrop into Morpho.
        vm.startPrank(alice);
        alice_morpho_vault.skim();
        vm.stopPrank();

        // Local balance fully consumed by skim; the airdrop now shows up in Morpho.
        assertEq(IERC20(MO_COLLATERAL_TOKEN).balanceOf(address(alice_morpho_vault)), 0, "skim should drain local balance");
        assertGe(alice_morpho_vault.collateralBalance(), morphoCollateralBefore + airdrop, "skim should supply airdrop to Morpho");
    }

    /// @notice Pins the fail-closed behavior of an unconfigured (intermediateVault, targetAsset)
    ///         liq-params entry (maxTwyneLTV = externalLiqBuffer = 0), the state a live pair is
    ///         left in when the post-upgrade per-asset config migration is missed or mis-keyed.
    /// @dev With (buffer, maxTwyneLTV) = (0, 0): a debt-free vault is not flagged liquidatable
    ///      (borrowed = 0 fails both _canLiquidate scenarios, exit stays open), while a
    ///      debt-carrying vault is bricked: maxBorrow() is 0, user operations revert with a
    ///      division-by-zero panic (adjExtLiqLTV = 0), and internal liquidation reverts
    ///      VaultStatusLiquidatable with no way to restore health.
    function test_mo_unconfiguredLiqParamsFailClosed() public noGasMetering {
        morpho_collateralDepositWithoutBorrow(MO_COLLATERAL_TOKEN, twyneLiqLTV);
        address intermediateVault = address(alice_morpho_vault.intermediateVault());

        // Debt-free vault: orphaned config must not flag it liquidatable.
        vm.startPrank(admin);
        twyneVaultManager.setMaxLiquidationLTV(intermediateVault, MO_LOAN_TOKEN, 0, 0);
        twyneVaultManager.setExternalLiqBuffer(intermediateVault, MO_LOAN_TOKEN, 0, 0);
        vm.stopPrank();
        assertFalse(alice_morpho_vault.canLiquidate(), "debt-free vault flagged liquidatable");

        // Restore config to take on external debt, then re-orphan the entry.
        vm.startPrank(admin);
        twyneVaultManager.setMaxLiquidationLTV(intermediateVault, MO_LOAN_TOKEN, maxLTVInitial, 0);
        twyneVaultManager.setExternalLiqBuffer(intermediateVault, MO_LOAN_TOKEN, externalLiqBufferInitial, 0);
        vm.stopPrank();

        uint256 borrowAmount = alice_morpho_vault.maxBorrow() / 2;
        vm.startPrank(alice);
        alice_morpho_vault.borrow(borrowAmount, alice);
        vm.stopPrank();

        vm.startPrank(admin);
        twyneVaultManager.setMaxLiquidationLTV(intermediateVault, MO_LOAN_TOKEN, 0, 0);
        twyneVaultManager.setExternalLiqBuffer(intermediateVault, MO_LOAN_TOKEN, 0, 0);
        vm.stopPrank();

        // 1. No new debt can be opened: maxBorrow() is 0 rather than reverting.
        assertEq(alice_morpho_vault.maxBorrow(), 0, "maxBorrow not zero");

        // 2. The debt-carrying vault is flagged liquidatable (buffer = 0 strips the
        //    external-liquidation margin), and user operations revert fail-closed: with
        //    adjExtLiqLTV = 0 the excess-credit invariant math divides by zero before the
        //    deferred checkVaultStatus would reject the batch with VaultStatusLiquidatable.
        assertTrue(alice_morpho_vault.canLiquidate(), "vault not liquidatable");

        vm.startPrank(alice);
        vm.expectRevert(abi.encodePacked(bytes4(0x4e487b71), uint256(0x12))); // Panic: division by zero
        alice_morpho_vault.deposit(0.01e18);
        vm.stopPrank();

        // 3. Internal liquidation cannot unwind the position: liquidate() books the takeover
        //    but the vault status check it requires can never pass while the entry reads (0, 0).
        deal(MO_LOAN_TOKEN, liquidator, borrowAmount + 1_000 ether);
        vm.startPrank(liquidator);
        IERC20_Base(MO_COLLATERAL_TOKEN).approve(address(alice_morpho_vault), type(uint256).max);
        IERC20_Base(MO_LOAN_TOKEN).approve(address(alice_morpho_vault), type(uint256).max);
        vm.expectRevert(TwyneErrors.VaultStatusLiquidatable.selector);
        alice_morpho_vault.liquidate();
        vm.stopPrank();
    }
}
