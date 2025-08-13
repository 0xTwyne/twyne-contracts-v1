// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {EulerTestBase, console2} from "./EulerTestBase.t.sol";
import "euler-vault-kit/EVault/shared/types/Types.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {EulerCollateralVault} from "src/twyne/EulerCollateralVault.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Permit2ECDSASigner} from "euler-vault-kit/../test/mocks/Permit2ECDSASigner.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";
import {MockSwapper} from "test/mocks/MockSwapper.sol";

contract EulerFrontendTests is EulerTestBase {
    function setUp() public override {
        super.setUp();
    }

    EulerCollateralVault user_collateral_vault;

    // Create debt modal
    function test_e_batchOpenBorrowSim() public noGasMetering {
        e_creditDeposit(eulerWETH);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(collateralVaultFactory),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(collateralVaultFactory.createCollateralVault, (eulerWETH, eulerUSDC, twyneLiqLTV))
        });
        vm.startPrank(alice);
        (IEVC.BatchItemResult[] memory batchItemsResult,,) = evc.batchSimulation(items);
        vm.stopPrank();
        assertTrue(batchItemsResult[0].success, "sim: collateral vault deployed");
        user_collateral_vault = EulerCollateralVault(address(abi.decode(batchItemsResult[0].result, (address))));
        vm.label(address(user_collateral_vault), "alice_collateral_vault");

        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: WETH,
                amount: uint160(COLLATERAL_AMOUNT),
                expiration: type(uint48).max,
                nonce: 0
            }),
            spender: address(user_collateral_vault),
            sigDeadline: type(uint256).max
        });

        // Alice creates batch to start interacting with the protocol
        vm.startPrank(alice);

        // First, approve permit2 to allow permit2 usage in batch
        IERC20(WETH).approve(permit2, type(uint).max);
        Permit2ECDSASigner permit2Signer = new Permit2ECDSASigner(address(permit2));

        items = new IEVC.BatchItem[](4);
        // Create collateral vault
        items[0] = IEVC.BatchItem({
            targetContract: address(collateralVaultFactory),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(collateralVaultFactory.createCollateralVault, (eulerWETH, eulerUSDC, twyneLiqLTV))
        });
        // Perform Permit2 on the collateral vault
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
        // deposit collateral into collateral vault
        items[2] = IEVC.BatchItem({
            targetContract: address(user_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(EulerCollateralVault(user_collateral_vault).depositUnderlying, (COLLATERAL_AMOUNT))
        });
        // Borrow assets from target vault
        items[3] = IEVC.BatchItem({
            targetContract: address(user_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(EulerCollateralVault(user_collateral_vault).borrow, (BORROW_USD_AMOUNT, alice))
        });

        evc.batchSimulation(items);
        evc.batch(items);
        vm.stopPrank();
    }


    // Create debt modal, borrow max with an existing borrow
    // TODO fix this test when increasing frontend precision
    // function test_e_frontend_batchMaxBorrowSim() external noGasMetering {
    //     test_e_batchOpenBorrowSim();

    //     vm.startPrank(alice);

    //     // To determine the maximum that can be borrowed, take the min of the two liquidation limits
    //     // First liquidation limit relies on the external protocol
    //     (uint externalCollateralValueScaledByLiqLTV, ) = IEVault(eulerUSDC).accountLiquidity(address(user_collateral_vault), true);
    //     uint maxBorrowValueExternalLimit = uint(twyneVaultManager.externalLiqBuffers(user_collateral_vault.asset())) * externalCollateralValueScaledByLiqLTV / MAXFACTOR;
    //     console2.log("maxBorrowValueExternalLimit", maxBorrowValueExternalLimit);

    //     // Second liquidation limit is the Twyne limit
    //     uint userCollateralValue = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(
    //         user_collateral_vault.totalAssetsDepositedOrReserved() - user_collateral_vault.maxRelease(), user_collateral_vault.asset(), IEVault(eeWETH_intermediate_vault).unitOfAccount());
    //     uint maxBorrowValueTwyneLimit = user_collateral_vault.twyneLiqLTV() * userCollateralValue / MAXFACTOR;
    //     console2.log("maxBorrowValueTwyneLimit", maxBorrowValueTwyneLimit);

    //     // Third limit is set by borrow LTV of target asset
    //     uint borrowAmountUSD2 = eulerOnChain.getQuote(
    //         user_collateral_vault.totalAssetsDepositedOrReserved() * uint(IEVault(user_collateral_vault.targetVault()).LTVBorrow(eulerWETH)) / MAXFACTOR,
    //         eulerWETH,
    //         USD
    //     );
    //     console2.log("borrowAmountUSD2", borrowAmountUSD2);

    //     maxBorrowValueTwyneLimit = maxBorrowValueTwyneLimit < maxBorrowValueExternalLimit ? maxBorrowValueTwyneLimit : maxBorrowValueExternalLimit;
    //     maxBorrowValueTwyneLimit = maxBorrowValueTwyneLimit < borrowAmountUSD2 ? maxBorrowValueTwyneLimit : borrowAmountUSD2;
    //     uint maxBorrowAmount = maxBorrowValueTwyneLimit / eulerOnChain.getQuote(1, USDC, USD);
    //     console2.log("maxBorrowAmount in USDC", maxBorrowAmount);

    //     IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
    //     // Borrow assets from target vault
    //     items[0] = IEVC.BatchItem({
    //         targetContract: address(user_collateral_vault),
    //         onBehalfOfAccount: alice,
    //         value: 0,
    //         data: abi.encodeCall(EulerCollateralVault(user_collateral_vault).borrow, (maxBorrowAmount - 100, alice))
    //     });

    //     evc.batchSimulation(items);
    //     evc.batch(items);

    //     // vm.expectRevert();
    //     alice_collateral_vault.borrow(1, alice);
    //     vm.stopPrank();
    // }

    // Credit repay modal, partial release
    function test_e_frontend_batchPartialRepayPositionSim() external noGasMetering {
        e_firstBorrowFromEulerDirect(eulerWETH);

        // Move forward in time to observe increase in debts
        uint256 blockIncrement = 1000;
        vm.roll(block.number + blockIncrement);
        vm.warp(block.timestamp + 12);
        deal(USDC, address(alice_collateral_vault), INITIAL_DEALT_ERC20); // minting USDC to alice to account for interest accrual

        // now repay - first Euler debt, then the bridge debt
        vm.startPrank(alice);

        uint maxWithdraw = alice_collateral_vault.totalAssetsDepositedOrReserved() - alice_collateral_vault.maxRelease();

        IERC20(USDC).approve(permit2, type(uint).max);
        Permit2ECDSASigner permit2Signer = new Permit2ECDSASigner(address(permit2));
        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: USDC,
                amount: type(uint160).max,
                expiration: type(uint48).max,
                nonce: 0
            }),
            spender: address(alice_collateral_vault),
            sigDeadline: type(uint256).max
        });

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);

        // Perform Permit2 on the collateral vault
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
        // repay debt to Euler
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.repay, (alice_collateral_vault.maxRepay() - BORROW_USD_AMOUNT/2))
        });
        items[2] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.withdraw, (maxWithdraw - COLLATERAL_AMOUNT/2, alice))
        });

        evc.batchSimulation(items);
        evc.batch(items);
        vm.stopPrank();
    }

    // Credit repay modal, 100% repayment with redeemUnderlying
    function test_e_frontend_closePositionRedeemUnderlying() external noGasMetering {
        e_firstBorrowFromEulerDirect(eulerWETH);

        // Move forward in time to observe increase in debts
        uint256 blockIncrement = 1000;
        vm.roll(block.number + blockIncrement);
        vm.warp(block.timestamp + 600);
        deal(USDC, address(alice_collateral_vault), INITIAL_DEALT_ERC20); // minting USDC to alice to account for interest accrual

        // now repay - first Euler debt, then the bridge debt
        vm.startPrank(alice);
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint256).max);
        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint256).max);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // repay debt to Euler
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.repay, (type(uint256).max))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.withdraw, (type(uint256).max, alice))
        });

        evc.batchSimulation(items);
        evc.batch(items);
        vm.stopPrank();
    }


    // Credit repay modal, 100% repayment
    function test_e_frontend_batchClosePositionSim() external noGasMetering {
        e_firstBorrowFromEulerDirect(eulerWETH);

        // Move forward in time to observe increase in debts
        uint256 blockIncrement = 1000;
        vm.roll(block.number + blockIncrement);
        vm.warp(block.timestamp + 12);
        deal(USDC, address(alice_collateral_vault), INITIAL_DEALT_ERC20); // minting USDC to alice to account for interest accrual

        // now repay - first Euler debt, then the bridge debt
        vm.startPrank(alice);
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint256).max);
        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint256).max);

        // First repay debt
        alice_collateral_vault.repay(type(uint256).max);
        // now withdraw using redeemUnderlying
        alice_collateral_vault.redeemUnderlying(alice_collateral_vault.balanceOf(address(alice_collateral_vault)), alice);
        vm.stopPrank();

        assertEq(alice_collateral_vault.balanceOf(address(alice_collateral_vault)), 0, "Collateral vault is not empty!");
        assertEq(IERC20(eulerWETH).balanceOf(address(alice_collateral_vault)), 0, "Collateral vault is not empty!");
    }

    function test_e_frontend_depositUnderlyingViaTwyneEVC() external noGasMetering {
        // Bob convert WETH from eulerWETH
        vm.startPrank(bob);
        // First, approve permit2 to allow permit2 usage in batch
        IERC20(WETH).approve(permit2, type(uint).max);
        Permit2ECDSASigner permit2Signer = new Permit2ECDSASigner(address(permit2));

        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: WETH,
                amount: uint160(CREDIT_LP_AMOUNT),
                expiration: type(uint48).max,
                nonce: 0
            }),
            spender: address(evc),
            sigDeadline: type(uint256).max
        });

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](4);

        items[0] = IEVC.BatchItem({
            targetContract: permit2,
            onBehalfOfAccount: bob,
            value: 0,
            data: abi.encodeWithSignature(
                "permit(address,((address,uint160,uint48,uint48),address,uint256),bytes)",
                bob,
                permitSingle,
                permit2Signer.signPermitSingle(bobKey, permitSingle)
            )
        });
        items[1] = IEVC.BatchItem({
            targetContract: permit2,
            onBehalfOfAccount: bob,
            value: 0,
            data: abi.encodeWithSignature(
                "transferFrom(address,address,uint160,address)",
                bob,
                address(evc),
                CREDIT_LP_AMOUNT,
                WETH
            )
        });
        items[2] = IEVC.BatchItem({
            targetContract: WETH,
            onBehalfOfAccount: bob,
            value: 0,
            data: abi.encodeCall(IERC20(WETH).approve, (eulerWETH, type(uint).max))
        });
        items[3] = IEVC.BatchItem({
            targetContract: eulerWETH,
            onBehalfOfAccount: bob,
            value: 0,
            data: abi.encodeCall(IEVault(eulerWETH).deposit, (CREDIT_LP_AMOUNT, bob))
        });
        console2.log(IEVault(eulerWETH).balanceOf(bob));
        evc.batch(items);
        vm.stopPrank();

        console2.log(IEVault(eulerWETH).balanceOf(bob));
    }

    function test_e_frontend_depositETHViaTwyneEVC() external noGasMetering {
        // Bob converts ETH to eulerWETH
        vm.startPrank(bob);
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);

        uint bal = bob.balance;
        console2.log(bal);
        items[0] = IEVC.BatchItem({
            targetContract: WETH,
            onBehalfOfAccount: bob,
            value: bal,
            data: abi.encodeWithSignature("deposit()")
        });
        items[1] = IEVC.BatchItem({
            targetContract: WETH,
            onBehalfOfAccount: bob,
            value: 0,
            data: abi.encodeCall(IERC20(WETH).approve, (eulerWETH, type(uint).max))
        });
        items[2] = IEVC.BatchItem({
            targetContract: eulerWETH,
            onBehalfOfAccount: bob,
            value: 0,
            data: abi.encodeCall(IEVault(eulerWETH).deposit, (bal, bob))
        });
        console2.log(IEVault(eulerWETH).balanceOf(bob));
        evc.batch{value: bal}(items);
        vm.stopPrank();

        console2.log(IEVault(eulerWETH).balanceOf(bob));
    }

    // Test 1-click leverage functionality
    function test_e_1clickLeverage() public {
        e_creditDeposit(eulerWETH);
        MockSwapper mockSwapper = new MockSwapper();
        uint eulerWETHBalance = IERC20(eulerWETH).balanceOf(alice);

        // Create collateral vault for user
        vm.startPrank(alice);
        EulerCollateralVault alice_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _asset: eulerWETH,
                _targetVault: eulerUSDC,
                _liqLTV: twyneLiqLTV
            })
        );

        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint).max);

        uint usdcBorrowAmount = 20000 * 1e6;
        uint minAmountOutWETH = 1 ether;
        uint deadline = block.timestamp + 10; // deadline of the swap quote
        // Prepare batch items for 1-click leverage
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](5);

        // Step 1: deposit eulerWETH as collateral
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.deposit, (eulerWETHBalance))
        });

        // Step 2: borrow USDC with Swapper as the receiver
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.borrow, (usdcBorrowAmount, address(mockSwapper)))
        });

        // Step 3: swap USDC for WETH. eulerWETH receives the swapped WETH (frontend needs to send swap quote to Swapper)
        items[2] = IEVC.BatchItem({
            targetContract: address(mockSwapper),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(MockSwapper.swap, (USDC, WETH, usdcBorrowAmount, minAmountOutWETH, eulerWETH))
        });

        // Step 4: skim the received WETH, deposit it in eulerWETH, transfer the receipt token to collateral vault
        items[3] = IEVC.BatchItem({
            targetContract: eulerSwapVerifier,
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeWithSignature("verifyAmountMinAndSkim(address,address,uint256,uint256)", eulerWETH, address(alice_collateral_vault), minAmountOutWETH, deadline)
        });

        // Step 5: skim collateral asset
        items[4] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.skim, ())
        });

        evc.batch(items);

        assertGt(alice_collateral_vault.totalAssetsDepositedOrReserved() - alice_collateral_vault.maxRelease(), eulerWETHBalance);
        assertEq(alice_collateral_vault.maxRepay(), usdcBorrowAmount);
    }
}
