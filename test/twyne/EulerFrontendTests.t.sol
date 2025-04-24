// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.28;

import {EulerTestNormalActions, console2} from "./EulerTestNormalActions.t.sol";
import "euler-vault-kit/EVault/shared/types/Types.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {EulerCollateralVault} from "src/twyne/EulerCollateralVault.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Permit2ECDSASigner} from "euler-vault-kit/../test/mocks/Permit2ECDSASigner.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";

contract EulerFrontendTests is EulerTestNormalActions {
    function setUp() public override {
        super.setUp();
    }

    EulerCollateralVault user_collateral_vault;

    // Create debt modal
    function test_e_batchOpenBorrowSim() public noGasMetering {
        test_e_creditDeposit();

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
    function test_e_frontend_batchMaxBorrowSim() external noGasMetering {
        test_e_batchOpenBorrowSim();

        vm.startPrank(alice);

        // To determine the maximum that can be borrowed, take the min of the two liquidation limits
        // First liquidation limit relies on the external protocol
        (uint externalCollateralValueScaledByLiqLTV, ) = IEVault(eulerUSDC).accountLiquidity(address(user_collateral_vault), true);
        uint maxBorrowValueExternalLimit = uint(twyneVaultManager.externalLiqBuffers(user_collateral_vault.asset())) * externalCollateralValueScaledByLiqLTV / MAXFACTOR;

        // Second liquidation limit is the Twyne limit
        uint userCollateralValue = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(
            user_collateral_vault.totalAssetsDepositedOrReserved() - user_collateral_vault.maxRelease(), user_collateral_vault.asset(), IEVault(eeWETH_intermediate_vault).unitOfAccount());
        uint maxBorrowValueTwyneLimit = user_collateral_vault.twyneLiqLTV() * userCollateralValue / MAXFACTOR;
        console2.log("maxBorrowValueTwyneLimit", maxBorrowValueTwyneLimit);

        maxBorrowValueTwyneLimit = maxBorrowValueTwyneLimit < maxBorrowValueExternalLimit ? maxBorrowValueTwyneLimit : maxBorrowValueExternalLimit;
        uint USDCPrice = eulerOnChain.getQuote(1, USDC, USD); // returns a value times 1e10
        uint maxBorrowAmount = maxBorrowValueTwyneLimit / USDCPrice;

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        // Borrow assets from target vault
        items[0] = IEVC.BatchItem({
            targetContract: address(user_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(EulerCollateralVault(user_collateral_vault).borrow, (maxBorrowAmount - user_collateral_vault.maxRepay(), alice))
        });

        evc.batchSimulation(items);
        evc.batch(items);

        vm.expectRevert(TwyneErrors.VaultStatusLiquidatable.selector);
        user_collateral_vault.borrow(1, alice);
        vm.stopPrank();
    }

    // Credit repay modal, partial release
    function test_e_frontend_batchPartialRepayPositionSim() external noGasMetering {
        test_e_firstBorrowFromEulerDirect();

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

    // Credit repay modal, 100% repayment
    function test_e_frontend_batchClosePositionSim() external noGasMetering {
        test_e_firstBorrowFromEulerDirect();

        // Move forward in time to observe increase in debts
        uint256 blockIncrement = 1000;
        vm.roll(block.number + blockIncrement);
        vm.warp(block.timestamp + 12);
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

}
