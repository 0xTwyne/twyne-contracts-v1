// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {EulerTestBase, console2} from "./EulerTestBase.t.sol";
import "euler-vault-kit/EVault/shared/types/Types.sol";
import {EVCUtil} from "ethereum-vault-connector/utils/EVCUtil.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {EulerCollateralVault, IERC20 as IER20_OZ} from "src/twyne/EulerCollateralVault.sol";
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
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {HealthStatViewer} from "src/twyne/HealthStatViewer.sol";
import {IIRM} from "euler-vault-kit/InterestRateModels/IIRM.sol";
import {MockCollateralVault} from "test/mocks/MockCollateralVault.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {GenericFactory} from "euler-vault-kit/GenericFactory/GenericFactory.sol";
import {ProtocolConfig} from "euler-vault-kit/ProtocolConfig/ProtocolConfig.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {BridgeHookTarget} from "src/TwyneFactory/BridgeHookTarget.sol";
import {CrossAdapter} from "euler-price-oracle/src/adapter/CrossAdapter.sol";
import {MockSwapper} from "test/mocks/MockSwapper.sol";

contract NewImplementation {
    uint constant public version = 953;
}

contract EulerTestEdgeCases is EulerTestBase {
    function setUp() public override {
        super.setUp();
    }

    // User creates a 2nd type of collateral vault after already creating a 1st collateral vault
    function test_e_createWSTETHCollateralVault() public noGasMetering {
        e_createCollateralVault(eulerWETH, 0.9e4);

        // Alice creates eWSTETH collateral vault with USDC target asset
        vm.startPrank(alice);
        alice_WSTETH_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _asset: eulerWSTETH,
                _targetVault: eulerUSDC,
                _liqLTV: twyneLiqLTV
            })
        );

        // collateral vaults cannot be enabled as controller
        vm.expectRevert(TwyneErrors.T_CV_OperationDisabled.selector);
        evc.enableController(alice, address(alice_collateral_vault));

        IEVC eulerEVC = IEVC(IEVault(eulerUSDC).EVC());
        vm.expectRevert(TwyneErrors.T_CV_OperationDisabled.selector);
        eulerEVC.enableController(alice, address(alice_collateral_vault));
        vm.stopPrank();

        vm.label(address(alice_WSTETH_collateral_vault), "alice_WSTETH_collateral_vault");
    }

    // Confirm a user can have multiple identical collateral vaults at any given time
    function test_e_secondVaultCreationSameUser() public noGasMetering {
        e_createCollateralVault(eulerWETH, 0.9e4);

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
        e_creditDeposit(eulerWETH);

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

    // Edge case where a batch attempts to force a Twyne liquidation
    // This should not be possible
    function test_e_operatorCanForceLiquidation() public noGasMetering {
        // This test won't work for liq buffer of 1 since the collateral vault becomes liquidatable
        // on Twyne and Euler at the same time. Thus, the batch executed later will be reverted by
        // Euler for items[0].
        vm.startPrank(admin);
        twyneVaultManager.setExternalLiqBuffer(eulerWETH, 0.95e4);
        vm.stopPrank();

        e_firstBorrowFromEulerDirect(eulerWETH);

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
            data: abi.encodeCall(alice_collateral_vault.withdraw, (withdrawAmountTriggerLiquidation * 11/10, liquidator))
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
        e_createCollateralVault(eulerWETH, 0.9e4);

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
        e_createCollateralVault(eulerWETH, 0.9e4);

        vm.startPrank(alice);

        // cannot transferFrom from vault
        vm.expectRevert(TwyneErrors.T_CV_OperationDisabled.selector);
        IERC20(address(alice_collateral_vault)).transferFrom(address(alice_collateral_vault), alice, 1 ether);

        // cannot transfer to eve
        vm.expectRevert(TwyneErrors.T_CV_OperationDisabled.selector);
        IERC20(address(alice_collateral_vault)).transfer(eve, 1 ether);

        // this approve() does nothing because alice never holds vault shares directly
        vm.expectRevert(TwyneErrors.T_CV_OperationDisabled.selector);
        IERC20(address(alice_collateral_vault)).approve(eve, 1 ether);
        vm.stopPrank();

        vm.startPrank(eve);
        vm.expectRevert(TwyneErrors.T_CV_OperationDisabled.selector);
        IERC20(address(alice_collateral_vault)).transferFrom(alice, eve, 1 ether);
        vm.stopPrank();
    }

    function test_e_anyoneCanRepayIntermediateVault() external noGasMetering {
        e_firstBorrowFromEulerDirect(eulerWETH);

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
        e_firstBorrowFromEulerViaCollateral(eulerWETH);
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
        e_collateralDepositWithoutBorrow(eulerWETH, 0.9e4);

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
        vm.expectRevert(Pausable.EnforcedPause.selector);
        alice_collateral_vault.skim();
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

        IERC20(eulerWETH).transfer(address(alice_collateral_vault), 1 ether);
        vm.stopPrank();

        vm.startPrank(alice);
        alice_collateral_vault.skim();
        // after unpause, collateral deposit should work
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
        e_firstBorrowFromEulerViaCollateral(eulerWETH);
        // Test case: verify that actions taken for retire MVP deployment works

        assertEq(eeWETH_intermediate_vault.LTVLiquidation(address(alice_collateral_vault)), 1e4, "unexpected liquidation LTV");
        assertEq(eeWETH_intermediate_vault.LTVBorrow(address(alice_collateral_vault)), 1e4, "unexpected borrow LTV");

        vm.startPrank(twyneVaultManager.owner());
        twyneVaultManager.setLTV(eeWETH_intermediate_vault, address(alice_collateral_vault), 0.08e4, 0.999e4, 100);
        vm.stopPrank();
    }

    // Governance upgrades proxy
    function test_e_proxyUpgrade() public {
        e_createCollateralVault(eulerWETH, 0.9e4);
        assertEq(alice_collateral_vault.version(), 1);
        UpgradeableBeacon beacon = UpgradeableBeacon(collateralVaultFactory.collateralVaultBeacon(eulerUSDC));
        vm.startPrank(admin);
        // set new implementation contract
        beacon.upgradeTo(address(new NewImplementation()));
        assertEq(alice_collateral_vault.version(), 953);
        vm.stopPrank();
    }

    // Governance upgrades proxy
    function test_e_proxyUpgrade_storageSetInConstructor() public {
        e_firstBorrowFromEulerViaCollateral(eulerWETH);
        assertEq(alice_collateral_vault.version(), 1);
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

        assertEq(alice_collateral_vault.balanceOf(alice), COLLATERAL_AMOUNT, "Incorrect alice_collateral_vault upgrade balanceOf()");

        vm.startPrank(alice);
        MockCollateralVault(address(alice_collateral_vault)).setNewValue(112);
        vm.stopPrank();

        assertEq(MockCollateralVault(address(alice_collateral_vault)).newValue(), 112, "Alice upgrade newValue is not 112");
    }

    // Test collateral vault revert cases for test coverage reasons
    function test_e_collateralVaultReverts() public {
        e_createCollateralVault(eulerWETH, 0.9e4);

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
        e_firstBorrowFromEulerViaCollateral(eulerWETH);

        vm.startPrank(alice);

        vm.expectRevert(TwyneErrors.RepayingMoreThanMax.selector);
        alice_collateral_vault.repay(type(uint256).max - 1);

        vm.expectRevert(TwyneErrors.NotCollateralVault.selector);
        collateralVaultFactory.setCollateralVaultLiquidated(address(this));

        vm.stopPrank();
    }

    function test_e_increaseTestCoverage() public {
        e_collateralDepositWithoutBorrow(eulerWETH, 0.9e4);

        address[] memory collats = new address[](2);
        collats[0] = address(0);
        collats[1] = address(1);

        vm.startPrank(alice);
        // verify the vault can't be initialized again
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        alice_collateral_vault.initialize(IER20_OZ(eulerWETH), alice, twyneLiqLTV, twyneVaultManager);
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
        e_collateralDepositWithoutBorrow(eulerWETH, 0.9e4);

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
        e_collateralDepositWithoutBorrow(eulerWETH, 0.9e4);

        assertEq(twyneVaultManager.collateralVaultFactory(), address(collateralVaultFactory), "collateral vault factory incorrectly set before update");
        vm.startPrank(admin);
        CollateralVaultFactory newCollateralVaultFactory = new CollateralVaultFactory(address(evc));
        twyneVaultManager.setCollateralVaultFactory(address(newCollateralVaultFactory));
        assertEq(twyneVaultManager.collateralVaultFactory(), address(newCollateralVaultFactory), "collateral vault factory incorrectly set after update");
        vm.stopPrank();
    }

    function test_e_removeAssetsVaultsFirstIndex() public noGasMetering {
        e_collateralDepositWithoutBorrow(eulerWETH, 0.9e4);

        uint arrayIndex = 0;

        vm.startPrank(admin);

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

        // First test failing case of removeAllowedTargetVault() for better branching test coverage
        vm.expectRevert(TwyneErrors.IncorrectIndex.selector);
        twyneVaultManager.removeAllowedTargetVault(address(eeWSTETH_intermediate_vault), eulerWETH, 1);
        assertEq(twyneVaultManager.allowedTargetVaultList(address(eeWSTETH_intermediate_vault), 1), eulerUSDS, "Target vault not at last index");
        assertEq(twyneVaultManager.targetVaultLength(address(eeWSTETH_intermediate_vault)), 2, "Not actually the last index");
        twyneVaultManager.removeAllowedTargetVault(address(eeWSTETH_intermediate_vault), eulerUSDS, 1);

        vm.stopPrank();
    }

    function newEVKIntermediateVault(address _asset, address _oracle, address _unitOfAccount) internal returns (IEVault) {
        IEVault new_vault = IEVault(factory.createProxy(address(0), true, abi.encodePacked(_asset, _oracle, _unitOfAccount)));

        // set test values, these are placeholders for testing
        // set hook so all borrows and flashloans to use the bridge
        new_vault.setHookConfig(address(new BridgeHookTarget(address(collateralVaultFactory))), OP_BORROW | OP_LIQUIDATE | OP_FLASHLOAN);
        // Base=0.00% APY,  Kink(80.00%)=20.00% APY  Max=120.00% APY
        new_vault.setInterestRateModel(address(new IRMTwyneCurve({
            idealKinkInterestRate_: 600, // 6%
            linearKinkUtilizationRate_: 8000, // 80%
            maxInterestRate_: 50000, // 500%
            nonlinearPoint_: 5e17 // 50%
        })));
        new_vault.setMaxLiquidationDiscount(0.2e4);
        new_vault.setLiquidationCoolOffTime(1);
        new_vault.setFeeReceiver(feeReceiver);
        // new_vault.setInterestFee(0); // set zero governance fee
        // assertEq(new_vault.protocolFeeShare(), 0, "Protocol fee not zero");  // confirm zero protocol fee

        // add intermediate vault share price convert as price oracle
        twyneVaultManager.setOracleResolvedVault(address(new_vault), true);
        twyneVaultManager.setOracleResolvedVault(_asset, true); // need to set this for recursive resolveOracle() lookup
        eulerExternalOracle = EulerRouter(EulerRouter(IEVault(_asset).oracle()).getConfiguredOracle(IEVault(_asset).asset(), USD));
        twyneVaultManager.doCall(address(twyneVaultManager.oracleRouter()), 0, abi.encodeCall(EulerRouter.govSetConfig, (IEVault(_asset).asset(), USD, address(eulerExternalOracle))));
        twyneVaultManager.setIntermediateVault(new_vault);
        new_vault.setGovernorAdmin(address(twyneVaultManager));

        assertEq(new_vault.configFlags() & CFG_DONT_SOCIALIZE_DEBT, 0, "debt isn't socialized");
        return new_vault;
    }

    // Why does Twyne use our own EVC deployment instead of using Euler's setup?
    // This test imitates productionSetup() and then twyneStuff() from the deployment script
    function test_e_whyCustomEVC() public noGasMetering {
        // Imitate productionSetup(), but set the real Euler EVK addresses here
        address oracleRouterFactory;
        if (block.chainid == 1) {
            oracleRouterFactory = 0x70B3f6F61b7Bf237DF04589DdAA842121072326A;
            evc = EthereumVaultConnector(payable(0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383));
            factory = GenericFactory(0x29a56a1b8214D9Cf7c5561811750D5cBDb45CC8e);
            protocolConfig = ProtocolConfig(0x4cD6BF1D183264c02Be7748Cb5cd3A47d013351b);
        } else if (block.chainid == 8453) {
            oracleRouterFactory = 0xA9287853987B107969f181Cce5e25e0D09c1c116;
            evc = EthereumVaultConnector(payable(0x5301c7dD20bD945D2013b48ed0DEE3A284ca8989));
            factory = GenericFactory(0x7F321498A801A191a93C840750ed637149dDf8D0);
            protocolConfig = ProtocolConfig(0x1D4b9e6ACACdc82Dd9E903C3F4431558Af32C4A9);
        } else {
            console2.log("Only supports mainnet and Base right now");
            revert UnknownProfile();
        }

        vm.startPrank(admin);
        // Deploy general Twyne contracts

        // Deploy CollateralVaultFactory implementation
        CollateralVaultFactory factoryImpl = new CollateralVaultFactory(address(evc));

        // Create initialization data for CollateralVaultFactory
        bytes memory factoryInitData = abi.encodeCall(CollateralVaultFactory.initialize, (admin));

        // Deploy CollateralVaultFactory proxy
        ERC1967Proxy factoryProxy = new ERC1967Proxy(address(factoryImpl), factoryInitData);
        collateralVaultFactory = CollateralVaultFactory(payable(address(factoryProxy)));

        vm.label(address(collateralVaultFactory), "collateralVaultFactory");

        // Deploy VaultManager implementation
        VaultManager vaultManagerImpl = new VaultManager();

        // Create initialization data for VaultManager
        bytes memory vaultManagerInitData = abi.encodeCall(VaultManager.initialize, (admin, address(collateralVaultFactory)));

        // Deploy VaultManager proxy
        ERC1967Proxy vaultManagerProxy = new ERC1967Proxy(address(vaultManagerImpl), vaultManagerInitData);
        twyneVaultManager = VaultManager(payable(address(vaultManagerProxy)));

        vm.label(address(twyneVaultManager), "twyneVaultManager");
        oracleRouter = new EulerRouter(address(evc), address(twyneVaultManager));
        vm.label(address(oracleRouter), "oracleRouter");

        address eulerCollateralVaultImpl = address(new EulerCollateralVault(address(evc), eulerUSDC));

        healthViewer = new HealthStatViewer();

        // Change ownership of EVK deploy contracts
        // oracleRouter.transferGovernance(address(twyneVaultManager));

        collateralVaultFactory.setBeacon(eulerUSDC, address(new UpgradeableBeacon(eulerCollateralVaultImpl, admin)));
        collateralVaultFactory.setVaultManager(address(twyneVaultManager));

        twyneVaultManager.setOracleRouter(address(oracleRouter));
        twyneVaultManager.setMaxLiquidationLTV(eulerWETH, 0.9e4);

        // First: deploy intermediate vault, then users can deploy corresponding collateral vaults
        eeWETH_intermediate_vault = newEVKIntermediateVault(eulerWETH, address(oracleRouter), USD);

        twyneVaultManager.setExternalLiqBuffer(eulerWETH, 0.95e4);
        twyneVaultManager.setAllowedTargetVault(address(eeWETH_intermediate_vault), eulerUSDC);

        // Set CrossAdaptor for handling the external liquidation case
        address baseAsset = eulerUSDC;
        address crossAsset = IEVault(eeWETH_intermediate_vault.asset()).unitOfAccount();
        address quoteAsset = IEVault(eeWETH_intermediate_vault.asset()).asset();
        address oracleBaseCross = EulerRouter(IEVault(eulerUSDC).oracle()).getConfiguredOracle(baseAsset, crossAsset);
        address oracleCrossQuote = EulerRouter(IEVault(eulerUSDC).oracle()).getConfiguredOracle(quoteAsset, crossAsset);
        CrossAdapter crossAdaptorOracle = new CrossAdapter(baseAsset, crossAsset, quoteAsset, address(oracleBaseCross), address(oracleCrossQuote));
        twyneVaultManager.doCall(address(twyneVaultManager.oracleRouter()), 0, abi.encodeCall(EulerRouter.govSetConfig, (baseAsset, quoteAsset, address(crossAdaptorOracle))));

        // Next: Deploy collateral vault
        vm.expectRevert(EVCErrors.EVC_ControllerViolation.selector);
        collateralVaultFactory.createCollateralVault({
            _asset: eulerWETH,
            _targetVault: eulerUSDC,
            _liqLTV: twyneLiqLTV
        });
        vm.stopPrank();
    }

    // When can getQuote() return zero? In at least two cases:
    // 1. When the input amount is zero
    // 2. When rounding and decimals cause the result to round down to zero
    function test_e_getQuoteZero() public noGasMetering {
        // test the input amount of zero case
        EulerRouter twyneOracle = twyneVaultManager.oracleRouter();
        uint userCollateralValue = twyneOracle.getQuote(0, eulerWETH, USD);
        assertEq(userCollateralValue, 0, "getQuote is not zero");
        // test the rounding down to zero case
        // have to choose an Euler oracle that is used for a low value asset, something below $1

        if (block.chainid == 1) {
            twyneOracle = EulerRouter(0x8F63048De9e67B90F43D6879168f49527b795d54);
            address oneinch = 0x111111111117dC0aa78b770fA6A738034120C302;
            userCollateralValue = twyneOracle.getQuote(1, oneinch, USD);
            assertEq(userCollateralValue, 0, "getQuote is not zero");
        } else if (block.chainid == 8453) {
            twyneOracle = EulerRouter(0x1e9F00350dA443A0FB532C1CD130487dDa504193);
            address aero = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
            userCollateralValue = twyneOracle.getQuote(1, aero, USD);
            assertEq(userCollateralValue, 0, "getQuote is not zero");
        }
    }

    // Can setting an account operator allow that operator to control the vault's TwyneLiqLTV? Answer is yes
    // We could use this feature to allow users to assign Twyne governance to dynamically control their position to keep them safe
    function test_e_setOperatorChangeTwyneLiqLTVNoBorrow() public noGasMetering {
        e_createCollateralVault(eulerWETH, 0.9e4);

        vm.startPrank(alice);
        // set bob as account operator
        evc.setAccountOperator(alice, bob, true);
        vm.stopPrank();

        vm.startPrank(bob);
        // Toggle LTV
        uint16 newLTV = IEVault(alice_collateral_vault.targetVault()).LTVLiquidation(eulerWETH);

        assertNotEq(alice_collateral_vault.twyneLiqLTV(), newLTV);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.setTwyneLiqLTV, newLTV)
        });
        evc.batch(items);
        vm.stopPrank();

        vm.stopPrank();
    }

    // Test EVC contract function calls
    // Note that these are not currently supported in the collateral vault
    function test_e_evcFeatures() public noGasMetering {
        e_firstBorrowFromEulerViaCollateral(eulerWETH);

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
        e_firstBorrowFromEulerViaCollateral(eulerWETH);

        uint256 externalHF;
        uint256 internalHF;
        uint256 external_liability_value;
        uint256 internal_liability_value;
        (externalHF, internalHF, external_liability_value, internal_liability_value) = healthViewer.health(address(alice_collateral_vault));
        (uint healthFactor, uint collateralValue, uint liabilityValue) = healthViewer.externalHF(address(alice_collateral_vault));
        (healthFactor, collateralValue, liabilityValue) = healthViewer.internalHF(address(alice_collateral_vault));
    }

    function test_e_HealthStatViewerWithoutLiability() public noGasMetering {
        e_createCollateralVault(eulerWETH, 0.9e4);

        uint256 externalHF;
        uint256 internalHF;
        uint256 external_liability_value;
        uint256 internal_liability_value;
        (externalHF, internalHF, external_liability_value, internal_liability_value) = healthViewer.health(address(alice_collateral_vault));
        (uint healthFactor, uint collateralValue, uint liabilityValue) = healthViewer.externalHF(address(alice_collateral_vault));
        (healthFactor, collateralValue, liabilityValue) = healthViewer.internalHF(address(alice_collateral_vault));
    }

    function test_e_teleportRevertsforZeroDeposit() public noGasMetering {
        e_creditDeposit(eulerWETH);

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
        teleporter_collateral_vault.teleport(0, B, 0);
        vm.stopPrank();
    }

    // Test case of collateral price dropping to zero
    // Current result is collateral vault actions (repay, withdraw, etc.) revert
    function test_e_collateralPriceIsZero() public noGasMetering {
        e_firstBorrowFromEulerViaCollateral(eulerWETH);
        address intermediateVault = address(alice_collateral_vault.intermediateVault());

        address eulerRouter = IEVault(intermediateVault).oracle();
        vm.startPrank(EulerRouter(eulerRouter).governor());
        EulerRouter(eulerRouter).govSetConfig(WETH, USD, address(mockOracle));
        // set collateral price to 0
        mockOracle.setPrice(eulerWETH, USD, 0);
        vm.stopPrank();

        eulerRouter = IEVault(eulerUSDC).oracle();
        vm.startPrank(EulerRouter(eulerRouter).governor());
        EulerRouter(eulerRouter).govSetConfig(WETH, USD, address(mockOracle));
        // set collateral price to 0
        mockOracle.setPrice(WETH, USD, 0);

        vm.startPrank(alice);
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint).max);

        // if collateral price is 0, no point in repaying, so it's fine for repay() to revert
        vm.expectRevert(Errors.E_AccountLiquidity.selector);
        alice_collateral_vault.repay(BORROW_USD_AMOUNT);
        // depositing 0 value of collateral isn't needed, so for deposit() to revert
        vm.expectRevert(Errors.E_AccountLiquidity.selector);
        alice_collateral_vault.deposit(COLLATERAL_AMOUNT);
        // TODO: user may want to withdraw 0 value collateral in case it's collateral mispricing or
        // just volatility
        vm.expectRevert(Errors.E_AccountLiquidity.selector);
        alice_collateral_vault.withdraw(COLLATERAL_AMOUNT, alice);
        // borrowing against 0 value collateral shouldn't be allowed
        vm.expectRevert(Errors.E_AccountLiquidity.selector);
        alice_collateral_vault.borrow(1, alice);
        vm.stopPrank();

        assertEq(alice_collateral_vault.canLiquidate(), true, "collateral vault should be liquidatable at 0 collateral price");

        uint256 snapshot = vm.snapshotState();
        vm.startPrank(liquidator);
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint).max);
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);

        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.liquidate, ())
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.repay, (BORROW_USD_AMOUNT))
        });
        items[2] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.withdraw, (type(uint).max, liquidator))
        });

        // collateral vault with 0 value collateral can be liquidated
        evc.batch(items);
        vm.revertToState(snapshot);

        vm.warp(block.timestamp + 1);

        IEVC(IEVault(eulerWETH).EVC()).enableCollateral(liquidator, address(eulerWETH));
        IEVC(IEVault(eulerUSDC).EVC()).enableController(liquidator, address(eulerUSDC));

        (uint maxRepay, uint maxYield) = IEVault(eulerUSDC).checkLiquidation(liquidator, address(alice_collateral_vault), eulerWETH);
        IEVault(eulerUSDC).liquidate(address(alice_collateral_vault), eulerWETH, maxRepay, maxYield);
        assertEq(alice_collateral_vault.maxRepay(), 0);

        evc.enableController(liquidator, intermediateVault);
        items = new IEVC.BatchItem[](2);

        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.handleExternalLiquidation, ())
        });
        items[1] = IEVC.BatchItem({
            targetContract: intermediateVault,
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(IEVault(intermediateVault).liquidate, (address(alice_collateral_vault), address(alice_collateral_vault), 0, 0))
        });

        // Since liability value is 0 (asset price is 0), bad debt isn't recognized
        // and not settled in items[1]. Thus, intermediateVault.debt(collateralVault) is non-zero
        vm.expectRevert(TwyneErrors.BadDebtNotSettled.selector);
        evc.batch(items);
        vm.stopPrank();
    }

    function test_e_fullUtilizationIntermediateVault() public noGasMetering {
        // Alice creates eWETH collateral vault with USDC target asset
        vm.startPrank(alice);
        alice_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _asset: eulerWETH,
                _targetVault: eulerUSDC,
                _liqLTV: twyneLiqLTV
            })
        );

        // Alice approves collateral vault and confirms deposit reverts because intermediate vault is empty
        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint).max);
        vm.expectRevert(Errors.E_InsufficientCash.selector);
        alice_collateral_vault.deposit(1);
        vm.stopPrank();

        // calculate how much to deposit into intermediate vault to get 100% utilization
        uint minorDiff = 10; // this amount can also be deposited without increasing C_LP
        uint exactIntermediateDeposit = getReservedAssets(COLLATERAL_AMOUNT, alice_collateral_vault);

        // find the maximum value of dust deposit made which doesn't reserve more credit after
        // `exactIntermediateDeposit` is deposited by the borrower
        for (uint i = minorDiff; i >= 0; i--) {
            uint exactIntermediateDeposit2 = getReservedAssets(COLLATERAL_AMOUNT+i, alice_collateral_vault);
            if (exactIntermediateDeposit == exactIntermediateDeposit2) {
                minorDiff = i;
                break;
            }
        }

        // Bob deposits exactIntermediateDeposit into the intermediate vault
        vm.startPrank(bob);
        IERC20(eulerWETH).approve(address(eeWETH_intermediate_vault), type(uint256).max);
        eeWETH_intermediate_vault.deposit(exactIntermediateDeposit, bob);
        vm.stopPrank();

        vm.startPrank(alice);
        // Deposit an amount that would create 100% utilization rate
        alice_collateral_vault.deposit(COLLATERAL_AMOUNT);
        assertEq(IERC20(eulerWETH).balanceOf(address(eeWETH_intermediate_vault)), 0, "The intermediate vault is NOT empty");

        // It is possible to deposit this minor diff amount without increasing C_LP
        alice_collateral_vault.deposit(minorDiff);
        // But depositing more beyond this minorDiff amount DOES revert
        vm.expectRevert(Errors.E_InsufficientCash.selector);
        alice_collateral_vault.deposit(1);
        vm.stopPrank();

        // Confirm that if the intermediate vault has 100% utilization, bob cannot withdraw
        vm.startPrank(bob);
        vm.expectRevert(Errors.E_InsufficientCash.selector);
        eeWETH_intermediate_vault.withdraw(1, bob, bob);
        vm.stopPrank();
    }

    ///
    // Test Twyne actions in response to Euler Finance governance actions
    ///

    // Euler changes their governor admin address with Governance.setGovernorAdmin()
    // No impact to Twyne and no action required from Twyne

    // Euler changes their fee receiver address with Governance.setFeeReceiver()
    // No impact to Twyne and no action required from Twyne
    // However, if Twyne starts to collect protocol fees, then Twyne may need to change/align feeReceiver address too
    // but this depends on the agreement with Euler regarding fee sharing

    function test_e_eulerTargetVaultFeeReceiverChange() external noGasMetering {
        e_firstBorrowFromEulerViaCollateral(eulerWETH);

        IEVault targetVault = IEVault(alice_collateral_vault.targetVault());
        vm.startPrank(targetVault.governorAdmin());
        address originalFeeReceiver = targetVault.feeReceiver();
        targetVault.setFeeReceiver(bob);
        vm.stopPrank();

        // Assert that feeReceiver changed
        // Also assert that no Twyne fees exist, meaning that there's no impact
        assertNotEq(originalFeeReceiver, targetVault.feeReceiver());
        assertEq(eeWETH_intermediate_vault.protocolFeeShare(), 0);
        assertEq(eeWETH_intermediate_vault.interestFee(), 0);
    }

    // Euler lowers their borrowing or liquidation LTV with Governance.setLTV()
    // Twyne users will be directly impacted and have less healthy positions
    // NOTE: This is already covered in the most extreme case by test_e_setupLiquidationFromExternalLTVChange() in the Liquidation tests
    // Impacts:
    // 1. Borrowers: One of two things should occur for dynamic adaptation to this scenario:
    // - either the liqLTV_twyne of the borrower is lowered against their will to match the reserved funds or
    // - fresh funds must be reserved on behalf of the borrower.
    // The choice of which design we choose will impact the future design of Twyne https://linear.app/twyneprotocol/issue/TWY-478
    // Currently there is no dynamic response, borrowers must manually interact with their position and update it
    // Twyne will likely implement a dynamic safety buffer that is a function of the underlying protocol's liquidation LTV to enable dynamic adjustment
    // 2. Credit LPs: Credit LPs would not be directly impacted by a decrease of liqLTV_euler,
    // except perhaps by a slight reduction in yields as borrowers shrink their borrow positions and reserved assets to align with the new LTV
    // 3. Protocol: A lower liqLTV_euler likely means the collateral quality has worsened, so maxTwyneLTV for this asset may also need to decrease
    // but changing maxTwyneLTV would not be urgent

    function test_e_eulerTargetVaultLowersLiqLTV() external noGasMetering {
        e_firstBorrowFromEulerViaCollateral(eulerWETH);

        IEVault targetVault = IEVault(alice_collateral_vault.targetVault());

        (uint256 externalHF, uint256 internalHF,, ) = healthViewer.health(address(alice_collateral_vault));

        // at this point, the vault should not be liquidatable (health factor > 1)
        assertGt(externalHF, 1e18, "Vault should be healthy before LTV change");
        assertFalse(alice_collateral_vault.canLiquidate());

        address collateralAsset = alice_collateral_vault.intermediateVault().asset();
        uint16 currentBorrowLTV = targetVault.LTVBorrow(collateralAsset);
        uint16 currentLiquidationLTV = targetVault.LTVLiquidation(collateralAsset);

        vm.startPrank(targetVault.governorAdmin());
        // decrease the borrow and liquidation LTVs of targetvault to make it liquidatable.
        uint16 newLiquidationLTV = currentLiquidationLTV / 2;
        targetVault.setLTV(collateralAsset, currentBorrowLTV / 2, newLiquidationLTV, 0);
        vm.stopPrank();

        assertEq(targetVault.LTVLiquidation(collateralAsset), newLiquidationLTV, "LiqLTV not updated correctly");

        (uint256 newExternalHF, uint256 newInternalHF,, ) = healthViewer.health(address(alice_collateral_vault));

        // Vault should now be liquidatable (health factor < 1)
        assertLt(newExternalHF, 1e18, "Vault should be less healthy after increasing external LiqLTV");
        assertTrue(alice_collateral_vault.canLiquidate());

        // Internal health factor should remain the same since only target vault's liq LTV was changed
        assertEq(newInternalHF, internalHF, "Internal health factor should remain unchanged");

        // Confirm external liquidation is possible from targetVault perspective
        vm.warp(block.timestamp + 1);
        (uint maxrepay, ) = targetVault.checkLiquidation(address(this), address(alice_collateral_vault), eulerWETH);
        assertGt(maxrepay, 0, "Vault cannot be externally liquidated");
    }

    // Euler raises their borrowing or liquidation LTV with Governance.setLTV()
    // Twyne users will be directly impacted and have more healthy positions
    // Impacts:
    // 1. Borrowers: positions become overcollateralized and rebalanceable, because less reserved assets are needed
    // Currently there is no dynamic response, borrowers must manually interact with their position and update it
    // 2. Credit LPs: Credit LPs would not be directly impacted by an increase of liqLTV_euler,
    // except perhaps by a slight increase in yields as borrowers grow their borrow positions and reserved assets to align with the new LTV
    // 3. Protocol: A higher liqLTV_euler likely means the collateral quality has improved, so maxTwyneLTV for this asset may also need to increase
    // but changing maxTwyneLTV would not be urgent

    function test_e_eulerTargetVaultRaisesLiqLTV() external noGasMetering {
        e_maxBorrowFromEulerDirect(eulerWETH, 1e4);

        IEVault targetVault = IEVault(alice_collateral_vault.targetVault());

        (uint256 externalHF, uint256 internalHF,, ) = healthViewer.health(address(alice_collateral_vault));

        address collateralAsset = alice_collateral_vault.intermediateVault().asset();
        uint16 currentBorrowLTV = targetVault.LTVBorrow(collateralAsset);
        uint16 currentLiquidationLTV = targetVault.LTVLiquidation(collateralAsset);

        vm.startPrank(targetVault.governorAdmin());
        // increase the borrow and liquidation LTVs of targetvault.
        uint16 ltvBoost = 700;
        targetVault.setLTV(collateralAsset, currentBorrowLTV + ltvBoost, currentLiquidationLTV + ltvBoost, 0);
        vm.stopPrank();

        assertEq(targetVault.LTVLiquidation(collateralAsset), currentLiquidationLTV + 700, "LiqLTV not updated correctly");

        (uint256 newExternalHF, uint256 newInternalHF,, ) = healthViewer.health(address(alice_collateral_vault));

        // Vault externalHF should now be more healthy
        assertGt(newExternalHF, externalHF, "Vault should be more healthy after increasing external LiqLTV");
        // Internal health factor should remain the same since only target vault's liq LTV was changed
        assertEq(newInternalHF, internalHF, "Internal health factor should remain unchanged");
        // Verify vault is rebalanceable
        assertGt(alice_collateral_vault.canRebalance(), 0, "Vault cannot be rebalanced");
    }

    // Euler changes their maximum liquidation discount with Governance.setMaxLiquidationDiscount()
    // A Twyne governance action to modify liquidation incentives may be in order
    // The Twyne liquidation incentive is effectively 1/maxTwyneLTV, so altering maxTwyneLTV is advised but not urgent

    function test_e_eulerTargetVaultMaxLiqDiscountChange() external noGasMetering {
        e_firstBorrowFromEulerViaCollateral(eulerWETH);

        IEVault targetVault = IEVault(alice_collateral_vault.targetVault());

        // increase the liquidation discount
        vm.startPrank(targetVault.governorAdmin());
        uint16 originalMaxLiquidationDiscount = targetVault.maxLiquidationDiscount();
        targetVault.setMaxLiquidationDiscount(originalMaxLiquidationDiscount * 4 / 3);
        vm.stopPrank();

        // Twyne can optionally reduce the maxTwyneLTV to increase Twyne liquidation incentive
        vm.startPrank(twyneVaultManager.owner());
        uint16 currentMaxLiqLTV = twyneVaultManager.maxTwyneLTVs(eulerWETH);
        twyneVaultManager.setMaxLiquidationLTV(eulerWETH, currentMaxLiqLTV - 100);
        vm.stopPrank();

        // decrease the liquidation discount
        vm.startPrank(targetVault.governorAdmin());
        originalMaxLiquidationDiscount = targetVault.maxLiquidationDiscount();
        targetVault.setMaxLiquidationDiscount(originalMaxLiquidationDiscount / 2);
        vm.stopPrank();

        // Twyne can optionally reduce the maxTwyneLTV to increase Twyne liquidation incentive
        vm.startPrank(twyneVaultManager.owner());
        currentMaxLiqLTV = twyneVaultManager.maxTwyneLTVs(eulerWETH);
        twyneVaultManager.setMaxLiquidationLTV(eulerWETH, currentMaxLiqLTV + 200);
        vm.stopPrank();
    }

    // Euler changes their Governance.setLiquidationCoolOffTime()
    // When an Euler liquidation is attempted, the vault must be outside of the liquidation cool-off timeframe
    // An increase of the liquidation cool-off time can result in slower liquidations for a vault on Euler
    // Note: the cool-off period is ONLY relevant after an Euler governance change

    function test_e_eulerTargetVaultLiqCooloffChange() external noGasMetering {
        e_firstBorrowFromEulerViaCollateral(eulerWETH);

        IEVault targetVault = IEVault(alice_collateral_vault.targetVault());
        uint16 originalCooloffTime = targetVault.liquidationCoolOffTime();

        // increase the liquidation cool-off time
        vm.startPrank(targetVault.governorAdmin());
        uint16 newCooloffTime = originalCooloffTime * 20;
        assertGt(newCooloffTime, 0, "Cool-off time will not change if it was zero to start with");
        targetVault.setLiquidationCoolOffTime(newCooloffTime);
        // also lower the external LTV to test the impact of the new cool-off time
        IEVault(eulerUSDC).setLTV(eulerWETH, 0.5e4, 0.6e4, 0);
        vm.stopPrank();

        // Confirm external liquidation is possible from eulerUSDC perspective
        vm.expectRevert(Errors.E_LiquidationCoolOff.selector);
        (uint maxrepay, ) = IEVault(eulerUSDC).checkLiquidation(address(this), address(alice_collateral_vault), eulerWETH);

        // Now ensure vault is out of liquidation cool-off period
        vm.warp(block.timestamp + newCooloffTime);

        // Confirm external liquidation is possible from eulerUSDC perspective
        (maxrepay, ) = IEVault(eulerUSDC).checkLiquidation(address(this), address(alice_collateral_vault), eulerWETH);
        assertGt(maxrepay, 0, "Vault cannot be externally liquidated");
    }

    // Euler changes their Governance.setInterestRateModel()
    // No impact to Twyne and no action required from Twyne

    // Euler changes their Governance.setHookConfig()
    // This impact Twyne/Euler interactions in different ways
    // Manual review is likely required if this happens to check the precise impact to Twyne

    function test_e_eulerTargetVaultHookChange() public {
        e_firstBorrowFromEulerViaCollateral(eulerWETH);

        IEVault targetVault = IEVault(alice_collateral_vault.targetVault());

        // Set new hook config
        vm.startPrank(targetVault.governorAdmin());
        targetVault.setHookConfig(address(0), OP_MAX_VALUE - 1);
        vm.stopPrank();

        // if no warp forward, we encounter the cool-off error
        vm.expectRevert(Errors.E_LiquidationCoolOff.selector);
        IEVault(eulerUSDC).checkLiquidation(address(this), address(alice_collateral_vault), eulerWETH);

        vm.startPrank(alice);
        // cannot borrow because of newly set hook
        vm.expectRevert(Errors.E_OperationDisabled.selector);
        alice_collateral_vault.borrow(1, alice);

        // cannot repay because of newly set hook
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint256).max);
        vm.expectRevert(Errors.E_OperationDisabled.selector);
        alice_collateral_vault.repay(1);

        // rebalance operation is allowed since this doesn't interact with the target vault
        vm.warp(block.timestamp + 100);
        alice_collateral_vault.rebalance();
        vm.stopPrank();
    }

    // Euler changes their config flags with Governance.setConfigFlags()
    // Config flags only change 2 settings in the current EVK implementation
    // 1. Debt socialization: when bad debt accrues to the Euler EVK vault,
    // it is either socialized across all vault depositors immediately, or the last withdrawers eat the loss
    // 2. Sub-account compatibility: When flag is set, asset is considered to be compatible with EVC sub-accounts and some protections are disabled
    // This impact depositors to the Euler EVK vault much more than borrowers, so Twyne is unaffected by these changes

    // Euler changes their vault supply and/or borrow caps with Governance.setCaps()
    // This impacts anyone interacting with Euler Finance
    // Impacts
    // Borrowers: If borrow cap is reduced, borrowers may not be able to borrow their intended asset from Euler
    // Additionally, the depositUnderlying() function to deposit WETH and bypass the Euler frontend can revert if the supply cap is reached
    // Credit LPs: If the supply cap is reduced, less assets may flow to the intermediate vault when demand for reserving assets is high because
    // only existing eToken holders can deposit to the intermediate vault
    // No impact to Twyne and no action required from Twyne

    // Euler changes their IRM model with Governance.setInterestFee()
    // No impact to Twyne and no action required from Twyne
    // Similar to setInterestRateModel()

    // Euler changes their protocol fee share with ProtocolConfig.setProtocolFeeShare()
    // This simply alters the vault governor and the Euler DAO. Twyne is unaffected by Euler fee changes
    // No impact to Twyne and no action required from Twyne

    // Euler changes their protocol fee share with ProtocolConfig.setVaultInterestFeeRange()
    // This alters the interest fees of a vault, but Twyne does not depend on these interest rates in any way
    // No impact to Twyne and no action required from Twyne

    // Euler changes their protocol fee share with ProtocolConfig.setVaultFeeConfig()
    // This alters the protocol config for a specific vault. If none is set, the default protocol config is used
    // It may be useful to monitor for whether this is ever called by Euler, but no obvious impact exists to Twyne
    // No impact to Twyne and no action required from Twyne

    function e_createDebtPositionOnEuler(address user, address subAccount1) internal {
        IEVC eulerEVC = IEVC(IEVault(eulerUSDC).EVC());

        // Give user some collateral tokens
        uint256 collateralAmount = 10 ether;
        deal(address(IEVault(eulerWETH).asset()), user, collateralAmount);

        // User deposits collateral to Euler for subAccount1
        vm.startPrank(user);
        IERC20(IEVault(eulerWETH).asset()).approve(eulerWETH, collateralAmount);
        IEVault(eulerWETH).deposit(collateralAmount, subAccount1);
        vm.stopPrank();

        uint eulerWETHCollateralAmount = IEVault(eulerWETH).balanceOf(subAccount1);

        // Step 1: Open a borrow position on Euler using subAccount1 through EVC batch
        vm.startPrank(user);

        // Enable controller and collateral for subAccount1
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);
        items[0] = IEVC.BatchItem({
            targetContract: address(eulerEVC),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeCall(IEVC.enableController, (subAccount1, eulerUSDC))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(eulerEVC),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeCall(IEVC.enableCollateral, (subAccount1, eulerWETH))
        });

        // Borrow USDC against eulerWETH collateral
        uint256 borrowAmount = 5000 * 10**6; // 5000 USDC
        items[2] = IEVC.BatchItem({
            targetContract: eulerUSDC,
            onBehalfOfAccount: subAccount1,
            value: 0,
            data: abi.encodeCall(IEVault(eulerUSDC).borrow, (borrowAmount, user))
        });

        eulerEVC.batch(items);
        vm.stopPrank();

        // Verify the borrow position is created
        assertEq(IEVault(eulerUSDC).debtOf(subAccount1), borrowAmount, "Debt not created correctly");
        assertEq(IEVault(eulerWETH).balanceOf(subAccount1), eulerWETHCollateralAmount, "Collateral balance incorrect");
    }

    // Test teleport function with subaccount
    function test_teleportWithSubaccount() public {
        e_creditDeposit(eulerWETH);
        // Setup: Create a user with collateral and a subaccount
        address user = makeAddr("user");
        address subAccount1 = getSubAccount(user, 1);
        vm.label(subAccount1, "subAccount1");
        IEVC eulerEVC = IEVC(IEVault(eulerUSDC).EVC());
        vm.label(address(eulerEVC), "eulerEVC");

        e_createDebtPositionOnEuler(user, subAccount1);

        // Step 2: Create a collateral vault and teleport the position
        vm.startPrank(user);
        EulerCollateralVault teleporter_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createCollateralVault(eulerWETH, eulerUSDC, twyneLiqLTV)
        );
        vm.stopPrank();
        vm.label(address(teleporter_collateral_vault), "teleporter_collateral_vault");
        vm.label(address(teleporter_collateral_vault.intermediateVault()), "intermediateVault");

        // Fetch the eulerUSDC beacon from collateral vault factory
        address currentBeacon = collateralVaultFactory.collateralVaultBeacon(eulerUSDC);
        vm.label(currentBeacon, "currentBeacon");
        address oldImplementation = UpgradeableBeacon(currentBeacon).implementation();
        vm.label(oldImplementation, "implementation");
        require(currentBeacon != address(0), "Beacon not found for eulerUSDC");

        uint collateralAmount = IERC20(eulerWETH).balanceOf(subAccount1);
        uint borrowAmount = IEVault(eulerUSDC).debtOf(subAccount1);

        // Approve and teleport through batch
        uint snapshot = vm.snapshotState();
        vm.startPrank(user);
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: eulerWETH,
            onBehalfOfAccount: subAccount1,
            value: 0,
            data: abi.encodeCall(IERC20.approve, (address(teleporter_collateral_vault), collateralAmount))
        });
        eulerEVC.batch(items);

        items[0] = IEVC.BatchItem({
            targetContract: address(teleporter_collateral_vault),
            onBehalfOfAccount: user,
            value: 0,
            data: abi.encodeCall(EulerCollateralVault.teleport, (collateralAmount, borrowAmount, 1))
        });

        evc.batch(items);
        vm.stopPrank();

        // Verify the teleport was successful
        assertEq(IEVault(eulerUSDC).debtOf(subAccount1), 0, "User debt should be 0 after teleport");
        assertEq(IEVault(eulerWETH).balanceOf(subAccount1), 0, "User collateral should be 0 after teleport");
        assertEq(IEVault(eulerUSDC).debtOf(address(teleporter_collateral_vault)), borrowAmount, "Vault should have the debt");
        assertGt(teleporter_collateral_vault.totalAssetsDepositedOrReserved(), 0, "Vault should have assets");

        vm.revertToState(snapshot);

        vm.startPrank(user);
        items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: eulerWETH,
            onBehalfOfAccount: subAccount1,
            value: 0,
            data: abi.encodeCall(IERC20.approve, (address(teleporter_collateral_vault), collateralAmount))
        });
        eulerEVC.batch(items);

        items[0] = IEVC.BatchItem({
            targetContract: address(teleporter_collateral_vault),
            onBehalfOfAccount: user,
            value: 0,
            data: abi.encodeCall(EulerCollateralVault.teleport, (collateralAmount, type(uint).max, 1))
        });

        evc.batch(items);
        vm.stopPrank();

        // Verify the teleport was successful
        assertEq(IEVault(eulerUSDC).debtOf(subAccount1), 0, "User debt should be 0 after teleport");
        assertEq(IEVault(eulerWETH).balanceOf(subAccount1), 0, "User collateral should be 0 after teleport");
        assertEq(IEVault(eulerUSDC).debtOf(address(teleporter_collateral_vault)), borrowAmount, "Vault should have the debt");
        assertGt(teleporter_collateral_vault.totalAssetsDepositedOrReserved(), 0, "Vault should have assets");
    }

    function test_e_LeverageOperator() public noGasMetering {
        e_creditDeposit(eulerWETH);
        MockSwapper mockSwapper = new MockSwapper();
        vm.etch(eulerSwapper, address(mockSwapper).code);

        vm.startPrank(bob);
        EulerCollateralVault bob_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _asset: eulerWETH,
                _targetVault: eulerUSDC,
                _liqLTV: twyneLiqLTV
            })
        );

        evc.setAccountOperator(bob, address(leverageOperator), true);
        // Approve leverage operator to take user's collateral
        IERC20(eulerWETH).approve(address(leverageOperator), type(uint).max);
        IERC20(WETH).approve(address(leverageOperator), type(uint).max);
        vm.stopPrank();

        // Create collateral vault for user
        vm.startPrank(alice);
        EulerCollateralVault alice_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _asset: eulerWETH,
                _targetVault: eulerUSDC,
                _liqLTV: twyneLiqLTV
            })
        );

        // Approve leverage operator to take user's collateral
        IERC20(eulerWETH).approve(address(leverageOperator), type(uint).max);
        IERC20(WETH).approve(address(leverageOperator), type(uint).max);

        uint userUnderlyingCollateralAmount = 1 ether; // User provides 1 WETH
        uint userCollateralAmount = 1 ether; // User provides 1 eulerWETH
        uint flashloanAmount = 20000 * 1e6; // Flashloan 20,000 USDC
        uint minAmountOutWETH = 20 ether; // Expect at least 20 WETH from swap
        uint deadline = block.timestamp + 10; // deadline of the swap quote

        // Prepare swap data for the swapper
        deal(WETH, eulerSwapper, minAmountOutWETH + 10);
        bytes memory swapData = abi.encodeCall(MockSwapper.swap, (USDC, WETH, flashloanAmount, minAmountOutWETH, eulerWETH));
        bytes[] memory multicallData = new bytes[](1);
        multicallData[0] = swapData;

        vm.expectRevert(TwyneErrors.T_CallerNotBorrower.selector);
        leverageOperator.executeLeverage(
            address(bob_collateral_vault),
            userUnderlyingCollateralAmount,
            userCollateralAmount,
            flashloanAmount,
            minAmountOutWETH,
            deadline,
            multicallData
        );

        vm.expectRevert(EVCErrors.EVC_NotAuthorized.selector);
        leverageOperator.executeLeverage(
            address(alice_collateral_vault),
            userUnderlyingCollateralAmount,
            userCollateralAmount,
            flashloanAmount,
            minAmountOutWETH,
            deadline,
            multicallData
        );

        evc.setAccountOperator(alice, address(leverageOperator), true);
        // Execute leverage through the operator
        leverageOperator.executeLeverage(
            address(alice_collateral_vault),
            userUnderlyingCollateralAmount,
            userCollateralAmount,
            flashloanAmount,
            minAmountOutWETH,
            deadline,
            multicallData
        );

        assertGt(alice_collateral_vault.totalAssetsDepositedOrReserved() - alice_collateral_vault.maxRelease(), userCollateralAmount + userUnderlyingCollateralAmount);
        assertEq(alice_collateral_vault.maxRepay(), flashloanAmount);

        // Verify that LeverageOperator has no remaining token balances
        assertEq(IERC20(eulerWETH).balanceOf(address(leverageOperator)), 0, "LeverageOperator should have 0 eulerWETH");
        assertEq(IERC20(eulerUSDC).balanceOf(address(leverageOperator)), 0, "LeverageOperator should have 0 eulerUSDC");
        assertEq(IERC20(WETH).balanceOf(address(leverageOperator)), 0, "LeverageOperator should have 0 WETH");
        assertEq(IERC20(USDC).balanceOf(address(leverageOperator)), 0, "LeverageOperator should have 0 USDC");


    }
}
