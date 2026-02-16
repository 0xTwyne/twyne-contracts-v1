// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {AaveTestBase, console2} from "./AaveTestBase.t.sol";
import "euler-vault-kit/EVault/shared/types/Types.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {MockChainlinkOracle} from "test/mocks/MockChainlinkOracle.sol";
import {ChainlinkOracle} from "euler-price-oracle/src/adapter/chainlink/ChainlinkOracle.sol";
import {AaveV3CollateralVault} from "src/twyne/AaveV3CollateralVault.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {CollateralVaultFactory, VaultType} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Permit2ECDSASigner} from "euler-vault-kit/../test/mocks/Permit2ECDSASigner.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";
import {MockSwapper} from "test/mocks/MockSwapper.sol";
import {Errors as EVCErrors} from "ethereum-vault-connector/Errors.sol";
import {IPool as IAaveV3Pool} from "aave-v3/interfaces/IPool.sol";
import {IERC20Permit} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC4626StataToken} from "src/interfaces/IAaveV3ATokenWrapper.sol";

contract AaveFrontendTests is AaveTestBase {
    function setUp() public override {
        super.setUp();
    }

    AaveV3CollateralVault user_collateral_vault;

    // Deposit WSTETH (underlying asset) in intermediate vault
    function test_aave_frontend_underlyingCreditDeposit_WithApprove() public noGasMetering {
        IEVault intermediate_vault = IEVault(twyneVaultManager.getIntermediateVault(address(aWSTETHWrapper)));

        // Give alice some WSTETH to deposit
        uint256 depositAmount = 10 ether;
        deal(WSTETH, alice, depositAmount);

        vm.startPrank(alice);
        // Approve wrapper to spend WSTETH
        IERC20(WSTETH).approve(address(aaveWrapper), depositAmount);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);

        items[0] = IEVC.BatchItem({
            targetContract: address(aaveWrapper),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(aaveWrapper.depositUnderlyingToIntermediateVault, (intermediate_vault, depositAmount))
        });

        // Execute the batch
        evc.batch(items);
        vm.stopPrank();

        // Verify the deposits
        assertGt(intermediate_vault.balanceOf(alice), 0, "Alice should have intermediate vault tokens");
    }

    // Deposit WSTETH (underlying asset) in intermediate vault using Permit2
    function test_aave_frontend_underlyingCreditDeposit_WithPermit2() public noGasMetering {
        IEVault intermediate_vault = IEVault(twyneVaultManager.getIntermediateVault(address(aWSTETHWrapper)));

        // Give alice some WSTETH to deposit
        uint256 depositAmount = 10 ether;
        deal(WSTETH, alice, depositAmount);

        vm.startPrank(alice);

        // First approve Permit2 to spend WSTETH
        IERC20(WSTETH).approve(permit2, type(uint256).max);

        // Create Permit2 signature
        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: WSTETH,
                amount: uint160(depositAmount),
                expiration: type(uint48).max,
                nonce: 0
            }),
            spender: address(aaveWrapper),
            sigDeadline: type(uint256).max
        });

        Permit2ECDSASigner permit2Signer = new Permit2ECDSASigner(address(permit2));

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // Item 0: Execute Permit2 to allow aaveWrapper to spend WSTETH
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

        // Item 1: Deposit underlying to intermediate vault
        items[1] = IEVC.BatchItem({
            targetContract: address(aaveWrapper),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(aaveWrapper.depositUnderlyingToIntermediateVault, (intermediate_vault, depositAmount))
        });

        // Execute the batch
        evc.batch(items);
        vm.stopPrank();

        // Verify the deposits
        assertGt(intermediate_vault.balanceOf(alice), 0, "Alice should have intermediate vault tokens");
    }

    // Deposit aWSTETH (aToken) in intermediate vault using approve
    function test_aave_frontend_creditDeposit_AToken_WithApprove() public noGasMetering {
        IEVault intermediate_vault = IEVault(twyneVaultManager.getIntermediateVault(address(aWSTETHWrapper)));
        address aWSTETH = aWSTETHWrapper.aToken();

        // First give alice some WSTETH and deposit to Aave to get aWSTETH
        uint256 underlyingAmount = 10 ether;
        deal(WSTETH, alice, underlyingAmount);

        vm.startPrank(alice);
        IERC20(WSTETH).approve(aavePool, underlyingAmount);
        IAaveV3Pool(aavePool).deposit(WSTETH, underlyingAmount, alice, 0);

        uint256 aTokenBalance = IERC20(aWSTETH).balanceOf(alice);
        assertGt(aTokenBalance, 0, "Alice should have aWSTETH tokens");

        // Now test depositing aTokens to intermediate vault
        // Approve wrapper to spend aWSTETH
        IERC20(aWSTETH).approve(address(aWSTETHWrapper), aTokenBalance);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        items[0] = IEVC.BatchItem({
            targetContract: address(aWSTETHWrapper),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(aWSTETHWrapper.depositATokens, (aTokenBalance, address(intermediate_vault)))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(intermediate_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(intermediate_vault.skim, (type(uint).max, alice))
        });

        // Execute the batch
        evc.batch(items);
        vm.stopPrank();

        // Verify the deposits
        assertGt(intermediate_vault.balanceOf(alice), 0, "Alice should have intermediate vault tokens");
    }

    // Deposit aWSTETH (aToken) in intermediate vault using aToken permit
    function test_aave_frontend_creditDeposit_AToken_WithPermit() public noGasMetering {
        IEVault intermediate_vault = IEVault(twyneVaultManager.getIntermediateVault(address(aWSTETHWrapper)));
        address aWSTETH = aWSTETHWrapper.aToken();

        // First give alice some WSTETH and deposit to Aave to get aWSTETH
        uint256 underlyingAmount = 10 ether;
        deal(WSTETH, alice, underlyingAmount);

        vm.startPrank(alice);
        IERC20(WSTETH).approve(aavePool, underlyingAmount);
        IAaveV3Pool(aavePool).deposit(WSTETH, underlyingAmount, alice, 0);

        uint256 aTokenBalance = IERC20(aWSTETH).balanceOf(alice);
        assertGt(aTokenBalance, 0, "Alice should have aWSTETH tokens");

        // Create aToken permit signature for the wrapper to spend aWSTETH
        uint256 deadline = block.timestamp + 1 hours;

        // Create permit signature for aToken
        bytes32 permitHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                IERC20Permit(aWSTETH).DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        alice,
                        address(aWSTETHWrapper),
                        aTokenBalance,
                        IERC20Permit(aWSTETH).nonces(alice),
                        deadline
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, permitHash);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // Create signature params struct
        IERC4626StataToken.SignatureParams memory sig = IERC4626StataToken.SignatureParams({
            v: v,
            r: r,
            s: s
        });

        // Item 0: Deposit aTokens using permit signature, sending shares to intermediate vault
        items[0] = IEVC.BatchItem({
            targetContract: address(aWSTETHWrapper),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(aWSTETHWrapper.depositWithPermit, (aTokenBalance, address(intermediate_vault), deadline, sig, false))
        });

        // Item 1: Skim wrapper shares from intermediate vault to alice
        items[1] = IEVC.BatchItem({
            targetContract: address(intermediate_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(intermediate_vault.skim, (type(uint).max, alice))
        });

        // Execute the batch
        evc.batch(items);
        vm.stopPrank();

        // Verify the deposits
        assertGt(intermediate_vault.balanceOf(alice), 0, "Alice should have intermediate vault tokens");
    }

    // Create debt modal
    function test_aave_frontend_batchOpenBorrowSim() public noGasMetering {
        address collateralAsset = address(aWETHWrapper);
        aave_creditDeposit(collateralAsset);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(collateralVaultFactory),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(collateralVaultFactory.createCollateralVault, (VaultType.AAVE_V3, collateralAsset, aavePool, twyneLiqLTV, USDC))
        });
        vm.startPrank(alice);
        (IEVC.BatchItemResult[] memory batchItemsResult,,) = evc.batchSimulation(items);
        vm.stopPrank();
        assertTrue(batchItemsResult[0].success, "sim: collateral vault deployed");
        user_collateral_vault = AaveV3CollateralVault(address(abi.decode(batchItemsResult[0].result, (address))));
        vm.label(address(user_collateral_vault), "alice_aave_vault");

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
            data: abi.encodeCall(collateralVaultFactory.createCollateralVault, (VaultType.AAVE_V3, collateralAsset, aavePool, twyneLiqLTV, USDC))
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
            data: abi.encodeCall(AaveV3CollateralVault(user_collateral_vault).depositUnderlying, (COLLATERAL_AMOUNT))
        });
        // Borrow assets from target vault
        items[3] = IEVC.BatchItem({
            targetContract: address(user_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(AaveV3CollateralVault(user_collateral_vault).borrow, (BORROW_USD_AMOUNT, alice))
        });

        evc.batchSimulation(items);
        evc.batch(items);
        vm.stopPrank();
    }

    // Create debt modal using aToken as collateral
    function test_aave_frontend_batchOpenBorrowSim_WithAToken() public noGasMetering {
        address collateralAsset = address(aWETHWrapper);
        address aWETH = aWETHWrapper.aToken();
        aave_creditDeposit(collateralAsset);

        // First give alice some WETH and deposit to Aave to get aWETH
        uint256 collateralAmount = COLLATERAL_AMOUNT;
        deal(WETH, alice, collateralAmount);

        vm.startPrank(alice);
        IERC20(WETH).approve(aavePool, collateralAmount);
        IAaveV3Pool(aavePool).deposit(WETH, collateralAmount, alice, 0);

        uint256 aTokenBalance = IERC20(aWETH).balanceOf(alice);
        assertGt(aTokenBalance, 0, "Alice should have aWETH tokens");
        vm.stopPrank();

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(collateralVaultFactory),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(collateralVaultFactory.createCollateralVault, (VaultType.AAVE_V3, collateralAsset, aavePool, twyneLiqLTV, USDC))
        });
        vm.startPrank(alice);
        (IEVC.BatchItemResult[] memory batchItemsResult,,) = evc.batchSimulation(items);
        vm.stopPrank();
        assertTrue(batchItemsResult[0].success, "sim: collateral vault deployed");
        user_collateral_vault = AaveV3CollateralVault(address(abi.decode(batchItemsResult[0].result, (address))));
        vm.label(address(user_collateral_vault), "alice_aave_vault");

        // Alice creates batch to start interacting with the protocol
        vm.startPrank(alice);

        // Approve wrapper to spend aTokens (normal approval, not Permit2)
        IERC20(aWETH).approve(address(aWETHWrapper), aTokenBalance);

        items = new IEVC.BatchItem[](4);
        // Create collateral vault
        items[0] = IEVC.BatchItem({
            targetContract: address(collateralVaultFactory),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(collateralVaultFactory.createCollateralVault, (VaultType.AAVE_V3, collateralAsset, aavePool, twyneLiqLTV, USDC))
        });
        // deposit aTokens into wrapper (which deposits to collateral vault)
        items[1] = IEVC.BatchItem({
            targetContract: address(aWETHWrapper),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(aWETHWrapper.depositATokens, (aTokenBalance, address(user_collateral_vault)))
        });
        // skim wrapper shares into collateral vault for alice
        items[2] = IEVC.BatchItem({
            targetContract: address(user_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(AaveV3CollateralVault(user_collateral_vault).skim, ())
        });
        // Borrow assets from target vault
        items[3] = IEVC.BatchItem({
            targetContract: address(user_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(AaveV3CollateralVault(user_collateral_vault).borrow, (BORROW_USD_AMOUNT, alice))
        });

        evc.batchSimulation(items);
        evc.batch(items);
        vm.stopPrank();
    }

    // Credit repay modal, partial withdraw of atoken collateral (like aWSTETH)
    function test_aave_frontend_batchPartialRepayPositionAndWithdrawATokenSim() external noGasMetering {
        address collateralAsset = address(aWETHWrapper);

        aave_firstBorrowDirect(collateralAsset);

        // Move forward in time to observe increase in debts
        uint256 blockIncrement = 1000;
        vm.roll(block.number + blockIncrement);
        vm.warp(block.timestamp + 12);
        deal(USDC, address(alice_aave_vault), INITIAL_DEALT_ERC20); // minting USDC to alice to account for interest accrual

        // now repay - first Euler debt, then the bridge debt
        vm.startPrank(alice);

        uint maxWithdraw = alice_aave_vault.totalAssetsDepositedOrReserved() - alice_aave_vault.maxRelease();

        IERC20(USDC).approve(permit2, type(uint).max);
        Permit2ECDSASigner permit2Signer = new Permit2ECDSASigner(address(permit2));
        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: USDC,
                amount: type(uint160).max,
                expiration: type(uint48).max,
                nonce: 0
            }),
            spender: address(alice_aave_vault),
            sigDeadline: type(uint256).max
        });

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](4);

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
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.repay, (alice_aave_vault.maxRepay() - BORROW_USD_AMOUNT/2))
        });
        items[2] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.withdraw, (maxWithdraw - COLLATERAL_AMOUNT/2, alice))
        });
        // Add item to redeem aTokens for the withdrawn amount
        items[3] = IEVC.BatchItem({
            targetContract: address(aWETHWrapper),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(aWETHWrapper.redeemATokens, (maxWithdraw - COLLATERAL_AMOUNT/2, alice, alice))
        });

        evc.batchSimulation(items);
        evc.batch(items);
        vm.stopPrank();
    }

    // Credit repay modal, 100% repayment with redeemUnderlying
    function test_aave_frontend_closePositionRedeemUnderlying() external noGasMetering {
        address collateralAsset = address(aWETHWrapper);

        aave_firstBorrowDirect(collateralAsset);

        // Move forward in time to observe increase in debts
        uint256 blockIncrement = 1000;
        vm.roll(block.number + blockIncrement);
        vm.warp(block.timestamp + 600);
        deal(USDC, address(alice_aave_vault), INITIAL_DEALT_ERC20); // minting USDC to alice to account for interest accrual

        // now repay - first Euler debt, then the bridge debt
        vm.startPrank(alice);
        IERC20(USDC).approve(address(alice_aave_vault), type(uint256).max);
        IERC20(collateralAsset).approve(address(alice_aave_vault), type(uint256).max);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // repay debt to Euler
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.repay, (type(uint256).max))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.redeemUnderlying, (type(uint256).max, alice))
        });

        evc.batchSimulation(items);
        evc.batch(items);
        vm.stopPrank();
    }


    // Credit repay modal, 100% repayment
    function test_aave_frontend_batchClosePositionSim() external noGasMetering {
        address collateralAsset = address(aWETHWrapper);

        aave_firstBorrowDirect(collateralAsset);

        // Move forward in time to observe increase in debts
        uint256 blockIncrement = 1000;
        vm.roll(block.number + blockIncrement);
        vm.warp(block.timestamp + 12);
        deal(USDC, address(alice_aave_vault), INITIAL_DEALT_ERC20); // minting USDC to alice to account for interest accrual

        // now repay - first Euler debt, then the bridge debt
        vm.startPrank(alice);
        IERC20(USDC).approve(address(alice_aave_vault), type(uint256).max);
        IERC20(collateralAsset).approve(address(alice_aave_vault), type(uint256).max);

        // First repay debt
        alice_aave_vault.repay(type(uint256).max);
        // now withdraw using redeemUnderlying
        alice_aave_vault.redeemUnderlying(alice_aave_vault.balanceOf(address(alice_aave_vault)), alice);
        vm.stopPrank();

        assertEq(alice_aave_vault.balanceOf(address(alice_aave_vault)), 0, "Collateral vault is not empty!");
        assertEq(IERC20(collateralAsset).balanceOf(address(alice_aave_vault)), 0, "Collateral vault is not empty!");
    }

    function test_aave_frontend_ETH_to_aWETH_ViaTwyneEVC() external noGasMetering {
        // Bob converts ETH to aWETH
        vm.startPrank(bob);
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);

        uint bal = bob.balance;
        address aWETH = aWETHWrapper.aToken();
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
            data: abi.encodeCall(IERC20(WETH).approve, (aavePool, type(uint).max))
        });
        items[2] = IEVC.BatchItem({
            targetContract: aavePool,
            onBehalfOfAccount: bob,
            value: 0,
            data: abi.encodeCall(IAaveV3Pool(aavePool).deposit, (WETH, bal, bob, 0))
        });

        console2.log(IERC20(aWETH).balanceOf(bob));
        evc.batch{value: bal}(items);
        vm.stopPrank();

        console2.log(IERC20(aWETH).balanceOf(bob));
    }

    function test_aave_frontend_depositETH_to_CollateralVault() external noGasMetering {
        aave_creditDeposit(address(aWETHWrapper));
        // Create collateral vault for bob
        vm.startPrank(bob);
        AaveV3CollateralVault collateral_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _asset: address(aWETHWrapper),
                _targetVault: aavePool,
                _liqLTV: twyneLiqLTV,
                _targetAsset: USDC
            })
        );

        uint bal = bob.balance;
        console2.log("Bob ETH balance before:", bal);

        // Use ETH operator to deposit ETH directly to collateral vault
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](4);
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
            data: abi.encodeCall(IERC20.transfer, (address(aWETHWrapper), bal))
        });
        items[2] = IEVC.BatchItem({
            targetContract: address(aWETHWrapper),
            onBehalfOfAccount: bob,
            value: 0,
            data: abi.encodeCall(aWETHWrapper.skim, (address(collateral_vault)))
        });
        items[3] = IEVC.BatchItem({
            targetContract: address(collateral_vault),
            onBehalfOfAccount: bob,
            value: 0,
            data: abi.encodeCall(collateral_vault.skim, ())
        });

        evc.batch{value: bal}(items);
        vm.stopPrank();

        // Verify results
        console2.log("Bob ETH balance after:", bob.balance);
        console2.log("Wrapper shares in collateral vault:", IERC20(address(aWETHWrapper)).balanceOf(address(collateral_vault)));
        assertGt(IERC20(address(aWETHWrapper)).balanceOf(address(collateral_vault)), 0, "Collateral vault should receive wrapper shares");
    }

    // Withdraw aTokens from intermediate vault
    function test_aave_frontend_withdrawATokenFromIntermediateVault() external noGasMetering {
        IEVault intermediate_vault = IEVault(twyneVaultManager.getIntermediateVault(address(aWSTETHWrapper)));
        address aWSTETH = aWSTETHWrapper.aToken();

        // Give alice some WSTETH to deposit
        uint256 depositAmount = 10 ether;
        deal(WSTETH, alice, depositAmount);

        vm.startPrank(alice);

        // First deposit underlying to intermediate vault
        IERC20(WSTETH).approve(address(aaveWrapper), depositAmount);
        aaveWrapper.depositUnderlyingToIntermediateVault(intermediate_vault, depositAmount);

        uint256 intermediateVaultShares = intermediate_vault.balanceOf(alice);
        assertGt(intermediateVaultShares, 0, "Alice should have intermediate vault shares");

        uint256 aliceATokenBalanceBefore = IERC20(aWSTETH).balanceOf(alice);

        // Withdraw 1 ether of atokens - convert to wrapper shares
        uint256 aTokenAmount = 1 ether;
        uint256 wrapperShares = aWSTETHWrapper.convertToShares(aTokenAmount);

        // Withdraw from intermediate vault and redeem as aTokens
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        items[0] = IEVC.BatchItem({
            targetContract: address(intermediate_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(intermediate_vault.withdraw, (wrapperShares, alice, alice))
        });

        items[1] = IEVC.BatchItem({
            targetContract: address(aWSTETHWrapper),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(aWSTETHWrapper.redeemATokens, (wrapperShares, alice, alice))
        });

        evc.batch(items);
        vm.stopPrank();

        // Verify alice received aTokens
        uint256 aliceATokenBalanceAfter = IERC20(aWSTETH).balanceOf(alice);
        assertGt(aliceATokenBalanceAfter, aliceATokenBalanceBefore, "Alice should have received aTokens");
        assertGt(intermediate_vault.balanceOf(alice), 0, "Alice should still have intermediate vault shares");

        console2.log("Alice aToken balance before:", aliceATokenBalanceBefore);
        console2.log("Alice aToken balance after:", aliceATokenBalanceAfter);
    }

    // Withdraw aTokens from collateral vault
    function test_aave_frontend_withdrawATokenFromCollateralVault() external noGasMetering {
        address collateralAsset = address(aWETHWrapper);
        address aWETH = aWETHWrapper.aToken();

        // Setup: deposit to credit and create collateral vault with collateral
        aave_creditDeposit(collateralAsset);

        vm.startPrank(alice);

        // Create collateral vault
        AaveV3CollateralVault collateral_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _asset: collateralAsset,
                _targetVault: aavePool,
                _liqLTV: twyneLiqLTV,
                _targetAsset: USDC
            })
        );

        // Deposit underlying to collateral vault
        uint256 depositAmount = 10 ether;
        deal(WETH, alice, depositAmount);
        IERC20(WETH).approve(address(collateral_vault), depositAmount);
        collateral_vault.depositUnderlying(depositAmount);

        uint256 aliceATokenBalanceBefore = IERC20(aWETH).balanceOf(alice);

        // Withdraw 1 ether of atokens - convert to wrapper shares
        uint256 aTokenAmount = 1 ether;
        uint256 wrapperShares = aWETHWrapper.convertToShares(aTokenAmount);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        items[0] = IEVC.BatchItem({
            targetContract: address(collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(collateral_vault.withdraw, (wrapperShares, alice))
        });

        items[1] = IEVC.BatchItem({
            targetContract: address(aWETHWrapper),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(aWETHWrapper.redeemATokens, (wrapperShares, alice, alice))
        });

        evc.batch(items);
        vm.stopPrank();

        // Verify alice received aTokens
        uint256 aliceATokenBalanceAfter = IERC20(aWETH).balanceOf(alice);
        assertGt(aliceATokenBalanceAfter, aliceATokenBalanceBefore, "Alice should have received aTokens");
        assertGt(collateral_vault.totalAssetsDepositedOrReserved(), 0, "Collateral vault should still have assets");

        console2.log("Alice aToken balance before:", aliceATokenBalanceBefore);
        console2.log("Alice aToken balance after:", aliceATokenBalanceAfter);
    }
}
