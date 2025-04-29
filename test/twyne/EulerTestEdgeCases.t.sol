// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.28;

import {EulerTestNormalActions, console2} from "./EulerTestNormalActions.t.sol";
import "euler-vault-kit/EVault/shared/types/Types.sol";
import {EVCUtil} from "ethereum-vault-connector/utils/EVCUtil.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {EulerCollateralVault, CollateralVaultBase, IERC20 as IER20_OZ} from "src/twyne/EulerCollateralVault.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {Pausable} from "openzeppelin-contracts/utils/Pausable.sol";
import {Initializable} from "openzeppelin-upgradeable/proxy/utils/Initializable.sol";
import {Errors} from "euler-vault-kit/EVault/shared/Errors.sol";
import {Errors as EVCErrors} from "ethereum-vault-connector/Errors.sol";
import {IRMLinearKink} from "euler-vault-kit/InterestRateModels/IRMLinearKink.sol";
import {IRMTwyneCurve} from "src/twyne/IRMTwyneCurve.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {HealthStatViewer} from "src/twyne/HealthStatViewer.sol";
import {IIRM} from "euler-vault-kit/InterestRateModels/IIRM.sol";
import {MockCollateralVault} from "test/mocks/MockCollateralVault.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Permit2ECDSASigner} from "euler-vault-kit/../test/mocks/Permit2ECDSASigner.sol";

contract NewImplementation {
    uint constant public version = 953;
}

