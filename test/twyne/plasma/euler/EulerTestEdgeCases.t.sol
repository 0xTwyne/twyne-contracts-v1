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
import {CollateralVaultFactory, VaultType} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {HealthStatViewer} from "src/twyne/HealthStatViewer.sol";
import {IIRM} from "euler-vault-kit/InterestRateModels/IIRM.sol";
import {MockCollateralVault} from "test/mocks/MockCollateralVault.sol";
import {MockChainlinkOracle} from "test/mocks/MockChainlinkOracle.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {ChainlinkOracle} from "euler-price-oracle/src/adapter/chainlink/ChainlinkOracle.sol";
import {GenericFactory} from "euler-vault-kit/GenericFactory/GenericFactory.sol";
import {ProtocolConfig} from "euler-vault-kit/ProtocolConfig/ProtocolConfig.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {BridgeHookTarget} from "src/TwyneFactory/BridgeHookTarget.sol";
import {CrossAdapter} from "euler-price-oracle/src/adapter/CrossAdapter.sol";
import {MockSwapper} from "test/mocks/MockSwapper.sol";
import { MockDirectPriceOracle } from "test/mocks/MockDirectPriceOracle.sol";

contract NewImplementation {
    uint constant public version = 953;
}

contract EulerTestEdgeCases is EulerTestBase {
    function setUp() public override {
        super.setUp();
    }

    // // User creates a 2nd type of collateral vault after already creating a 1st collateral vault
    // function test_e_createWSTETHCollateralVault() public noGasMetering {
    //     e_createCollateralVault(eulerYzPP, 0.9e4);

    //     // Alice creates eWSTETH collateral vault with USDT target asset
    //     vm.startPrank(alice);
    //     alice_WSTETH_collateral_vault = EulerCollateralVault(
    //         collateralVaultFactory.createCollateralVault({
    //             _vaultType: VaultType.EULER_V2,
    //             _asset: eulerWSTETH,
    //             _targetVault: eulerUSDT,
    //             _liqLTV: twyneLiqLTV,
    //             _targetAsset: address(0)
    //         })
    //     );

    //     // collateral vaults cannot be enabled as controller
    //     vm.expectRevert(TwyneErrors.T_CV_OperationDisabled.selector);
    //     evc.enableController(alice, address(alice_collateral_vault));

    //     IEVC eulerEVC = IEVC(IEVault(eulerUSDT).EVC());
    //     vm.expectRevert(TwyneErrors.T_CV_OperationDisabled.selector);
    //     eulerEVC.enableController(alice, address(alice_collateral_vault));
    //     vm.stopPrank();

    //     vm.label(address(alice_WSTETH_collateral_vault), "alice_WSTETH_collateral_vault");
    // }

    // Confirm a user can have multiple identical collateral vaults at any given time
    function test_e_secondVaultCreationSameUser() public noGasMetering {
        e_createCollateralVault(eulerYzPP, 0.9e4);

        vm.startPrank(alice);
        // Alice creates another vault with same params
        EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.EULER_V2,
                _asset: eulerYzPP,
                _targetVault: eulerUSDT,
                _liqLTV: twyneLiqLTV,
                _targetAsset: address(0)
            })
        );
        vm.stopPrank();
    }

    // Test case where user tries to create a collateral vault with a config that is not allowed
    // In this case, eUSDT is not an allowed collateral
    function test_e_createMismatchCollateralVault() public noGasMetering {
        e_creditDeposit(eulerYzPP);

        // Try creating a collateral vault with a disallowed collateral asset
        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.IntermediateVaultNotSet.selector);
        EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.EULER_V2,
                _asset: eulerUSDT,
                _targetVault: eulerUSDT,
                _liqLTV: twyneLiqLTV,
                _targetAsset: address(0)
            })
        );

        // Try creating a collateral vault with a disallowed target asset
        vm.expectRevert(TwyneErrors.NotIntermediateVault.selector);
        EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.EULER_V2,
                _asset: eulerYzPP,
                _targetVault: eulerYzPP,
                _liqLTV: twyneLiqLTV,
                _targetAsset: address(0)
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
        twyneVaultManager.setExternalLiqBuffer(eulerYzPP, 0.8e4);
        vm.stopPrank();

        e_firstBorrowFromEulerDirect(eulerYzPP);

        // to ensure vaults are out of liquidation cool off period
        vm.warp(block.timestamp + 2);

        vm.startPrank(liquidator);
        IERC20(USDT).approve(address(alice_collateral_vault), type(uint256).max);
        IERC20(eulerYzPP).approve(address(alice_collateral_vault), type(uint256).max);
        uint borrowerCollateral = alice_collateral_vault.totalAssetsDepositedOrReserved() - alice_collateral_vault.maxRelease();

        (uint externalHF, , , ) = healthViewer.health(address(alice_collateral_vault));
        uint withdrawAmountTriggerLiquidation = borrowerCollateral * (externalHF - 1.01e18) / 1e18;
        vm.stopPrank();

        vm.startPrank(alice);
        evc.setAccountOperator(alice, liquidator, true);
        vm.stopPrank();

        vm.startPrank(liquidator);
        IERC20(eulerYzPP).transfer(address(evc), COLLATERAL_AMOUNT);

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
        e_createCollateralVault(eulerYzPP, 0.9e4);

        vm.startPrank(eve);
        IERC20(eulerYzPP).approve(address(alice_collateral_vault), type(uint256).max);

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
        e_createCollateralVault(eulerYzPP, 0.9e4);

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
        e_firstBorrowFromEulerDirect(eulerYzPP);

        // alice_collateral_vault holds the Euler debt
        assertEq(alice_collateral_vault.maxRepay(), BORROW_USD_AMOUNT, "collateral vault holding incorrect Euler debt");

        // Move forward in time to observe increase in debts
        uint256 blockIncrement = 1000;
        vm.roll(block.number + blockIncrement);
        vm.warp(block.timestamp + 12);

        // borrower has MORE debt in eUSDT
        assertGt(alice_collateral_vault.maxRelease(), 1e10);
        // collateral vault now has MORE debt in eUSDT
        assertGt(alice_collateral_vault.maxRepay(), BORROW_USD_AMOUNT);

        // now repay - first Euler debt, then withdraw
        vm.startPrank(alice);
        IERC20(USDT).approve(address(alice_collateral_vault), type(uint256).max);
        IERC20(eulerYzPP).approve(address(alice_collateral_vault), type(uint256).max);
        vm.stopPrank();
        assertEq(IERC20(USDT).allowance(alice, address(alice_collateral_vault)), type(uint256).max);

        uint256 aliceCurrentDebt = alice_collateral_vault.maxRelease();

        // Deal assets to someone
        address someone = makeAddr("someone");
        vm.deal(someone, 10 ether);
        deal(address(YzPP), someone, INITIAL_DEALT_ERC20);
        dealEToken(address(eulerYzPP), someone, INITIAL_DEALT_ETOKEN);

        // Demonstrate that someone can repay all intermediate vault debt on behalf of a collateral vault
        vm.startPrank(someone);
        IERC20(eulerYzPP).approve(address(eeYzPP_intermediate_vault), type(uint).max);
        uint repaid = eeYzPP_intermediate_vault.repay(type(uint).max, address(alice_collateral_vault));
        vm.stopPrank();

        // borrower alice has no debt from intermediate vault
        assertEq(alice_collateral_vault.maxRelease(), 0);
        assertEq(aliceCurrentDebt, repaid);
    }

    // Retire a set of Twyne contract, like early release versions
    function test_e_MVPRetirement() public noGasMetering {
        e_firstBorrowFromEulerViaCollateral(eulerYzPP);
        // Test case: verify that actions taken for retire MVP deployment works
        // To retire intermediate vault:
        // 1. prevent deposits
        // 2. boost interest rate via IRM
        // 3. set reserve factor to 100%
        // TODO Change these calls to use vaultManager's doCall()
        vm.startPrank(address(eeYzPP_intermediate_vault.governorAdmin()));
        eeYzPP_intermediate_vault.setHookConfig(address(0), OP_DEPOSIT);
        // Base=10% APY,  Kink(50%)=30% APY  Max=100% APY
        eeYzPP_intermediate_vault.setInterestRateModel(address(new IRMLinearKink(1406417851, 3871504476, 6356726949, 2147483648)));
        eeYzPP_intermediate_vault.setInterestFee(1e4);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(Errors.E_OperationDisabled.selector);
        eeYzPP_intermediate_vault.deposit(1 ether, bob);
        vm.stopPrank();
    }

    // Test the scenario of pausing the protocol
    function test_e_pauseProtocol() public noGasMetering {
        e_collateralDepositWithoutBorrow(eulerYzPP, 0.9e4);

        vm.startPrank(bob);
        eeYzPP_intermediate_vault.deposit(1 ether, bob);
        vm.stopPrank();

        vm.startPrank(admin);
        collateralVaultFactory.pause(true);
        vm.stopPrank();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.EULER_V2,
                _asset: eulerYzPP,
                _targetVault: eulerUSDT,
                _liqLTV: twyneLiqLTV,
                _targetAsset: address(0)
            })
        );

        vm.startPrank(address(eeYzPP_intermediate_vault.governorAdmin()));
        (address originalHookTarget, ) = eeYzPP_intermediate_vault.hookConfig();
        eeYzPP_intermediate_vault.setHookConfig(address(0), OP_MAX_VALUE - 1);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(Errors.E_OperationDisabled.selector);
        eeYzPP_intermediate_vault.deposit(1 ether, bob);
        vm.expectRevert(Errors.E_OperationDisabled.selector);
        eeYzPP_intermediate_vault.withdraw(0.5 ether, bob, bob);
        vm.stopPrank();

        // alice can deposit and withdraw collateral
        vm.startPrank(alice);
        IERC20(YzPP).approve(address(alice_collateral_vault), type(uint).max);
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
        vm.startPrank(address(eeYzPP_intermediate_vault.governorAdmin()));
        eeYzPP_intermediate_vault.setHookConfig(originalHookTarget, OP_BORROW | OP_LIQUIDATE | OP_FLASHLOAN | OP_PULL_DEBT);
        vm.stopPrank();

        // Confirm skim() works now
        // eve donates to collateral vault, but this doesn't increase its totalAssets
        vm.startPrank(eve);
        IERC20(eulerYzPP).transfer(address(eeYzPP_intermediate_vault), CREDIT_LP_AMOUNT);
        eeYzPP_intermediate_vault.skim(CREDIT_LP_AMOUNT, eve);

        IERC20(eulerYzPP).transfer(address(alice_collateral_vault), 1 ether);
        vm.stopPrank();

        vm.startPrank(alice);
        alice_collateral_vault.skim();
        // after unpause, collateral deposit should work
        IERC20(eulerYzPP).approve(address(alice_collateral_vault), type(uint).max);

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

    // Test that pullDebt is blocked on intermediate vault via BridgeHookTarget
    function test_e_pullDebtBlocked() public noGasMetering {
        e_firstBorrowFromEulerViaCollateral(eulerYzPP);

        // Alice tries to pull debt from her own position via intermediate vault
        // This should revert with T_OperationDisabled because pullDebt is hooked
        // and BridgeHookTarget's fallback reverts
        vm.startPrank(alice);
        evc.enableController(alice, address(eeYzPP_intermediate_vault));

        vm.expectRevert(TwyneErrors.T_OperationDisabled.selector);
        eeYzPP_intermediate_vault.pullDebt(1, address(alice_collateral_vault));
        vm.stopPrank();
    }

    ///
    // Governance actions
    ///

    // Governance sets LTV ramping
    function test_e_LTVRamping() public noGasMetering {
        e_firstBorrowFromEulerViaCollateral(eulerYzPP);
        // Test case: verify that actions taken for retire MVP deployment works

        assertEq(eeYzPP_intermediate_vault.LTVLiquidation(address(alice_collateral_vault)), 1e4, "unexpected liquidation LTV");
        assertEq(eeYzPP_intermediate_vault.LTVBorrow(address(alice_collateral_vault)), 1e4, "unexpected borrow LTV");

        vm.startPrank(twyneVaultManager.owner());
        twyneVaultManager.setLTV(eeYzPP_intermediate_vault, address(alice_collateral_vault), 0.08e4, 0.999e4, 100);
        vm.stopPrank();
    }

    // Governance upgrades proxy
    function test_e_proxyUpgrade() public {
        e_createCollateralVault(eulerYzPP, 0.9e4);
        assertEq(alice_collateral_vault.version(), 1);
        UpgradeableBeacon beacon = UpgradeableBeacon(collateralVaultFactory.collateralVaultBeacon(eulerUSDT));
        vm.startPrank(admin);
        // set new implementation contract
        beacon.upgradeTo(address(new NewImplementation()));
        assertEq(alice_collateral_vault.version(), 953);
        vm.stopPrank();
    }

    // Governance upgrades proxy
    function test_e_proxyUpgrade_storageSetInConstructor() public {
        e_firstBorrowFromEulerViaCollateral(eulerYzPP);
        assertEq(alice_collateral_vault.version(), 1);
        UpgradeableBeacon beacon = UpgradeableBeacon(collateralVaultFactory.collateralVaultBeacon(eulerUSDT));

        vm.startPrank(admin);
        address mockVault = address(new MockCollateralVault(address(evc), eulerUSDT, 7777));
        // set new implementation contract for beacon for existing and future vaults
        beacon.upgradeTo(address(mockVault));
        vm.stopPrank();

        assertEq(beacon.implementation(), address(mockVault));

        MockCollateralVault mock_collateral_vault = MockCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.EULER_V2,
                _asset: eulerYzPP,
                _targetVault: eulerUSDT,
                _liqLTV: twyneLiqLTV,
                _targetAsset: address(0)
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
        e_createCollateralVault(eulerYzPP, 0.9e4);

        vm.startPrank(alice);

        vm.expectRevert(TwyneErrors.NotExternallyLiquidated.selector);
        alice_collateral_vault.handleExternalLiquidation();

        vm.expectRevert(TwyneErrors.T_OperationDisabled.selector);
        eeYzPP_intermediate_vault.flashLoan(1, abi.encode(""));

        vm.expectRevert(TwyneErrors.T_OperationDisabled.selector);
        eeYzPP_intermediate_vault.flashLoan(1, abi.encode(""));

        evc.enableController(alice, address(eeYzPP_intermediate_vault));
        evc.enableCollateral(alice, address(alice_collateral_vault));
        vm.expectRevert(TwyneErrors.CallerNotCollateralVault.selector);
        eeYzPP_intermediate_vault.borrow(1, alice);

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

        vm.startPrank(address(eeYzPP_intermediate_vault.governorAdmin()));
        eeYzPP_intermediate_vault.setInterestRateModel(address(curvedIRM));
        vm.stopPrank();

        // Since the linear IRM and the Twyne curved IRM should be the same before the nonlinearPoint, confirm near equality
        assertApproxEqRel(IRMLinearKink(irm).computeInterestRateView(address(0), 100, 10), curvedIRM.computeInterestRateView(address(0), 100, 10), 5e16, "First IRM results aren't similar");
        assertApproxEqRel(IRMLinearKink(irm).computeInterestRateView(address(0), 100, 50), curvedIRM.computeInterestRateView(address(0), 100, 50), 1e17, "Second IRM results aren't similar");
        // TODO need to test the new upgrade
    }

    // Test collateral vault reverts after a borrow exists
    function test_e_collateralVaultWithBorrowReverts() public {
        e_firstBorrowFromEulerViaCollateral(eulerYzPP);

        vm.startPrank(alice);

        vm.expectRevert(TwyneErrors.RepayingMoreThanMax.selector);
        alice_collateral_vault.repay(type(uint256).max - 1);

        vm.expectRevert(TwyneErrors.NotCollateralVault.selector);
        collateralVaultFactory.setCollateralVaultLiquidated(address(this));

        vm.stopPrank();
    }

    function test_e_increaseTestCoverage() public {
        e_collateralDepositWithoutBorrow(eulerYzPP, 0.9e4);

        address[] memory collats = new address[](2);
        collats[0] = address(0);
        collats[1] = address(1);

        vm.startPrank(alice);
        // verify the vault can't be initialized again
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        alice_collateral_vault.initialize(IER20_OZ(eulerYzPP), alice, twyneLiqLTV, twyneVaultManager);
        vm.stopPrank();

        vm.startPrank(admin);
        vm.expectRevert(TwyneErrors.IntermediateVaultAlreadySet.selector);
        twyneVaultManager.setIntermediateVault(eeYzPP_intermediate_vault);
        vm.stopPrank();

        // address collateralAsset =  IEVault(eeWSTETH_intermediate_vault).asset();
        // vm.expectRevert(TwyneErrors.ValueOutOfRange.selector);
        // twyneVaultManager.checkLiqLTV(0, eulerUSDT, collateralAsset);
    }

    // VaultManager.sol tests for coverage

    function test_e_vaultManagerSetterReverts() public noGasMetering {
        e_collateralDepositWithoutBorrow(eulerYzPP, 0.9e4);

        vm.startPrank(alice);
        vm.expectRevert(TwyneErrors.CallerNotOwnerOrCollateralVaultFactory.selector);
        twyneVaultManager.setLTV(eeYzPP_intermediate_vault, address(alice_collateral_vault), 6500, 7500, 0);
        vm.stopPrank();

        twyneVaultManager.targetVaultLength(address(eeYzPP_intermediate_vault));

        vm.startPrank(admin);

        // first test a revert case for branch coverage
        // vm.expectRevert(TwyneErrors.AssetMismatch.selector);
        // twyneVaultManager.setLTV(eeWSTETH_intermediate_vault, address(alice_collateral_vault), 6500, 7500, 0);

        twyneVaultManager.setMaxLiquidationLTV(eulerYzPP, 1e4);
        vm.expectRevert(TwyneErrors.ValueOutOfRange.selector);
        twyneVaultManager.setMaxLiquidationLTV(eulerYzPP, 1e4 + 1);

        vm.expectRevert(TwyneErrors.ValueOutOfRange.selector);
        twyneVaultManager.setExternalLiqBuffer(eulerYzPP, 0);
        vm.expectRevert(TwyneErrors.ValueOutOfRange.selector);
        twyneVaultManager.setExternalLiqBuffer(eulerYzPP, 1e4 + 1);
    }

    function test_e_setNewFactory() public noGasMetering {
        e_collateralDepositWithoutBorrow(eulerYzPP, 0.9e4);

        assertEq(twyneVaultManager.collateralVaultFactory(), address(collateralVaultFactory), "collateral vault factory incorrectly set before update");
        vm.startPrank(admin);
        CollateralVaultFactory newCollateralVaultFactory = new CollateralVaultFactory(address(evc));
        twyneVaultManager.setCollateralVaultFactory(address(newCollateralVaultFactory));
        assertEq(twyneVaultManager.collateralVaultFactory(), address(newCollateralVaultFactory), "collateral vault factory incorrectly set after update");
        vm.stopPrank();
    }

    function test_e_removeAssetsVaultsFirstIndex() public noGasMetering {
        e_collateralDepositWithoutBorrow(eulerYzPP, 0.9e4);

        uint arrayIndex = 0;

        vm.startPrank(admin);

        // First test failing case of removeAllowedTargetVault() for better branching test coverage
        vm.expectRevert(TwyneErrors.IncorrectIndex.selector);
        twyneVaultManager.removeAllowedTargetVault(address(eeYzPP_intermediate_vault), eulerYzPP, arrayIndex);
        assertEq(twyneVaultManager.allowedTargetVaultList(address(eeYzPP_intermediate_vault), arrayIndex), eulerUSDT, "Target vault not at first index");
        // Since we have only one target asset and vault, these will fail
        // assertNotEq(twyneVaultManager.targetVaultLength(address(eeYzPP_intermediate_vault)), arrayIndex+1, "Target vault may be first, but should not also be the last index");
        // twyneVaultManager.removeAllowedTargetVault(address(eeYzPP_intermediate_vault), eulerUSDT, arrayIndex);

        vm.stopPrank();
    }

    // function test_e_removeAssetsVaultsLastIndex() public noGasMetering {
    //     test_e_createWSTETHCollateralVault();

    //     vm.startPrank(admin);

    //     // First test failing case of removeAllowedTargetVault() for better branching test coverage
    //     vm.expectRevert(TwyneErrors.IncorrectIndex.selector);
    //     twyneVaultManager.removeAllowedTargetVault(address(eeWSTETH_intermediate_vault), eulerYzPP, 1);
    //     assertEq(twyneVaultManager.allowedTargetVaultList(address(eeWSTETH_intermediate_vault), 1), eulerUSDS, "Target vault not at last index");
    //     assertEq(twyneVaultManager.targetVaultLength(address(eeWSTETH_intermediate_vault)), 2, "Not actually the last index");
    //     twyneVaultManager.removeAllowedTargetVault(address(eeWSTETH_intermediate_vault), eulerUSDS, 1);

    //     vm.stopPrank();
    // }

    function newEVKIntermediateVault(address _asset, address _oracle, address _unitOfAccount) internal returns (IEVault) {
        IEVault new_vault = IEVault(factory.createProxy(address(0), true, abi.encodePacked(_asset, _oracle, _unitOfAccount)));

        // set test values, these are placeholders for testing
        // set hook so all borrows and flashloans to use the bridge
        new_vault.setHookConfig(address(new BridgeHookTarget(address(collateralVaultFactory))), OP_BORROW | OP_LIQUIDATE | OP_FLASHLOAN | OP_PULL_DEBT);
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

        oracleRouterFactory = 0x7e539159a06CFe0A9f855d22dD82aD95eDf8C2F1;
        evc = EthereumVaultConnector(payable(0x7bdbd0A7114aA42CA957F292145F6a931a345583));
        factory = GenericFactory(0x42388213C6F56D7E1477632b58Ae6Bba9adeEeA3);
        protocolConfig = ProtocolConfig(0x593Ab8A0182f752c6f1af52CA2A0E8B9F868f64A);


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

        address eulerCollateralVaultImpl = address(new EulerCollateralVault(address(evc), eulerUSDT));

        // Change ownership of EVK deploy contracts
        // oracleRouter.transferGovernance(address(twyneVaultManager));

        collateralVaultFactory.setBeacon(eulerUSDT, address(new UpgradeableBeacon(eulerCollateralVaultImpl, admin)));
        collateralVaultFactory.setVaultManager(address(twyneVaultManager));

        twyneVaultManager.setOracleRouter(address(oracleRouter));
        twyneVaultManager.setMaxLiquidationLTV(eulerYzPP, 0.9e4);

        // First: deploy intermediate vault, then users can deploy corresponding collateral vaults
        eeYzPP_intermediate_vault = newEVKIntermediateVault(eulerYzPP, address(oracleRouter), USD);

        twyneVaultManager.setExternalLiqBuffer(eulerYzPP, 0.95e4);
        twyneVaultManager.setAllowedTargetVault(address(eeYzPP_intermediate_vault), eulerUSDT);

        // Set CrossAdaptor for handling the external liquidation case
        address baseAsset = eulerUSDT;
        address crossAsset = IEVault(eeYzPP_intermediate_vault.asset()).unitOfAccount();
        address quoteAsset = IEVault(eeYzPP_intermediate_vault.asset()).asset();
        address oracleBaseCross = EulerRouter(IEVault(eulerUSDT).oracle()).getConfiguredOracle(baseAsset, crossAsset);
        address oracleCrossQuote = EulerRouter(IEVault(eulerUSDT).oracle()).getConfiguredOracle(quoteAsset, crossAsset);
        CrossAdapter crossAdaptorOracle = new CrossAdapter(baseAsset, crossAsset, quoteAsset, address(oracleBaseCross), address(oracleCrossQuote));
        twyneVaultManager.doCall(address(twyneVaultManager.oracleRouter()), 0, abi.encodeCall(EulerRouter.govSetConfig, (baseAsset, quoteAsset, address(crossAdaptorOracle))));

        // Next: Deploy collateral vault
        vm.expectRevert(EVCErrors.EVC_ControllerViolation.selector);
        collateralVaultFactory.createCollateralVault({
            _vaultType: VaultType.EULER_V2,
            _asset: eulerYzPP,
            _targetVault: eulerUSDT,
            _liqLTV: twyneLiqLTV,
            _targetAsset: address(0)
        });
        vm.stopPrank();
    }

    // When can getQuote() return zero? In at least two cases:
    // 1. When the input amount is zero
    // 2. When rounding and decimals cause the result to round down to zero
    function test_e_getQuoteZero() public noGasMetering {
        // test the input amount of zero case
        EulerRouter twyneOracle = twyneVaultManager.oracleRouter();
        uint userCollateralValue = twyneOracle.getQuote(0, eulerYzPP, USD);
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
        e_createCollateralVault(eulerYzPP, 0.9e4);

        vm.startPrank(alice);
        // set bob as account operator
        evc.setAccountOperator(alice, bob, true);
        vm.stopPrank();

        vm.startPrank(bob);
        // Toggle LTV
        uint16 newLTV = IEVault(alice_collateral_vault.targetVault()).LTVLiquidation(eulerYzPP);

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
        e_firstBorrowFromEulerViaCollateral(eulerYzPP);

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
        e_firstBorrowFromEulerViaCollateral(eulerYzPP);

        uint256 externalHF;
        uint256 internalHF;
        uint256 external_liability_value;
        uint256 internal_liability_value;
        (externalHF, internalHF, external_liability_value, internal_liability_value) = healthViewer.health(address(alice_collateral_vault));
        (uint healthFactor, uint collateralValue, uint liabilityValue) = healthViewer.externalHF(address(alice_collateral_vault));
        (healthFactor, collateralValue, liabilityValue) = healthViewer.internalHF(address(alice_collateral_vault));
    }

    function test_e_HealthStatViewerWithoutLiability() public noGasMetering {
        e_createCollateralVault(eulerYzPP, 0.9e4);

        uint256 externalHF;
        uint256 internalHF;
        uint256 external_liability_value;
        uint256 internal_liability_value;
        (externalHF, internalHF, external_liability_value, internal_liability_value) = healthViewer.health(address(alice_collateral_vault));
        (uint healthFactor, uint collateralValue, uint liabilityValue) = healthViewer.externalHF(address(alice_collateral_vault));
        (healthFactor, collateralValue, liabilityValue) = healthViewer.internalHF(address(alice_collateral_vault));
    }

    function test_e_teleportRevertsforZeroDeposit() public noGasMetering {
        e_creditDeposit(eulerYzPP);
        uint C = IERC20(eulerYzPP).balanceOf(teleporter);
        uint B = 5 * (10**6); // $5000

        // create a debt position on Euler for teleporter
        vm.startPrank(teleporter);
        IEVC eulerEVC = IEVC(IEVault(eulerUSDT).EVC());
        eulerEVC.enableController(teleporter, eulerUSDT);
        eulerEVC.enableCollateral(teleporter, eulerYzPP);
        IEVault(eulerUSDT).borrow(B, teleporter);
        vm.stopPrank();

        // teleport position
        vm.startPrank(teleporter);
        EulerCollateralVault teleporter_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.EULER_V2,
                _asset: eulerYzPP,
                _targetVault: eulerUSDT,
                _liqLTV: twyneLiqLTV,
                _targetAsset: address(0)
            })
        );
        vm.label(address(teleporter_collateral_vault), "teleporter_collateral_vault");

        IEVault(eulerYzPP).approve(address(teleporter_collateral_vault), C);

        // Intermediate vault reverts during account status check,
        // since it doesn't allow borrowing against 0 collateral.
        vm.expectRevert(Errors.E_AccountLiquidity.selector);
        teleporter_collateral_vault.teleport(0, B, 0);
        vm.stopPrank();
    }

    // Test case of collateral price dropping to zero
    // Current result is collateral vault actions (repay, withdraw, etc.) revert
    function test_e_collateralPriceIsZero() public noGasMetering {
        e_firstBorrowFromEulerViaCollateral(eulerYzPP);
        address intermediateVault = address(alice_collateral_vault.intermediateVault());


        address eulerRouter = IEVault(eulerUSDT).oracle();
        // If safety buffer is very high, set price with mockOracle?
        MockDirectPriceOracle directOracle = new MockDirectPriceOracle();
        vm.startPrank(EulerRouter(eulerRouter).governor());
        EulerRouter(eulerRouter).govSetConfig(YzPP, USD, address(directOracle));
        EulerRouter(eulerRouter).govSetResolvedVault(YzPP, false);
        directOracle.setPrice(YzPP, USD, 0);
        vm.stopPrank();

        vm.startPrank(oracleRouter.governor());
        oracleRouter.govSetConfig(YzPP, USD, address(directOracle));
        oracleRouter.govSetResolvedVault(YzPP, false);
        vm.stopPrank();


        vm.startPrank(alice);
        IERC20(USDT).approve(address(alice_collateral_vault), type(uint).max);

        // // if collateral price is 0, no point in repaying, so it's fine for repay() to revert
        // vm.expectRevert(Errors.E_AccountLiquidity.selector);
        // alice_collateral_vault.repay(BORROW_USD_AMOUNT);
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
        IERC20(USDT).approve(address(alice_collateral_vault), type(uint).max);
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

        IEVC(IEVault(eulerYzPP).EVC()).enableCollateral(liquidator, address(eulerYzPP));
        IEVC(IEVault(eulerUSDT).EVC()).enableController(liquidator, address(eulerUSDT));

        (uint maxRepay, uint maxYield) = IEVault(eulerUSDT).checkLiquidation(liquidator, address(alice_collateral_vault), eulerYzPP);
        IEVault(eulerUSDT).liquidate(address(alice_collateral_vault), eulerYzPP, maxRepay, maxYield);
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
        // Alice creates eYzPP collateral vault with USDT target asset
        vm.startPrank(alice);
        alice_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.EULER_V2,
                _asset: eulerYzPP,
                _targetVault: eulerUSDT,
                _liqLTV: twyneLiqLTV,
                _targetAsset: address(0)
            })
        );

        // Alice approves collateral vault and confirms deposit reverts because intermediate vault is empty
        IERC20(eulerYzPP).approve(address(alice_collateral_vault), type(uint).max);
        vm.expectRevert(Errors.E_InsufficientCash.selector);
        alice_collateral_vault.deposit(1);
        vm.stopPrank();

        // calculate how much to deposit into intermediate vault to get 100% utilization
        uint minorDiff = 100; // this amount can also be deposited without increasing C_LP
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
        IERC20(eulerYzPP).approve(address(eeYzPP_intermediate_vault), type(uint256).max);
        eeYzPP_intermediate_vault.deposit(exactIntermediateDeposit, bob);
        vm.stopPrank();

        vm.startPrank(alice);
        // Deposit an amount that would create 100% utilization rate
        alice_collateral_vault.deposit(COLLATERAL_AMOUNT);
        assertEq(IERC20(eulerYzPP).balanceOf(address(eeYzPP_intermediate_vault)), 0, "The intermediate vault is NOT empty");

        // It is possible to deposit this minor diff amount without increasing C_LP
        alice_collateral_vault.deposit(minorDiff);
        // But depositing more beyond this minorDiff amount DOES revert
        vm.expectRevert(Errors.E_InsufficientCash.selector);
        alice_collateral_vault.deposit(1);
        vm.stopPrank();

        // Confirm that if the intermediate vault has 100% utilization, bob cannot withdraw
        vm.startPrank(bob);
        vm.expectRevert(Errors.E_InsufficientCash.selector);
        eeYzPP_intermediate_vault.withdraw(1, bob, bob);
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
        e_firstBorrowFromEulerViaCollateral(eulerYzPP);

        IEVault targetVault = IEVault(alice_collateral_vault.targetVault());
        vm.startPrank(targetVault.governorAdmin());
        address originalFeeReceiver = targetVault.feeReceiver();
        targetVault.setFeeReceiver(bob);
        vm.stopPrank();

        // Assert that feeReceiver changed
        // Also assert that no Twyne fees exist, meaning that there's no impact
        assertNotEq(originalFeeReceiver, targetVault.feeReceiver());
        assertEq(eeYzPP_intermediate_vault.protocolFeeShare(), 0);
        assertEq(eeYzPP_intermediate_vault.interestFee(), 0);
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
        e_firstBorrowFromEulerViaCollateral(eulerYzPP);

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
        (uint maxrepay, ) = targetVault.checkLiquidation(address(this), address(alice_collateral_vault), eulerYzPP);
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
        e_collateralDepositWithBorrow(eulerYzPP);

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
        e_firstBorrowFromEulerViaCollateral(eulerYzPP);

        IEVault targetVault = IEVault(alice_collateral_vault.targetVault());

        // increase the liquidation discount
        vm.startPrank(targetVault.governorAdmin());
        uint16 originalMaxLiquidationDiscount = targetVault.maxLiquidationDiscount();
        targetVault.setMaxLiquidationDiscount(originalMaxLiquidationDiscount * 4 / 3);
        vm.stopPrank();

        // Twyne can optionally reduce the maxTwyneLTV to increase Twyne liquidation incentive
        vm.startPrank(twyneVaultManager.owner());
        uint16 currentMaxLiqLTV = twyneVaultManager.maxTwyneLTVs(eulerYzPP);
        twyneVaultManager.setMaxLiquidationLTV(eulerYzPP, currentMaxLiqLTV - 100);
        vm.stopPrank();

        // decrease the liquidation discount
        vm.startPrank(targetVault.governorAdmin());
        originalMaxLiquidationDiscount = targetVault.maxLiquidationDiscount();
        targetVault.setMaxLiquidationDiscount(originalMaxLiquidationDiscount / 2);
        vm.stopPrank();

        // Twyne can optionally reduce the maxTwyneLTV to increase Twyne liquidation incentive
        vm.startPrank(twyneVaultManager.owner());
        currentMaxLiqLTV = twyneVaultManager.maxTwyneLTVs(eulerYzPP);
        twyneVaultManager.setMaxLiquidationLTV(eulerYzPP, currentMaxLiqLTV + 200);
        vm.stopPrank();
    }

    // Euler changes their Governance.setLiquidationCoolOffTime()
    // When an Euler liquidation is attempted, the vault must be outside of the liquidation cool-off timeframe
    // An increase of the liquidation cool-off time can result in slower liquidations for a vault on Euler
    // Note: the cool-off period is ONLY relevant after an Euler governance change

    function test_e_eulerTargetVaultLiqCooloffChange() external noGasMetering {
        e_firstBorrowFromEulerViaCollateral(eulerYzPP);

        IEVault targetVault = IEVault(alice_collateral_vault.targetVault());
        uint16 originalCooloffTime = targetVault.liquidationCoolOffTime();

        // increase the liquidation cool-off time
        vm.startPrank(targetVault.governorAdmin());
        uint16 newCooloffTime = originalCooloffTime * 20;
        assertGt(newCooloffTime, 0, "Cool-off time will not change if it was zero to start with");
        targetVault.setLiquidationCoolOffTime(newCooloffTime);
        // also lower the external LTV to test the impact of the new cool-off time
        IEVault(eulerUSDT).setLTV(eulerYzPP, 0.5e4, 0.6e4, 0);
        vm.stopPrank();

        // Confirm external liquidation is possible from eulerUSDT perspective
        vm.expectRevert(Errors.E_LiquidationCoolOff.selector);
        (uint maxrepay, ) = IEVault(eulerUSDT).checkLiquidation(address(this), address(alice_collateral_vault), eulerYzPP);

        // Now ensure vault is out of liquidation cool-off period
        vm.warp(block.timestamp + newCooloffTime);

        // Confirm external liquidation is possible from eulerUSDT perspective
        (maxrepay, ) = IEVault(eulerUSDT).checkLiquidation(address(this), address(alice_collateral_vault), eulerYzPP);
        assertGt(maxrepay, 0, "Vault cannot be externally liquidated");
    }

    // Euler changes their Governance.setInterestRateModel()
    // No impact to Twyne and no action required from Twyne

    // Euler changes their Governance.setHookConfig()
    // This impact Twyne/Euler interactions in different ways
    // Manual review is likely required if this happens to check the precise impact to Twyne

    function test_e_eulerTargetVaultHookChange() public {
        e_firstBorrowFromEulerViaCollateral(eulerYzPP);

        IEVault targetVault = IEVault(alice_collateral_vault.targetVault());

        // Set new hook config
        vm.startPrank(targetVault.governorAdmin());
        targetVault.setHookConfig(address(0), OP_MAX_VALUE - 1);
        vm.stopPrank();

        // if no warp forward, we encounter the cool-off error
        vm.expectRevert(Errors.E_LiquidationCoolOff.selector);
        IEVault(eulerUSDT).checkLiquidation(address(this), address(alice_collateral_vault), eulerYzPP);

        vm.startPrank(alice);
        // cannot borrow because of newly set hook
        vm.expectRevert(Errors.E_OperationDisabled.selector);
        alice_collateral_vault.borrow(1, alice);

        // cannot repay because of newly set hook
        IERC20(USDT).approve(address(alice_collateral_vault), type(uint256).max);
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
    // Additionally, the depositUnderlying() function to deposit YzPP and bypass the Euler frontend can revert if the supply cap is reached
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
        IEVC eulerEVC = IEVC(IEVault(eulerUSDT).EVC());

        // Give user some collateral tokens
        uint256 collateralAmount = 100 ether;
        deal(address(IEVault(eulerYzPP).asset()), user, collateralAmount);

        // User deposits collateral to Euler for subAccount1
        vm.startPrank(user);
        IERC20(IEVault(eulerYzPP).asset()).approve(eulerYzPP, collateralAmount);
        IEVault(eulerYzPP).deposit(collateralAmount, subAccount1);
        vm.stopPrank();

        uint eulerYzPPCollateralAmount = IEVault(eulerYzPP).balanceOf(subAccount1);

        // Step 1: Open a borrow position on Euler using subAccount1 through EVC batch
        vm.startPrank(user);

        // Enable controller and collateral for subAccount1
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);
        items[0] = IEVC.BatchItem({
            targetContract: address(eulerEVC),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeCall(IEVC.enableController, (subAccount1, eulerUSDT))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(eulerEVC),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeCall(IEVC.enableCollateral, (subAccount1, eulerYzPP))
        });

        // Borrow USDT against eulerYzPP collateral
        uint256 borrowAmount = 50 * 10**6; // 5000 USDT
        items[2] = IEVC.BatchItem({
            targetContract: eulerUSDT,
            onBehalfOfAccount: subAccount1,
            value: 0,
            data: abi.encodeCall(IEVault(eulerUSDT).borrow, (borrowAmount, user))
        });

        eulerEVC.batch(items);
        vm.stopPrank();

        // Verify the borrow position is created
        assertEq(IEVault(eulerUSDT).debtOf(subAccount1), borrowAmount, "Debt not created correctly");
        assertEq(IEVault(eulerYzPP).balanceOf(subAccount1), eulerYzPPCollateralAmount, "Collateral balance incorrect");
    }

    // Test teleport function with subaccount
    function test_teleportWithSubaccount() public {
        e_creditDeposit(eulerYzPP);
        // Setup: Create a user with collateral and a subaccount
        address user = makeAddr("user");
        address subAccount1 = getSubAccount(user, 1);
        vm.label(subAccount1, "subAccount1");
        IEVC eulerEVC = IEVC(IEVault(eulerUSDT).EVC());
        vm.label(address(eulerEVC), "eulerEVC");

        e_createDebtPositionOnEuler(user, subAccount1);

        // Step 2: Create a collateral vault and teleport the position
        vm.startPrank(user);
        EulerCollateralVault teleporter_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createCollateralVault(VaultType.EULER_V2, eulerYzPP, eulerUSDT, twyneLiqLTV, address(0))
        );
        vm.stopPrank();
        vm.label(address(teleporter_collateral_vault), "teleporter_collateral_vault");
        vm.label(address(teleporter_collateral_vault.intermediateVault()), "intermediateVault");

        // Fetch the eulerUSDT beacon from collateral vault factory
        address currentBeacon = collateralVaultFactory.collateralVaultBeacon(eulerUSDT);
        vm.label(currentBeacon, "currentBeacon");
        address oldImplementation = UpgradeableBeacon(currentBeacon).implementation();
        vm.label(oldImplementation, "implementation");
        require(currentBeacon != address(0), "Beacon not found for eulerUSDT");

        uint collateralAmount = IERC20(eulerYzPP).balanceOf(subAccount1);
        uint borrowAmount = IEVault(eulerUSDT).debtOf(subAccount1);

        // Approve and teleport through batch
        uint snapshot = vm.snapshotState();
        vm.startPrank(user);
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: eulerYzPP,
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
        assertEq(IEVault(eulerUSDT).debtOf(subAccount1), 0, "User debt should be 0 after teleport");
        assertEq(IEVault(eulerYzPP).balanceOf(subAccount1), 0, "User collateral should be 0 after teleport");
        assertEq(IEVault(eulerUSDT).debtOf(address(teleporter_collateral_vault)), borrowAmount, "Vault should have the debt");
        assertGt(teleporter_collateral_vault.totalAssetsDepositedOrReserved(), 0, "Vault should have assets");

        vm.revertToState(snapshot);

        vm.startPrank(user);
        items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: eulerYzPP,
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
        assertEq(IEVault(eulerUSDT).debtOf(subAccount1), 0, "User debt should be 0 after teleport");
        assertEq(IEVault(eulerYzPP).balanceOf(subAccount1), 0, "User collateral should be 0 after teleport");
        assertEq(IEVault(eulerUSDT).debtOf(address(teleporter_collateral_vault)), borrowAmount, "Vault should have the debt");
        assertGt(teleporter_collateral_vault.totalAssetsDepositedOrReserved(), 0, "Vault should have assets");
    }

    // Will fail as there is no Morpho on Plasma
    // function test_e_LeverageOperator() public noGasMetering {
    //     e_creditDeposit(eulerYzPP);
    //     MockSwapper mockSwapper = new MockSwapper();
    //     vm.etch(eulerSwapper, address(mockSwapper).code);

    //     vm.startPrank(bob);
    //     EulerCollateralVault bob_collateral_vault = EulerCollateralVault(
    //         collateralVaultFactory.createCollateralVault({
    //             _vaultType: VaultType.EULER_V2,
    //             _asset: eulerYzPP,
    //             _targetVault: eulerUSDT,
    //             _liqLTV: twyneLiqLTV,
    //             _targetAsset: address(0)
    //         })
    //     );

    //     evc.setAccountOperator(bob, address(leverageOperator), true);
    //     // Approve leverage operator to take user's collateral
    //     IERC20(eulerYzPP).approve(address(leverageOperator), type(uint).max);
    //     IERC20(YzPP).approve(address(leverageOperator), type(uint).max);
    //     vm.stopPrank();

    //     // Create collateral vault for user
    //     vm.startPrank(alice);
    //     EulerCollateralVault alice_collateral_vault = EulerCollateralVault(
    //         collateralVaultFactory.createCollateralVault({
    //             _vaultType: VaultType.EULER_V2,
    //             _asset: eulerYzPP,
    //             _targetVault: eulerUSDT,
    //             _liqLTV: twyneLiqLTV,
    //             _targetAsset: address(0)
    //         })
    //     );

    //     // Approve leverage operator to take user's collateral
    //     IERC20(eulerYzPP).approve(address(leverageOperator), type(uint).max);
    //     IERC20(YzPP).approve(address(leverageOperator), type(uint).max);

    //     {
    //         uint userUnderlyingCollateralAmount = 1 ether; // User provides 1 YzPP
    //         uint userCollateralAmount = 1 ether; // User provides 1 eulerYzPP
    //         uint flashloanAmount = 20000 * 1e6; // Flashloan 20,000 USDT
    //         uint minAmountOutYzPP = 20 ether; // Expect at least 20 YzPP from swap
    //         uint deadline = block.timestamp + 10; // deadline of the swap quote

    //         // Prepare swap data for the swapper
    //         deal(YzPP, eulerSwapper, minAmountOutYzPP + 10);
    //         bytes memory swapData = abi.encodeCall(MockSwapper.swap, (USDT, YzPP, flashloanAmount, minAmountOutYzPP, eulerYzPP));
    //         bytes[] memory multicallData = new bytes[](1);
    //         multicallData[0] = swapData;

    //         vm.expectRevert(TwyneErrors.T_CallerNotBorrower.selector);
    //         leverageOperator.executeLeverage(
    //             address(bob_collateral_vault),
    //             userUnderlyingCollateralAmount,
    //             userCollateralAmount,
    //             flashloanAmount,
    //             minAmountOutYzPP,
    //             deadline,
    //             multicallData
    //         );

    //         vm.expectRevert(EVCErrors.EVC_NotAuthorized.selector);
    //         leverageOperator.executeLeverage(
    //             address(alice_collateral_vault),
    //             userUnderlyingCollateralAmount,
    //             userCollateralAmount,
    //             flashloanAmount,
    //             minAmountOutYzPP,
    //             deadline,
    //             multicallData
    //         );

    //         uint256 snapshot = vm.snapshot();

    //         // Execute leverage through EVC batch with operator setup
    //         IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);

    //         // Item 0: Enable operator
    //         items[0] = IEVC.BatchItem({
    //             targetContract: address(evc),
    //             onBehalfOfAccount: address(0),
    //             value: 0,
    //             data: abi.encodeCall(evc.setAccountOperator, (alice, address(leverageOperator), true))
    //         });

    //         // Item 1: Execute leverage operation
    //         items[1] = IEVC.BatchItem({
    //             targetContract: address(leverageOperator),
    //             onBehalfOfAccount: alice,
    //             value: 0,
    //             data: abi.encodeCall(leverageOperator.executeLeverage, (
    //                 address(alice_collateral_vault),
    //                 userUnderlyingCollateralAmount,
    //                 userCollateralAmount,
    //                 flashloanAmount,
    //                 minAmountOutYzPP,
    //                 deadline,
    //                 multicallData
    //             ))
    //         });

    //         // Item 2: Disable operator
    //         items[2] = IEVC.BatchItem({
    //             targetContract: address(evc),
    //             onBehalfOfAccount: address(0),
    //             value: 0,
    //             data: abi.encodeCall(evc.setAccountOperator, (alice, address(leverageOperator), false))
    //         });

    //         evc.batch(items);

    //         assertGt(alice_collateral_vault.totalAssetsDepositedOrReserved() - alice_collateral_vault.maxRelease(), userCollateralAmount + userUnderlyingCollateralAmount);
    //         assertEq(alice_collateral_vault.maxRepay(), flashloanAmount);

    //         // Verify that LeverageOperator has no remaining token balances
    //         assertEq(IERC20(eulerYzPP).balanceOf(address(leverageOperator)), 0, "LeverageOperator should have 0 eulerYzPP");
    //         assertEq(IERC20(eulerUSDT).balanceOf(address(leverageOperator)), 0, "LeverageOperator should have 0 eulerUSDT");
    //         assertEq(IERC20(YzPP).balanceOf(address(leverageOperator)), 0, "LeverageOperator should have 0 YzPP");
    //         assertEq(IERC20(USDT).balanceOf(address(leverageOperator)), 0, "LeverageOperator should have 0 USDT");

    //         // Restore state so we can test the direct call to executeLeverage
    //         vm.revertTo(snapshot);

    //         evc.setAccountOperator(alice, address(leverageOperator), true);
    //         // Execute leverage through the operator
    //         leverageOperator.executeLeverage(
    //             address(alice_collateral_vault),
    //             userUnderlyingCollateralAmount,
    //             userCollateralAmount,
    //             flashloanAmount,
    //             minAmountOutYzPP,
    //             deadline,
    //             multicallData
    //         );

    //         assertGt(alice_collateral_vault.totalAssetsDepositedOrReserved() - alice_collateral_vault.maxRelease(), userCollateralAmount + userUnderlyingCollateralAmount);
    //         assertEq(alice_collateral_vault.maxRepay(), flashloanAmount);

    //         // Verify that LeverageOperator has no remaining token balances
    //         assertEq(IERC20(eulerYzPP).balanceOf(address(leverageOperator)), 0, "LeverageOperator should have 0 eulerYzPP");
    //         assertEq(IERC20(eulerUSDT).balanceOf(address(leverageOperator)), 0, "LeverageOperator should have 0 eulerUSDT");
    //         assertEq(IERC20(YzPP).balanceOf(address(leverageOperator)), 0, "LeverageOperator should have 0 YzPP");
    //         assertEq(IERC20(USDT).balanceOf(address(leverageOperator)), 0, "LeverageOperator should have 0 USDT");
    //     }

    //     // Test deleverage functionality
    //     vm.warp(block.timestamp + 1 days);

    //     // Update oracle to avoid stale price revert
    //     {
    //         address configuredYzPP_USD_Oracle = oracleRouter.getConfiguredOracle(YzPP, USD);
    //         address chainlinkFeed = ChainlinkOracle(configuredYzPP_USD_Oracle).feed();
    //         MockChainlinkOracle mockChainlink = new MockChainlinkOracle(YzPP, USD, chainlinkFeed, 61 seconds);
    //         vm.etch(configuredYzPP_USD_Oracle, address(mockChainlink).code);

    //         address configuredUSDT_USD_Oracle = oracleRouter.getConfiguredOracle(USDT, USD);
    //         chainlinkFeed = ChainlinkOracle(configuredUSDT_USD_Oracle).feed();
    //         mockChainlink = new MockChainlinkOracle(USDT, USD, chainlinkFeed, 61 seconds);
    //         vm.etch(configuredUSDT_USD_Oracle, address(mockChainlink).code);
    //     }

    //     // Calculate deleverage amounts based on current position
    //     uint borrowerCollateral = alice_collateral_vault.totalAssetsDepositedOrReserved() - alice_collateral_vault.maxRelease();
    //     uint maxDebt = alice_collateral_vault.maxRepay() / 2;
    //     uint withdrawCollateralAmount = borrowerCollateral / 2;
    //     uint flashloanAmount = withdrawCollateralAmount + 1;

    //     deal(USDT, eulerSwapper, maxDebt + 11);

    //     // Prepare deleverage swap data
    //     bytes memory deleverageSwapData = abi.encodeCall(MockSwapper.swap, (YzPP, USDT, flashloanAmount, maxDebt + 1, address(deleverageOperator)));
    //     bytes[] memory deleverageMulticallData = new bytes[](1);
    //     deleverageMulticallData[0] = deleverageSwapData;

    //     IERC20 targetAsset = IERC20(alice_collateral_vault.targetAsset());
    //     uint aliceTargetAssetBal = targetAsset.balanceOf(alice);
    //     IERC20 underlyingCollateralAsset = IERC20(IEVault(alice_collateral_vault.asset()).asset());
    //     uint aliceUnderlyingCollateralBal = underlyingCollateralAsset.balanceOf(alice);

    //     // Test unauthorized deleverage attempts
    //     vm.startPrank(bob);
    //     vm.expectRevert(TwyneErrors.T_CallerNotBorrower.selector);
    //     deleverageOperator.executeDeleverage(
    //         address(alice_collateral_vault),
    //         flashloanAmount,
    //         maxDebt,
    //         withdrawCollateralAmount,
    //         deleverageMulticallData
    //     );
    //     vm.stopPrank();

    //     vm.startPrank(alice);
    //     // Test deleverage without operator permission
    //     vm.expectRevert(EVCErrors.EVC_NotAuthorized.selector);
    //     deleverageOperator.executeDeleverage(
    //         address(alice_collateral_vault),
    //         flashloanAmount,
    //         maxDebt,
    //         withdrawCollateralAmount,
    //         deleverageMulticallData
    //     );

    //     // Enable operator and execute deleverage
    //     evc.setAccountOperator(alice, address(deleverageOperator), true);
    //     deleverageOperator.executeDeleverage(
    //         address(alice_collateral_vault),
    //         flashloanAmount,
    //         maxDebt,
    //         withdrawCollateralAmount,
    //         deleverageMulticallData
    //     );
    //     evc.setAccountOperator(alice, address(deleverageOperator), false);

    //     assertLe(IEVault(eulerUSDT).debtOf(address(alice_collateral_vault)), maxDebt, "Debt not fully repaid");
    //     assertEq(alice_collateral_vault.totalAssetsDepositedOrReserved() - alice_collateral_vault.maxRelease(), borrowerCollateral / 2, "Collateral not fully withdrawn");

    //     assertEq(targetAsset.balanceOf(alice), aliceTargetAssetBal);
    //     assertGt(underlyingCollateralAsset.balanceOf(alice), aliceUnderlyingCollateralBal, "alice collateral balance increases");

    //     // Check deleverageOperator has no remaining balances
    //     assertEq(targetAsset.balanceOf(address(deleverageOperator)), 0, "DeleverageOperator has remaining YzPP");
    //     assertEq(underlyingCollateralAsset.balanceOf(address(deleverageOperator)), 0, "DeleverageOperator has remaining USDT");

    //     vm.stopPrank();
    // }

    // Test that non-collateral vault accounts are blocked by BridgeHookTarget (not CreditRiskManager)
    // The BridgeHookTarget provides the first line of defense by checking receiver is a collateral vault
    function test_e_NonCollateralVaultBorrowBlockedByHook() public noGasMetering {
        // Setup: credit deposit so intermediate vault has liquidity
        e_creditDeposit(eulerYzPP);

        // Alice (not a collateral vault) tries to borrow from intermediate vault
        vm.startPrank(alice);

        // Enable intermediate vault as controller for alice
        evc.enableController(alice, address(eeYzPP_intermediate_vault));

        // Alice tries to borrow with receiver=alice - blocked by BridgeHookTarget (caller must be collateral vault)
        vm.expectRevert(TwyneErrors.CallerNotCollateralVault.selector);
        eeYzPP_intermediate_vault.borrow(1e18, alice);

        alice_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.EULER_V2,
                _asset: eulerYzPP,
                _targetVault: eulerUSDT,
                _liqLTV: twyneLiqLTV,
                _targetAsset: address(0)
            })
        );

        // Even if receiver is collateral vault, alice (non-CV caller) still cannot borrow
        vm.expectRevert(TwyneErrors.CallerNotCollateralVault.selector);
        eeYzPP_intermediate_vault.borrow(1e18, address(alice_collateral_vault));

        vm.stopPrank();

        // Random actor also cannot borrow
        address randomActor = makeAddr("randomActor");
        vm.startPrank(randomActor);
        evc.enableController(randomActor, address(eeYzPP_intermediate_vault));
        vm.expectRevert(TwyneErrors.CallerNotCollateralVault.selector);
        eeYzPP_intermediate_vault.borrow(1e18, address(alice_collateral_vault));
        vm.stopPrank();
    }

    // Test that CreditRiskManager's checkAccountStatus returns success for collateral vaults
    // even when they have debt but no collateral from the intermediate vault's perspective
    // function test_e_CreditRiskManager_CheckAccountStatus_CollateralVault() public noGasMetering {
    //     // Setup: credit deposit so intermediate vault has liquidity
    //     e_creditDeposit(eulerYzPP);

    //     // Create collateral vault
    //     vm.startPrank(alice);
    //     alice_collateral_vault = EulerCollateralVault(
    //         collateralVaultFactory.createCollateralVault({
    //             _vaultType: VaultType.EULER_V2,
    //             _asset: eulerYzPP,
    //             _targetVault: eulerUSDT,
    //             _liqLTV: twyneLiqLTV,
    //             _targetAsset: address(0)
    //         })
    //     );
    //     vm.label(address(alice_collateral_vault), "alice_collateral_vault");
    //     vm.stopPrank();

    //     // Collateral vault borrows from intermediate vault with no collateral
    //     vm.prank(address(alice_collateral_vault));
    //     eeYzPP_intermediate_vault.borrow(1e18, address(alice_collateral_vault));

    //     // Verify the account is underwater from intermediate vault's perspective
    //     (uint collateralValue, uint liabilityValue) = eeYzPP_intermediate_vault.accountLiquidity(address(alice_collateral_vault), false);
    //     assertEq(collateralValue, 0, "Collateral should be 0");
    //     assertGt(liabilityValue, 0, "Liability should be non-zero");

    //     // CreditRiskManager should still allow this because it skips checks for collateral vaults
    //     // The account status check passes (no revert) even though position is underwater
    //     address[] memory collaterals = new address[](1);
    //     collaterals[0] = address(alice_collateral_vault);
    //     bytes4 result = eeYzPP_intermediate_vault.checkAccountStatus(address(alice_collateral_vault), collaterals);
    //     assertEq(result, IEVCVault.checkAccountStatus.selector, "checkAccountStatus should return success selector");

    //     // Verify that checkAccountStatus also runs (and passes) for non-collateral vault accounts
    //     // Since alice has no debt (BridgeHookTarget prevents non-collateral vaults from borrowing),
    //     // the liquidity check passes
    //     bytes4 aliceResult = eeYzPP_intermediate_vault.checkAccountStatus(alice, collaterals);
    //     assertEq(aliceResult, IEVCVault.checkAccountStatus.selector, "checkAccountStatus should pass for alice with no debt");

    //     // Enable controller for alice so she can attempt to borrow
    //     vm.startPrank(alice);
    //     evc.enableController(alice, address(eeYzPP_intermediate_vault));

    //     // Verify alice cannot borrow - hook blocks non-collateral vault callers
    //     vm.expectRevert(TwyneErrors.CallerNotCollateralVault.selector);
    //     eeYzPP_intermediate_vault.borrow(0.1e18, alice);
    //     // Even when receiver is collateral vault, alice (non-CV caller) still cannot borrow
    //     vm.expectRevert(TwyneErrors.CallerNotCollateralVault.selector);
    //     eeYzPP_intermediate_vault.borrow(0.1e18, address(alice_collateral_vault));

    //     // Verify alice cannot pullDebt from collateral vault
    //     vm.expectRevert(TwyneErrors.T_OperationDisabled.selector);
    //     eeYzPP_intermediate_vault.pullDebt(0.1e18, address(alice_collateral_vault));
    // }
}
