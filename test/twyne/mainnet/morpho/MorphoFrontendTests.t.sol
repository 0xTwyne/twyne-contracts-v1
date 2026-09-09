// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {MorphoTestBase, console2} from "./MorphoTestBase.t.sol";
import "euler-vault-kit/EVault/shared/types/Types.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {MorphoCollateralVault} from "src/twyne/MorphoCollateralVault.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Permit2ECDSASigner} from "euler-vault-kit/../test/mocks/Permit2ECDSASigner.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";
import {IMorpho, MarketParams} from "morpho/interfaces/IMorpho.sol";
import {IOracle} from "morpho/interfaces/IOracle.sol";
import {ORACLE_PRICE_SCALE} from "morpho/libraries/ConstantsLib.sol";
import {MathLib} from "morpho/libraries/MathLib.sol";

/// @title MorphoFrontendTests
/// @notice Tests simulating frontend batch interactions for Morpho integration
/// @dev Morpho differences from Aave/Euler:
///   - No wrapped token (aToken/eToken) — collateral is raw ERC20 (WSTETH)
///   - redeemUnderlying() not applicable — use withdraw() instead
///   - No aToken/eToken deposit/withdrawal paths
///   - No ETH deposit path (Morpho WSTETH/WETH market uses WSTETH directly)
///   - Leverage/deleverage operators not yet implemented for Morpho
contract MorphoFrontendTests is MorphoTestBase {
    using MathLib for uint;

    function setUp() public override {
        super.setUp();
    }

    MorphoCollateralVault user_collateral_vault;

    // ============================================================
    // Credit deposit tests (CLP deposits to intermediate vault)
    // ============================================================

    // Credit deposit: CLP deposits WSTETH to intermediate vault using approve
    // Morpho uses raw collateral token (WSTETH) directly — no wrapper needed
    function test_morpho_frontend_creditDeposit_WithApprove() public noGasMetering {
        IEVault intermediate_vault = morpho_intermediate_vault;

        uint256 depositAmount = 10 ether;
        deal(MO_COLLATERAL_TOKEN, alice, depositAmount);

        vm.startPrank(alice);
        IERC20(MO_COLLATERAL_TOKEN).approve(address(intermediate_vault), depositAmount);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(intermediate_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(intermediate_vault.deposit, (depositAmount, alice))
        });

        evc.batch(items);
        vm.stopPrank();

        assertGt(intermediate_vault.balanceOf(alice), 0, "Alice should have intermediate vault tokens");
    }

    // Credit deposit: CLP deposits WSTETH to intermediate vault using Permit2
    function test_morpho_frontend_creditDeposit_WithPermit2() public noGasMetering {
        IEVault intermediate_vault = morpho_intermediate_vault;

        uint256 depositAmount = 10 ether;
        deal(MO_COLLATERAL_TOKEN, alice, depositAmount);

        vm.startPrank(alice);

        // Approve Permit2 to spend WSTETH
        IERC20(MO_COLLATERAL_TOKEN).approve(permit2, type(uint256).max);

        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: MO_COLLATERAL_TOKEN,
                amount: uint160(depositAmount),
                expiration: type(uint48).max,
                nonce: 0
            }),
            spender: address(intermediate_vault),
            sigDeadline: type(uint256).max
        });

        Permit2ECDSASigner permit2Signer = new Permit2ECDSASigner(address(permit2));

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // Permit2 approval for intermediate vault to spend WSTETH
        items[0] = IEVC.BatchItem({
            targetContract: permit2,
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeWithSignature(
                "permit(address,((address,uint160,uint48,uint48),address,uint256),bytes)",
                alice,
                permitSingle,
                permit2Signer.signPermitSingle(aliceKey, permitSingle)
            )
        });

        // Deposit WSTETH to intermediate vault
        items[1] = IEVC.BatchItem({
            targetContract: address(intermediate_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(intermediate_vault.deposit, (depositAmount, alice))
        });

        evc.batch(items);
        vm.stopPrank();

        assertGt(intermediate_vault.balanceOf(alice), 0, "Alice should have intermediate vault tokens");
    }

    // ============================================================
    // Batch open borrow (create vault + deposit + borrow in one tx)
    // ============================================================

    // Simulates frontend "open position" flow:
    // 1. batchSimulation to validate the tx
    // 2. createCollateralVault
    // 3. Permit2 approval for collateral
    // 4. deposit collateral (WSTETH)
    // 5. borrow loan token (WETH) from Morpho
    function test_morpho_frontend_batchOpenBorrowSim() public noGasMetering {
        morpho_creditDeposit(MO_COLLATERAL_TOKEN);

        // Step 1: Simulate vault creation to get the address
        IEVC.BatchItem[] memory simItems = new IEVC.BatchItem[](1);
        simItems[0] = IEVC.BatchItem({
            targetContract: address(collateralVaultFactory),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(
                collateralVaultFactory.createMorphoCollateralVault,
                (address(morpho_intermediate_vault), morpho, morphoMarketParams, twyneLiqLTV)
            )
        });
        vm.startPrank(alice);
        (IEVC.BatchItemResult[] memory batchItemsResult,,) = evc.batchSimulation(simItems);
        vm.stopPrank();
        assertTrue(batchItemsResult[0].success, "sim: collateral vault deployed");
        user_collateral_vault = MorphoCollateralVault(address(abi.decode(batchItemsResult[0].result, (address))));
        vm.label(address(user_collateral_vault), "alice_morpho_vault_frontend");

        // Step 2: Build the actual batch with Permit2
        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: MO_COLLATERAL_TOKEN,
                amount: uint160(COLLATERAL_AMOUNT),
                expiration: type(uint48).max,
                nonce: 0
            }),
            spender: address(user_collateral_vault),
            sigDeadline: type(uint256).max
        });

        vm.startPrank(alice);
        IERC20(MO_COLLATERAL_TOKEN).approve(permit2, type(uint).max);
        Permit2ECDSASigner permit2Signer = new Permit2ECDSASigner(address(permit2));

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](4);

        // Item 0: Deploy the Morpho collateral vault
        items[0] = IEVC.BatchItem({
            targetContract: address(collateralVaultFactory),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(
                collateralVaultFactory.createMorphoCollateralVault,
                (address(morpho_intermediate_vault), morpho, morphoMarketParams, twyneLiqLTV)
            )
        });

        // Item 1: Permit2 approval for the collateral vault to spend WSTETH
        items[1] = IEVC.BatchItem({
            targetContract: permit2,
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeWithSignature(
                "permit(address,((address,uint160,uint48,uint48),address,uint256),bytes)",
                alice,
                permitSingle,
                permit2Signer.signPermitSingle(aliceKey, permitSingle)
            )
        });

        // Item 2: Deposit WSTETH collateral into collateral vault
        items[2] = IEVC.BatchItem({
            targetContract: address(user_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(user_collateral_vault.deposit, (COLLATERAL_AMOUNT))
        });

        // Item 3: Borrow WETH from Morpho
        items[3] = IEVC.BatchItem({
            targetContract: address(user_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(user_collateral_vault.borrow, (BORROW_WETH_AMOUNT, alice))
        });

        // Simulate first, then execute
        evc.batchSimulation(items);
        evc.batch(items);
        vm.stopPrank();

        assertGt(user_collateral_vault.maxRepay(), 0, "Should have Morpho debt");
        assertEq(user_collateral_vault.borrower(), alice, "Vault borrower should be alice");
    }

    // ============================================================
    // Partial repay + partial withdraw
    // ============================================================

    // Simulates frontend "partial close" flow:
    // 1. Permit2 approval for loan token (WETH)
    // 2. Partial repay of Morpho debt
    // 3. Partial withdraw of collateral (WSTETH)
    function test_morpho_frontend_batchPartialRepayPositionSim() external noGasMetering {
        morpho_firstBorrowDirect(MO_COLLATERAL_TOKEN);

        // Move forward in time to accrue interest
        uint256 blockIncrement = 1000;
        vm.roll(block.number + blockIncrement);
        vm.warp(block.timestamp + 12);

        vm.startPrank(alice);

        uint maxWithdraw = alice_morpho_vault.totalAssetsDepositedOrReserved() - alice_morpho_vault.maxRelease();

        IERC20(MO_LOAN_TOKEN).approve(permit2, type(uint).max);
        Permit2ECDSASigner permit2Signer = new Permit2ECDSASigner(address(permit2));
        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: MO_LOAN_TOKEN,
                amount: type(uint160).max,
                expiration: type(uint48).max,
                nonce: 0
            }),
            spender: address(alice_morpho_vault),
            sigDeadline: type(uint256).max
        });

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);

        // Item 0: Permit2 approval for loan token repayment
        items[0] = IEVC.BatchItem({
            targetContract: permit2,
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeWithSignature(
                "permit(address,((address,uint160,uint48,uint48),address,uint256),bytes)",
                alice,
                permitSingle,
                permit2Signer.signPermitSingle(aliceKey, permitSingle)
            )
        });

        // Item 1: Partial repay — repay half the debt
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.repay, (alice_morpho_vault.maxRepay() - BORROW_WETH_AMOUNT / 2))
        });

        // Item 2: Partial withdraw — withdraw half the collateral
        items[2] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.withdraw, (maxWithdraw - COLLATERAL_AMOUNT / 2, alice))
        });

        // Simulate first, then execute
        evc.batchSimulation(items);
        evc.batch(items);
        vm.stopPrank();

        assertGt(alice_morpho_vault.maxRepay(), 0, "Should still have some debt");
        assertGt(alice_morpho_vault.balanceOf(address(alice_morpho_vault)), 0, "Should still have some collateral");
    }

    // ============================================================
    // Full close position (repay all + withdraw all)
    // ============================================================

    // Simulates frontend "close position" flow:
    // 1. Repay all Morpho debt (WETH)
    // 2. Withdraw all collateral (WSTETH) back to alice
    // Note: Morpho uses withdraw() not redeemUnderlying() since there's no wrapper
    function test_morpho_frontend_batchClosePositionSim() external noGasMetering {
        morpho_firstBorrowDirect(MO_COLLATERAL_TOKEN);

        // Move forward in time to accrue interest
        uint256 blockIncrement = 1000;
        vm.roll(block.number + blockIncrement);
        vm.warp(block.timestamp + 12);

        vm.startPrank(alice);
        IERC20(MO_LOAN_TOKEN).approve(address(alice_morpho_vault), type(uint256).max);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // Item 0: Repay all Morpho debt
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.repay, (type(uint256).max))
        });

        // Item 1: Withdraw all collateral
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.withdraw, (type(uint256).max, alice))
        });

        // Simulate first, then execute
        evc.batchSimulation(items);
        evc.batch(items);
        vm.stopPrank();

        assertEq(alice_morpho_vault.maxRepay(), 0, "Should have no debt");
        assertEq(alice_morpho_vault.maxRelease(), 0, "Should have no intermediate vault debt");
        assertEq(alice_morpho_vault.balanceOf(address(alice_morpho_vault)), 0, "Collateral vault should be empty");
    }

    // ============================================================
    // Credit withdraw from intermediate vault
    // ============================================================

    // Simulates CLP withdrawing their credit from the intermediate vault
    // No wrapper involved — WSTETH is withdrawn directly
    function test_morpho_frontend_creditWithdraw() external noGasMetering {
        IEVault intermediate_vault = morpho_intermediate_vault;

        uint256 depositAmount = 10 ether;
        deal(MO_COLLATERAL_TOKEN, alice, depositAmount);

        vm.startPrank(alice);
        IERC20(MO_COLLATERAL_TOKEN).approve(address(intermediate_vault), depositAmount);
        intermediate_vault.deposit(depositAmount, alice);

        uint256 shares = intermediate_vault.balanceOf(alice);
        assertGt(shares, 0, "Alice should have shares");

        uint256 wstethBefore = IERC20(MO_COLLATERAL_TOKEN).balanceOf(alice);

        // Withdraw half
        uint256 withdrawShares = shares / 2;
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(intermediate_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(intermediate_vault.withdraw, (withdrawShares, alice, alice))
        });
        evc.batch(items);
        vm.stopPrank();

        assertGt(IERC20(MO_COLLATERAL_TOKEN).balanceOf(alice), wstethBefore, "Alice should have received WSTETH");
        assertGt(intermediate_vault.balanceOf(alice), 0, "Alice should still have remaining shares");
    }

    // ============================================================
    // Batch open borrow without simulation
    // ============================================================

    // Same as batchOpenBorrowSim but without simulation step
    // Simulates a direct open-position flow using approve instead of Permit2
    function test_morpho_frontend_batchOpenBorrow_WithApprove() public noGasMetering {
        morpho_creditDeposit(MO_COLLATERAL_TOKEN);

        vm.startPrank(alice);

        // Create vault first to get the address
        address vault = collateralVaultFactory.createMorphoCollateralVault({
            _intermediateVault: address(morpho_intermediate_vault),
            _targetVault: morpho,
            _marketParams: morphoMarketParams,
            _liqLTV: twyneLiqLTV
        });
        MorphoCollateralVault morphoVault = MorphoCollateralVault(vault);

        // Approve collateral
        IERC20(MO_COLLATERAL_TOKEN).approve(vault, type(uint256).max);

        // Batch: deposit + borrow
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        items[0] = IEVC.BatchItem({
            targetContract: vault,
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(morphoVault.deposit, (COLLATERAL_AMOUNT))
        });

        items[1] = IEVC.BatchItem({
            targetContract: vault,
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(morphoVault.borrow, (BORROW_WETH_AMOUNT, alice))
        });

        evc.batch(items);
        vm.stopPrank();

        assertGt(morphoVault.maxRepay(), 0, "Should have Morpho debt");
        assertGt(morphoVault.collateralBalance(), 0, "Should have collateral in Morpho");
    }

    // ============================================================
    // Full close position with Permit2
    // ============================================================

    // Simulates frontend "close position" flow using Permit2 for loan token approval
    function test_morpho_frontend_batchClosePosition_WithPermit2() external noGasMetering {
        morpho_firstBorrowDirect(MO_COLLATERAL_TOKEN);

        // Move forward in time to accrue interest
        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 12);

        vm.startPrank(alice);

        IERC20(MO_LOAN_TOKEN).approve(permit2, type(uint).max);
        Permit2ECDSASigner permit2Signer = new Permit2ECDSASigner(address(permit2));

        uint256 maxRepay = alice_morpho_vault.maxRepay();

        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: MO_LOAN_TOKEN,
                amount: uint160(maxRepay),
                expiration: type(uint48).max,
                nonce: 0
            }),
            spender: address(alice_morpho_vault),
            sigDeadline: type(uint256).max
        });

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);

        // Item 0: Permit2 approval for WETH repayment
        items[0] = IEVC.BatchItem({
            targetContract: permit2,
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeWithSignature(
                "permit(address,((address,uint160,uint48,uint48),address,uint256),bytes)",
                alice,
                permitSingle,
                permit2Signer.signPermitSingle(aliceKey, permitSingle)
            )
        });

        // Item 1: Repay all debt
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.repay, (maxRepay))
        });

        // Item 2: Withdraw all collateral
        items[2] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.withdraw, (alice_morpho_vault.balanceOf(address(alice_morpho_vault)), alice))
        });

        evc.batch(items);
        vm.stopPrank();

        assertEq(alice_morpho_vault.maxRepay(), 0, "Should have no debt");
        assertEq(alice_morpho_vault.maxRelease(), 0, "Should have no intermediate vault debt");
    }
}