contract EulerTestEdgeCases is EulerTestNormalActions {
    function setUp() public override {
        super.setUp();
    }

    // User creates a 2nd type of collateral vault after already creating a 1st collateral vault
    function test_e_createWSTETHCollateralVault() public noGasMetering {
        test_e_createWETHCollateralVault();

        // Alice creates eWSTETH collateral vault with USDC target asset
        vm.startPrank(alice);
        alice_WSTETH_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _asset: eulerWSTETH,
                _targetVault: eulerUSDC,
                _liqLTV: twyneLiqLTV
            })
        );
        vm.stopPrank();

        vm.label(address(alice_WSTETH_collateral_vault), "alice_WSTETH_collateral_vault");
    }

    // Confirm a user can have multiple identical collateral vaults at any given time
    function test_e_secondVaultCreationSameUser() public noGasMetering {
        test_e_createWETHCollateralVault();

        vm.startPrank(alice);
        // Alice creates another vault with same params
        EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _asset: eulerWETH,
                _targetVault: eulerUSDC,
                _liqLTV: twyneLiqLTV
            })
        );
        vm.stopPrank();
    }

    // Test case where user tries to create a collateral vault with a config that is not allowed
    // In this case, eUSDC is not an allowed collateral
    function test_e_createMismatchCollateralVault() public noGasMetering {
        test_e_creditDeposit();

        // Try creating a collateral vault with a disallowed collateral asset
        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.IntermediateVaultNotSet.selector);
        EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _asset: eulerUSDC,
                _targetVault: eulerUSDC,
                _liqLTV: twyneLiqLTV
            })
        );

        // Try creating a collateral vault with a disallowed target asset
        vm.expectRevert(TwyneErrors.NotIntermediateVault.selector);
        EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _asset: eulerWETH,
                _targetVault: eulerWETH,
                _liqLTV: twyneLiqLTV
            })
        );
        vm.stopPrank();
    }

    // Edge case where a batch attempts to force an external liquidation
    // This should not be possible
    function test_e_verifyBatchCannotForceExtLiquidation() public noGasMetering {
        test_e_firstBorrowFromEulerDirect();

        // to ensure vaults are out of liquidation cool off period
        vm.warp(block.timestamp + 2);

        address eulerEVC = IEVault(eulerWETH).EVC();

        vm.startPrank(alice);
        IERC20(eulerWETH).transfer(address(evc), COLLATERAL_AMOUNT);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](4);
        items[0] = IEVC.BatchItem({
            targetContract: eulerEVC,
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(evc.enableCollateral, (address(evc), eulerWETH))
        });
        items[1] = IEVC.BatchItem({
            targetContract: eulerEVC,
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(evc.enableController, (address(evc), eulerUSDC))
        });
        items[2] = IEVC.BatchItem({
            targetContract: eulerUSDC,
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(IEVault(eulerUSDC).liquidate, (address(alice_collateral_vault), eulerWETH, type(uint).max, 0))
        });
        items[3] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.handleExternalLiquidation, ())
        });

        // cannot make a position unhealthy and liquidate in the same tx.
        // this reverts in items[2] tx.
        vm.expectRevert(TwyneErrors.NotExternallyLiquidated.selector);
        evc.batch(items);
        vm.stopPrank();
    }

    // Edge case where a batch attempts to force a Twyne liquidation
    // This should not be possible
    function test_e_verifyBatchCannotForceLiquidation() public noGasMetering {
        test_e_firstBorrowFromEulerDirect();

        // to ensure vaults are out of liquidation cool off period
        vm.warp(block.timestamp + 2);

        vm.startPrank(liquidator);
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint256).max);
        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint256).max);
        uint borrowerCollateral = alice_collateral_vault.totalAssetsDepositedOrReserved() - alice_collateral_vault.maxRelease();

        (uint externalHF, , , ) = healthViewer.health(address(alice_collateral_vault));
        uint withdrawAmountTriggerLiquidation = borrowerCollateral * (externalHF - 1.01e18) / 1e18;
        vm.stopPrank();

        vm.startPrank(alice);
        evc.setAccountOperator(alice, liquidator, true);
        vm.stopPrank();

        vm.startPrank(liquidator);
        IERC20(eulerWETH).transfer(address(evc), COLLATERAL_AMOUNT);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.withdraw, (withdrawAmountTriggerLiquidation, liquidator))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.liquidate, ())
        });
        items[2] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.deposit, (withdrawAmountTriggerLiquidation))
        });

        evc.batch(items);
        vm.stopPrank();
    }

    // Make sure eve is not allowed to deposit into Alice's vault
    function test_e_eveCantDepositIntoAliceVault() public noGasMetering {
        test_e_createWETHCollateralVault();

        vm.startPrank(eve);
        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint256).max);

        // because alice is the vault owner, eve's deposit should fail
        assert(alice_collateral_vault.borrower() == alice);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_collateral_vault.deposit(COLLATERAL_AMOUNT);
        vm.stopPrank();

        // Even if Alice allows Eve to be an operator on the vault, eve still cannnot deposit
        vm.startPrank(alice);
        evc.setAccountOperator(alice, eve, true);
        vm.stopPrank();

        vm.startPrank(eve);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_collateral_vault.deposit(COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    // Collateral vault does not support standard ERC20 functions like transfer, transferFrom, etc.
    function test_e_aliceCantTransferCollateralShares() public noGasMetering {
        test_e_createWETHCollateralVault();

        vm.startPrank(alice);

        // cannot transferFrom from vault
        vm.expectRevert();
        IERC20(address(alice_collateral_vault)).transferFrom(address(alice_collateral_vault), alice, 1 ether);

        // cannot transfer to eve
        vm.expectRevert();
        IERC20(address(alice_collateral_vault)).transfer(eve, 1 ether);

        // this approve() does nothing because alice never holds vault shares directly
        vm.expectRevert();
        IERC20(address(alice_collateral_vault)).approve(eve, 1 ether);
        vm.stopPrank();

        vm.startPrank(eve);
        vm.expectRevert();
        IERC20(address(alice_collateral_vault)).transferFrom(alice, eve, 1 ether);
        vm.stopPrank();
    }

    function test_e_anyoneCanRepayIntermediateVault() external noGasMetering {
        test_e_firstBorrowFromEulerDirect();

        // alice_collateral_vault holds the Euler debt
        assertEq(alice_collateral_vault.maxRepay(), BORROW_USD_AMOUNT, "collateral vault holding incorrect Euler debt");

        // Move forward in time to observe increase in debts
        uint256 blockIncrement = 1000;
        vm.roll(block.number + blockIncrement);
        vm.warp(block.timestamp + 12);

        // borrower has MORE debt in eUSDC
        assertGt(alice_collateral_vault.maxRelease(), 1e10);
        // collateral vault now has MORE debt in eUSDC
        assertGt(alice_collateral_vault.maxRepay(), BORROW_USD_AMOUNT);

        // now repay - first Euler debt, then withdraw
        vm.startPrank(alice);
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint256).max);
        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint256).max);
        vm.stopPrank();
        assertEq(IERC20(USDC).allowance(alice, address(alice_collateral_vault)), type(uint256).max);

        uint256 aliceCurrentDebt = alice_collateral_vault.maxRelease();

        // Deal assets to someone
        address someone = makeAddr("someone");
        vm.deal(someone, 10 ether);
        deal(address(WETH), someone, INITIAL_DEALT_ERC20);
        dealEToken(address(eulerWETH), someone, INITIAL_DEALT_ETOKEN);

        // Demonstrate that someone can repay all intermediate vault debt on behalf of a collateral vault
        vm.startPrank(someone);
        IERC20(eulerWETH).approve(address(eeWETH_intermediate_vault), type(uint).max);
        uint repaid = eeWETH_intermediate_vault.repay(type(uint).max, address(alice_collateral_vault));
        vm.stopPrank();

        // borrower alice has no debt from intermediate vault
        assertEq(alice_collateral_vault.maxRelease(), 0);
        assertEq(aliceCurrentDebt, repaid);
    }

    // Retire a set of Twyne contract, like early release versions
    function test_e_MVPRetirement() public noGasMetering {
        test_e_firstBorrowFromEulerViaCollateral();
        // Test case: verify that actions taken for retire MVP deployment works
        // To retire intermediate vault:
        // 1. prevent deposits
        // 2. boost interest rate via IRM
        // 3. set reserve factor to 100%
        // TODO Change these calls to use vaultManager's doCall()
        vm.startPrank(address(eeWETH_intermediate_vault.governorAdmin()));
        eeWETH_intermediate_vault.setHookConfig(address(0), OP_DEPOSIT);
        // Base=10% APY,  Kink(50%)=30% APY  Max=100% APY
        eeWETH_intermediate_vault.setInterestRateModel(address(new IRMLinearKink(1406417851, 3871504476, 6356726949, 2147483648)));
        eeWETH_intermediate_vault.setInterestFee(1e4);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(Errors.E_OperationDisabled.selector);
        eeWETH_intermediate_vault.deposit(1 ether, bob);
        vm.stopPrank();
    }

    // Test the scenario of pausing the protocol
    function test_e_pauseProtocol() public noGasMetering {
        test_e_collateralDepositWithoutBorrow();

        vm.startPrank(bob);
        eeWETH_intermediate_vault.deposit(1 ether, bob);
        vm.stopPrank();

        vm.startPrank(admin);
        collateralVaultFactory.pause(true);
        vm.stopPrank();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _asset: eulerWETH,
                _targetVault: eulerUSDC,
                _liqLTV: twyneLiqLTV
            })
        );

        vm.startPrank(address(eeWETH_intermediate_vault.governorAdmin()));
        (address originalHookTarget, ) = eeWETH_intermediate_vault.hookConfig();
        eeWETH_intermediate_vault.setHookConfig(address(0), OP_MAX_VALUE - 1);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(Errors.E_OperationDisabled.selector);
        eeWETH_intermediate_vault.deposit(1 ether, bob);
        vm.expectRevert(Errors.E_OperationDisabled.selector);
        eeWETH_intermediate_vault.withdraw(0.5 ether, bob, bob);
        vm.stopPrank();

        // alice can deposit and withdraw collateral
        vm.startPrank(alice);
        IERC20(WETH).approve(address(alice_collateral_vault), type(uint).max);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        alice_collateral_vault.depositUnderlying(INITIAL_DEALT_ERC20 / 2);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        alice_collateral_vault.deposit(INITIAL_DEALT_ERC20 / 4);
        // withdraw is blocked because of the automatic rebalancing on the intermediate vault, which is paused
        vm.expectRevert(Errors.E_OperationDisabled.selector);
        alice_collateral_vault.withdraw(1 ether, alice);
        vm.stopPrank();

        // Unpause the Twyne protocol
        vm.startPrank(admin);
        collateralVaultFactory.pause(false);
        vm.stopPrank();

        // Unpause the intermediate vault by returning the original setHookConfig settings
        // EXCEPT also allow for skim() to be called now without reverting
        vm.startPrank(address(eeWETH_intermediate_vault.governorAdmin()));
        eeWETH_intermediate_vault.setHookConfig(originalHookTarget, OP_BORROW | OP_LIQUIDATE | OP_FLASHLOAN);
        vm.stopPrank();

        // Confirm skim() works now
        // eve donates to collateral vault, but this doesn't increase its totalAssets
        vm.startPrank(eve);
        IERC20(eulerWETH).transfer(address(eeWETH_intermediate_vault), CREDIT_LP_AMOUNT);
        eeWETH_intermediate_vault.skim(CREDIT_LP_AMOUNT, eve);
        vm.stopPrank();

        // after unpause, collateral deposit should work
        vm.startPrank(alice);
        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint).max);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        // reserve assets from intermediate vault
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.deposit, (COLLATERAL_AMOUNT))
        });

        evc.batch(items);
        vm.stopPrank();
    }

    ///
    // Governance actions
    ///

    // Governance sets LTV ramping
    function test_e_LTVRamping() public noGasMetering {
        test_e_firstBorrowFromEulerViaCollateral();
        // Test case: verify that actions taken for retire MVP deployment works

        assertEq(eeWETH_intermediate_vault.LTVLiquidation(address(alice_collateral_vault)), 1e4, "unexpected liquidation LTV");
        assertEq(eeWETH_intermediate_vault.LTVBorrow(address(alice_collateral_vault)), 1e4, "unexpected borrow LTV");

        vm.startPrank(twyneVaultManager.owner());
        twyneVaultManager.setLTV(eeWETH_intermediate_vault, address(alice_collateral_vault), 0.08e4, 0.999e4, 100);
        vm.stopPrank();
    }

    // Governance upgrades proxy
    function test_e_proxyUpgrade() public {
        test_e_createWETHCollateralVault();
        assertEq(alice_collateral_vault.version(), 0);
        UpgradeableBeacon beacon = UpgradeableBeacon(collateralVaultFactory.collateralVaultBeacon(eulerUSDC));
        vm.startPrank(admin);
        // set new implementation contract
        beacon.upgradeTo(address(new NewImplementation()));
        assertEq(alice_collateral_vault.version(), 953);
        vm.stopPrank();
    }

    // Governance upgrades proxy
    function test_e_proxyUpgrade_storageSetInConstructor() public {
        test_e_firstBorrowFromEulerViaCollateral();
        assertEq(alice_collateral_vault.version(), 0);
        UpgradeableBeacon beacon = UpgradeableBeacon(collateralVaultFactory.collateralVaultBeacon(eulerUSDC));

        vm.startPrank(admin);
        address mockVault = address(new MockCollateralVault(address(evc), eulerUSDC, 7777));
        // set new implementation contract for beacon for existing and future vaults
        beacon.upgradeTo(address(mockVault));
        vm.stopPrank();

        assertEq(beacon.implementation(), address(mockVault));

        MockCollateralVault mock_collateral_vault = MockCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _asset: eulerWETH,
                _targetVault: eulerUSDC,
                _liqLTV: twyneLiqLTV
            })
        );

        assertEq(mock_collateral_vault.version(), 909, "Incorrect mock_collateral_vault upgrade version");
        assertEq(mock_collateral_vault.immutableValue(), 333, "Incorrect mock_collateral_vault upgrade immutableValue");
        assertEq(MockCollateralVault(mockVault).newValue(), 7777, "Incorrect mockVault upgrade newValue");
        assertEq(MockCollateralVault(mockVault).immutableValue(), 333, "Incorrect mockVault upgrade immutableValue");

        // newValue is set in constructor, hence the newValue is 0
        assertEq(mock_collateral_vault.newValue(), 0, "mock_collateral_vault upgrade newValue is not zero");
        assertEq(MockCollateralVault(address(alice_collateral_vault)).newValue(), 0, "Alice upgraded vault newValue is not zero");

        vm.expectRevert("not implemented");
        mock_collateral_vault.disableController();
        vm.expectRevert("not implemented");
        alice_collateral_vault.disableController();

        assertEq(alice_collateral_vault.balanceOf(alice), COLLATERAL_AMOUNT, "Incorrect alice_collateral_vault upgrade balanceOf()");

        vm.startPrank(alice);
        MockCollateralVault(address(alice_collateral_vault)).setNewValue(112);
        vm.stopPrank();

        assertEq(MockCollateralVault(address(alice_collateral_vault)).newValue(), 112, "Alice upgrade newValue is not 112");
    }

    // Test collateral vault revert cases for test coverage reasons
    function test_e_collateralVaultReverts() public {
        test_e_createWETHCollateralVault();

        vm.startPrank(alice);

        vm.expectRevert(TwyneErrors.NotExternallyLiquidated.selector);
        alice_collateral_vault.handleExternalLiquidation();

        vm.expectRevert(TwyneErrors.T_OperationDisabled.selector);
        eeWETH_intermediate_vault.flashLoan(1, abi.encode(""));

        vm.expectRevert(TwyneErrors.T_OperationDisabled.selector);
        eeWETH_intermediate_vault.flashLoan(1, abi.encode(""));

        evc.enableController(alice, address(eeWETH_intermediate_vault));
        evc.enableCollateral(alice, address(alice_collateral_vault));
        vm.expectRevert(TwyneErrors.ReceiverNotCollateralVault.selector);
        eeWETH_intermediate_vault.borrow(1, alice);

        // address[] memory collaterals = address[WETH];
        // alice_collateral_vault.checkAccountStatus(address(alice_collateral_vault), collaterals);

        // Base=0.00% APY,  Kink(80.00%)=10.00% APY  Max=120.00% APY
        address irm = address(new IRMLinearKink(0, 879011157, 25570578576, 3435973836));
        uint ir = IRMLinearKink(irm).computeInterestRateView(address(0), 100, 0);
        ir = IRMLinearKink(irm).computeInterestRateView(address(0), 100, 50);
        ir = IRMLinearKink(irm).computeInterestRateView(address(0), 100, 900);
        vm.expectRevert(IIRM.E_IRMUpdateUnauthorized.selector);
        IRMLinearKink(irm).computeInterestRate(address(0), 100, 900);

        // IRMTwyneCurve curvedIRM = new IRMTwyneCurve(1500, 8000, 12000, 6000);
        IRMTwyneCurve curvedIRM = new IRMTwyneCurve(1000, 8000, 12000, 4000);
        ir = curvedIRM.computeInterestRateView(address(0), 100, 0);
        ir = curvedIRM.computeInterestRateView(address(0), 100, 50);
        ir = curvedIRM.computeInterestRateView(address(0), 100, 900);
        vm.expectRevert(IIRM.E_IRMUpdateUnauthorized.selector);
        curvedIRM.computeInterestRate(address(0), 100, 900);
        vm.expectRevert(IIRM.E_IRMUpdateUnauthorized.selector);
        new IRMTwyneCurve(672, 10001, 12000, 4000);
        vm.stopPrank();

        vm.startPrank(address(eeWETH_intermediate_vault.governorAdmin()));
        eeWETH_intermediate_vault.setInterestRateModel(address(curvedIRM));
        vm.stopPrank();

        // Since the linear IRM and the Twyne curved IRM should be the same before the nonlinearPoint, confirm near equality
        assertApproxEqRel(IRMLinearKink(irm).computeInterestRateView(address(0), 100, 10), curvedIRM.computeInterestRateView(address(0), 100, 10), 5e16, "First IRM results aren't similar");
        assertApproxEqRel(IRMLinearKink(irm).computeInterestRateView(address(0), 100, 50), curvedIRM.computeInterestRateView(address(0), 100, 50), 1e17, "Second IRM results aren't similar");
        // TODO need to test the new upgrade
    }

    // Test collateral vault reverts after a borrow exists
    function test_e_collateralVaultWithBorrowReverts() public {
        test_e_firstBorrowFromEulerViaCollateral();

        vm.startPrank(alice);

        vm.expectRevert(TwyneErrors.RepayingMoreThanMax.selector);
        alice_collateral_vault.repay(type(uint256).max - 1);

        vm.expectRevert(TwyneErrors.NotIntermediateVault.selector);
        collateralVaultFactory.setCollateralVaultLiquidated(address(this));

        vm.stopPrank();
    }

    // Test the disableController() function, only used if a user accidentally enables wrong controller
    function test_e_disableController() public noGasMetering {
        test_e_collateralDepositWithoutBorrow();

        vm.startPrank(bob);
        // Confirm that Bob can call disableController on Alice's vault without the call reverting
        // even though Bob never enabled this controller
        alice_collateral_vault.disableController();
        vm.stopPrank();

        vm.startPrank(alice);
        // Confirm initial starting state
        assertFalse(evc.isControllerEnabled(alice, address(alice_collateral_vault)), "EVC Controller is already enabled?");
        // Alice accidentally enables collateral vault as a controller
        evc.enableController(alice, address(alice_collateral_vault));
        // Confirm controller is enabled
        assertTrue(evc.isControllerEnabled(alice, address(alice_collateral_vault)), "EVC Controller is not enabled?");
        // Now can disable the controller without reverting due to existing borrow
        alice_collateral_vault.disableController();
        assertFalse(evc.isControllerEnabled(alice, address(alice_collateral_vault)), "EVC Controller is already enabled?");
        vm.stopPrank();
    }

    function test_e_increaseTestCoverage() public {
        test_e_collateralDepositWithoutBorrow();

        address[] memory collats = new address[](2);
        collats[0] = address(0);
        collats[1] = address(1);

        vm.startPrank(alice);
        // verify the vault can't be initialized again
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        alice_collateral_vault.initialize(IER20_OZ(eulerWETH), alice, twyneLiqLTV, twyneVaultManager);

        vm.expectRevert(EVCUtil.NotAuthorized.selector);
        alice_collateral_vault.checkAccountStatus(address(0), collats);
        vm.stopPrank();

        vm.startPrank(admin);
        vm.expectRevert(TwyneErrors.IntermediateVaultAlreadySet.selector);
        twyneVaultManager.setIntermediateVault(eeWSTETH_intermediate_vault);
        vm.stopPrank();

        address collateralAsset =  IEVault(eeWSTETH_intermediate_vault).asset();
        vm.expectRevert(TwyneErrors.ValueOutOfRange.selector);
        twyneVaultManager.checkLiqLTV(0, eulerUSDC, collateralAsset);
    }

    // VaultManager.sol tests for coverage

    function test_e_vaultManagerSetterReverts() public noGasMetering {
        test_e_collateralDepositWithoutBorrow();

        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.CallerNotOwnerOrCollateralVaultFactory.selector);
        twyneVaultManager.setLTV(eeWETH_intermediate_vault, address(alice_collateral_vault), 6500, 7500, 0);
        vm.stopPrank();

        twyneVaultManager.targetVaultLength(address(eeWETH_intermediate_vault));

        vm.startPrank(admin);

        // first test a revert case for branch coverage
        vm.expectRevert(TwyneErrors.AssetMismatch.selector);
        twyneVaultManager.setLTV(eeWSTETH_intermediate_vault, address(alice_collateral_vault), 6500, 7500, 0);

        twyneVaultManager.setMaxLiquidationLTV(eulerWETH, 1e4);
        twyneVaultManager.setExternalLiqBuffer(eulerWSTETH, 1e4);
        vm.expectRevert(TwyneErrors.ValueOutOfRange.selector);
        twyneVaultManager.setMaxLiquidationLTV(eulerWETH, 1e4 + 1);

        vm.expectRevert(TwyneErrors.ValueOutOfRange.selector);
        twyneVaultManager.setExternalLiqBuffer(eulerWETH, 0);
        vm.expectRevert(TwyneErrors.ValueOutOfRange.selector);
        twyneVaultManager.setExternalLiqBuffer(eulerWETH, 1e4 + 1);
    }

    function test_e_setNewFactory() public noGasMetering {
        test_e_collateralDepositWithoutBorrow();

        assertEq(twyneVaultManager.collateralVaultFactory(), address(collateralVaultFactory), "collateral vault factory incorrectly set before update");
        vm.startPrank(admin);
        CollateralVaultFactory newCollateralVaultFactory = new CollateralVaultFactory(admin, address(evc));
        twyneVaultManager.setCollateralVaultFactory(address(newCollateralVaultFactory));
        assertEq(twyneVaultManager.collateralVaultFactory(), address(newCollateralVaultFactory), "collateral vault factory incorrectly set after update");
        vm.stopPrank();
    }

    function test_e_removeAssetsVaultsFirstIndex() public noGasMetering {
        test_e_collateralDepositWithoutBorrow();

        uint arrayIndex = 0;

        vm.startPrank(admin);

        // allow USDS target asset for these tests
        twyneVaultManager.setAllowedTargetVault(address(eeWETH_intermediate_vault), eulerUSDS);

        // First test failing case of removeAllowedTargetVault() for better branching test coverage
        vm.expectRevert(TwyneErrors.IncorrectIndex.selector);
        twyneVaultManager.removeAllowedTargetVault(address(eeWETH_intermediate_vault), eulerWETH, arrayIndex);
        assertEq(twyneVaultManager.allowedTargetVaultList(address(eeWETH_intermediate_vault), arrayIndex), eulerUSDC, "Target vault not at first index");
        assertNotEq(twyneVaultManager.targetVaultLength(address(eeWETH_intermediate_vault)), arrayIndex+1, "Target vault may be first, but should not also be the last index");
        twyneVaultManager.removeAllowedTargetVault(address(eeWETH_intermediate_vault), eulerUSDC, arrayIndex);

        vm.stopPrank();
    }

    function test_e_removeAssetsVaultsLastIndex() public noGasMetering {
        test_e_createWSTETHCollateralVault();

        vm.startPrank(admin);

        // allow USDS target asset for these tests
        twyneVaultManager.setAllowedTargetVault(address(eeWSTETH_intermediate_vault), eulerUSDS);

        // First test failing case of removeAllowedTargetVault() for better branching test coverage
        vm.expectRevert(TwyneErrors.IncorrectIndex.selector);
        twyneVaultManager.removeAllowedTargetVault(address(eeWSTETH_intermediate_vault), eulerWETH, 1);
        // NOTE: the line below uses index 0 because the same targetVault is not added twice to the array
        assertEq(twyneVaultManager.allowedTargetVaultList(address(eeWSTETH_intermediate_vault), 1), eulerUSDS, "Target vault not at last index");
        assertEq(twyneVaultManager.targetVaultLength(address(eeWSTETH_intermediate_vault)), 2, "Not actually the last index");
        twyneVaultManager.removeAllowedTargetVault(address(eeWSTETH_intermediate_vault), eulerUSDS, 1);

        vm.stopPrank();
    }

    // Test EVC contract function calls
    // Note that these are not currently supported in the collateral vault
    function test_e_evcFeatures() public noGasMetering {
        test_e_firstBorrowFromEulerViaCollateral();

        vm.startPrank(alice);
        // alice can change her own EVC settings...
        bytes19 alice_prefix = bytes19(uint152(uint160(address(alice)) >> 8));
        evc.setLockdownMode(alice_prefix, true);
        assertTrue(evc.isLockdownMode(alice_prefix), "lockdown didn't happen as expected");

        // ...but alice can't influence her vault
        vm.expectRevert(EVCErrors.EVC_NotAuthorized.selector);
        evc.setLockdownMode(bytes19(uint152(uint160(address(alice_collateral_vault)) >> 8)), true);
        vm.stopPrank();

        vm.startPrank(address(alice_collateral_vault));
        bytes19 alice_vault_prefix = bytes19(uint152(uint160(address(alice_collateral_vault)) >> 8));
        evc.setLockdownMode(alice_vault_prefix, true);
        assertTrue(evc.isLockdownMode(alice_vault_prefix), "lockdown didn't happen as expected");

        evc.setPermitDisabledMode(alice_vault_prefix, true);
        assertTrue(evc.isPermitDisabledMode(alice_vault_prefix), "permit disable mode didn't happen as expected");

        evc.setOperator(alice_vault_prefix, bob, 1);
        assertEq(evc.getOperator(alice_vault_prefix, bob), 1, "setOperator didn't happen as expected");

        vm.stopPrank();

    }

    // Test the HealthStatViewer.sol helper contract
    function test_e_HealthStatViewerWithLiability() public noGasMetering {
        test_e_firstBorrowFromEulerViaCollateral();

        uint256 externalHF;
        uint256 internalHF;
        uint256 external_liability_value;
        uint256 internal_liability_value;
        (externalHF, internalHF, external_liability_value, internal_liability_value) = healthViewer.health(address(alice_collateral_vault));
        (uint healthFactor, uint collateralValue, uint liabilityValue) = healthViewer.externalHF(address(alice_collateral_vault));
        (healthFactor, collateralValue, liabilityValue) = healthViewer.internalHF(address(alice_collateral_vault));
    }

    function test_e_HealthStatViewerWithoutLiability() public noGasMetering {
        test_e_createWETHCollateralVault();

        uint256 externalHF;
        uint256 internalHF;
        uint256 external_liability_value;
        uint256 internal_liability_value;
        (externalHF, internalHF, external_liability_value, internal_liability_value) = healthViewer.health(address(alice_collateral_vault));
        (uint healthFactor, uint collateralValue, uint liabilityValue) = healthViewer.externalHF(address(alice_collateral_vault));
        (healthFactor, collateralValue, liabilityValue) = healthViewer.internalHF(address(alice_collateral_vault));
    }

    // Test Twyne actions in response to Euler Finance governance actions

    // What if Euler pauses a pool
    function test_e_collateralAssetIsPaused() public {
        test_e_firstBorrowFromEulerViaCollateral();

        IEVault intermediateVault = alice_collateral_vault.intermediateVault();
        address governorAdmin = intermediateVault.governorAdmin();

        // pause all operations
        vm.startPrank(governorAdmin);
        intermediateVault.setHookConfig(address(0), OP_MAX_VALUE - 1);
        vm.stopPrank();

        vm.warp(block.timestamp + 100);
        vm.expectRevert(Errors.E_OperationDisabled.selector);
        alice_collateral_vault.rebalance();
    }

    // What if Euler pauses a vault
    function test_e_targetVaultIsPaused() public {
        test_e_firstBorrowFromEulerViaCollateral();

        IEVault targetVault = IEVault(alice_collateral_vault.targetVault());
        address governorAdmin = targetVault.governorAdmin();

        // pause all operations
        vm.startPrank(governorAdmin);
        targetVault.setHookConfig(address(0), OP_MAX_VALUE - 1);
        vm.stopPrank();

        // rebalance operation is allowed since this doesn't trigger
        // any write operation on target vault.
        vm.warp(block.timestamp + 100);
        alice_collateral_vault.rebalance();

        vm.startPrank(alice);
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint256).max);
        vm.expectRevert(Errors.E_OperationDisabled.selector);
        alice_collateral_vault.repay(1);
        vm.stopPrank();
    }

    function test_e_targetVaultChangesLiqLTV() external noGasMetering {
        test_e_firstBorrowFromEulerViaCollateral();

        IEVault targetVault = IEVault(alice_collateral_vault.targetVault());
        address governorAdmin = targetVault.governorAdmin();

        (uint256 externalHF, uint256 internalHF,, ) = healthViewer.health(address(alice_collateral_vault));
        // console2.log("Initial external health factor:", externalHF);
        // console2.log("Initial internal health factor:", internalHF);

        // at this point, the vault should not be liquidatable (health factor > 1)
        assertGt(externalHF, 1e18, "Vault should be healthy before LTV change");
        assertFalse(alice_collateral_vault.canLiquidate());

        address collateralAsset = alice_collateral_vault.intermediateVault().asset();
        uint16 currentBorrowLTV = targetVault.LTVBorrow(collateralAsset);
        uint16 currentLiquidationLTV = targetVault.LTVLiquidation(collateralAsset);

        vm.startPrank(governorAdmin);
        // change the liquidation ltv of targetvault to make it liquidatable.
        uint16 newLiquidationLTV = currentLiquidationLTV / 2;
        targetVault.setLTV(collateralAsset, currentBorrowLTV / 2, newLiquidationLTV, 0);
        vm.stopPrank();

        assertEq(targetVault.LTVLiquidation(collateralAsset), newLiquidationLTV, "LiqLTV not updated correctly");

        (uint256 newExternalHF, uint256 newInternalHF,, ) = healthViewer.health(address(alice_collateral_vault));

        // Vault should now be liquidatable (health factor < 1)
        assertLt(newExternalHF, 1e18, "Vault should be liquidatable after reducing liquidation LTV");
        assertTrue(alice_collateral_vault.canLiquidate());

        // Internal health factor should remain the same since only target vault's liq LTV was changed
        assertEq(newInternalHF, internalHF, "Internal health factor should remain unchanged");
    }

    function test_e_teleportRevertsforZeroDeposit() public noGasMetering {
        test_e_creditDeposit();

        uint C = IERC20(eulerWETH).balanceOf(teleporter);
        uint B = 5000 * (10**6); // $5000

        // create a debt position on Euler for teleporter
        vm.startPrank(teleporter);
        IEVC eulerEVC = IEVC(IEVault(eulerUSDC).EVC());
        eulerEVC.enableController(teleporter, eulerUSDC);
        eulerEVC.enableCollateral(teleporter, eulerWETH);
        IEVault(eulerUSDC).borrow(B, teleporter);
        vm.stopPrank();

        // teleport position
        vm.startPrank(teleporter);
        EulerCollateralVault teleporter_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _asset: eulerWETH,
                _targetVault: eulerUSDC,
                _liqLTV: twyneLiqLTV
            })
        );
        vm.label(address(teleporter_collateral_vault), "teleporter_collateral_vault");

        IEVault(eulerWETH).approve(address(teleporter_collateral_vault), C);

        // Intermediate vault reverts during account status check,
        // since it doesn't allow borrowing against 0 collateral.
        vm.expectRevert(Errors.E_AccountLiquidity.selector);
        teleporter_collateral_vault.teleport(0, B);
        vm.stopPrank();
    }

    // TODO Test the scenario where one user is a credit LP and a borrower at the same time

    // TODO Test the scenario where a fake intermediate vault is created
    // and the borrow from it causes near-instant liquidation for the user
}
