// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {AaveTestBase, console2} from "./AaveTestBase.t.sol";
import "euler-vault-kit/EVault/shared/types/Types.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {MockChainlinkOracle} from "test/mocks/MockChainlinkOracle.sol";
import {ChainlinkOracle} from "euler-price-oracle/src/adapter/chainlink/ChainlinkOracle.sol";
import {AaveV3CollateralVault} from "src/twyne/AaveV3CollateralVault.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Permit2ECDSASigner} from "euler-vault-kit/../test/mocks/Permit2ECDSASigner.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";
import {MockSwapper} from "test/mocks/MockSwapper.sol";
import {Errors as EVCErrors} from "ethereum-vault-connector/Errors.sol";
import {IPool as IAaveV3Pool} from "aave-v3/interfaces/IPool.sol";
import {IERC20Permit} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC4626StataToken, IAaveV3ATokenWrapper} from "src/interfaces/IAaveV3ATokenWrapper.sol";
import {AssetZapFrontendHelper, IWstETH, IPendleMarket, IPendleRouter, PendleTokenInput, PendleSwapData} from "../AssetZapFrontendHelper.sol";
import {WstethHandler} from "src/operators/handlers/WstethHandler.sol";
import {AssetZap} from "src/Periphery/AssetZap.sol";
import {IVault, IERC4626} from "euler-vault-kit/EVault/IEVault.sol";

contract AaveFrontendTests is AaveTestBase {
    function setUp() public override {
        super.setUp();
    }

    AaveV3CollateralVault user_collateral_vault;

    // Deposit WSTETH (underlying asset) in intermediate vault
    function test_aave_frontend_underlyingCreditDeposit_WithApprove() public noGasMetering {
        IEVault intermediate_vault = IEVault(intermediateVaultFor[address(aWSTETHWrapper)]);

        // Give alice some WSTETH to deposit
        uint256 depositAmount = 10 ether;
        deal(WSTETH, alice, depositAmount);

        vm.startPrank(alice);
        // Approve wrapper to spend WSTETH
        IERC20(WSTETH).approve(address(assetZap), depositAmount);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        items[0] = IEVC.BatchItem({
            targetContract: address(assetZap),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(AssetZap.zapUnderlying, (WSTETH, depositAmount, address(intermediate_vault), 0))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(intermediate_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(IVault.skim, (type(uint256).max, alice))
        });

        // Execute the batch
        evc.batch(items);
        vm.stopPrank();

        // Verify the deposits
        assertGt(intermediate_vault.balanceOf(alice), 0, "Alice should have intermediate vault tokens");
    }

    // Deposit WSTETH (underlying asset) in intermediate vault using Permit2
    function test_aave_frontend_underlyingCreditDeposit_WithPermit2() public noGasMetering {
        IEVault intermediate_vault = IEVault(intermediateVaultFor[address(aWSTETHWrapper)]);

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
            spender: address(assetZap),
            sigDeadline: type(uint256).max
        });

        Permit2ECDSASigner permit2Signer = new Permit2ECDSASigner(address(permit2));

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);

        // Item 0: Execute Permit2 to allow assetZap to spend WSTETH
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

        // Item 1: zap: deposit underlying into the IV's wrapper, minting wrapper shares to the IV
        items[1] = IEVC.BatchItem({
            targetContract: address(assetZap),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(AssetZap.zapUnderlying, (WSTETH, depositAmount, address(intermediate_vault), 0))
        });

        // Item 2: skim: the IV deposits its wrapper shares and mints IV shares to alice
        items[2] = IEVC.BatchItem({
            targetContract: address(intermediate_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(IVault.skim, (type(uint256).max, alice))
        });

        // Execute the batch
        evc.batch(items);
        vm.stopPrank();

        // Verify the deposits
        assertGt(intermediate_vault.balanceOf(alice), 0, "Alice should have intermediate vault tokens");
    }

    // Deposit aWSTETH (aToken) in intermediate vault using approve
    function test_aave_frontend_creditDeposit_AToken_WithApprove() public noGasMetering {
        IEVault intermediate_vault = IEVault(intermediateVaultFor[address(aWSTETHWrapper)]);
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
        IEVault intermediate_vault = IEVault(intermediateVaultFor[address(aWSTETHWrapper)]);
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
            data: abi.encodeCall(collateralVaultFactory.createAaveV3CollateralVault, (intermediateVaultFor[collateralAsset], aavePool, twyneLiqLTV, USDC))
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
        // Wrap WETH -> aWETHWrapper and approve the collateral vault for the deposit
        IERC20(WETH).approve(address(aWETHWrapper), COLLATERAL_AMOUNT);
        uint256 shares = aWETHWrapper.deposit(COLLATERAL_AMOUNT, alice);
        aWETHWrapper.approve(address(user_collateral_vault), shares);

        items = new IEVC.BatchItem[](4);
        // Create collateral vault
        items[0] = IEVC.BatchItem({
            targetContract: address(collateralVaultFactory),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(collateralVaultFactory.createAaveV3CollateralVault, (intermediateVaultFor[collateralAsset], aavePool, twyneLiqLTV, USDC))
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
            data: abi.encodeCall(AaveV3CollateralVault(user_collateral_vault).deposit, (shares))
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
            data: abi.encodeCall(collateralVaultFactory.createAaveV3CollateralVault, (intermediateVaultFor[collateralAsset], aavePool, twyneLiqLTV, USDC))
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
            data: abi.encodeCall(collateralVaultFactory.createAaveV3CollateralVault, (intermediateVaultFor[collateralAsset], aavePool, twyneLiqLTV, USDC))
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
            collateralVaultFactory.createAaveV3CollateralVault({
                _intermediateVault: intermediateVaultFor[address(aWETHWrapper)],
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
        IEVault intermediate_vault = IEVault(intermediateVaultFor[address(aWSTETHWrapper)]);
        address aWSTETH = aWSTETHWrapper.aToken();

        // Give alice some WSTETH to deposit
        uint256 depositAmount = 10 ether;
        deal(WSTETH, alice, depositAmount);

        vm.startPrank(alice);

        // First deposit underlying to intermediate vault
        IERC20(WSTETH).approve(address(assetZap), depositAmount);
        assetZap.zapUnderlying(WSTETH, depositAmount, address(intermediate_vault), 0);
        intermediate_vault.skim(type(uint).max, alice);

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
            collateralVaultFactory.createAaveV3CollateralVault({
                _intermediateVault: intermediateVaultFor[collateralAsset],
                _targetVault: aavePool,
                _liqLTV: twyneLiqLTV,
                _targetAsset: USDC
            })
        );

        // Deposit to collateral vault (wrap WETH -> aWETHWrapper first)
        uint256 depositAmount = 10 ether;
        deal(WETH, alice, depositAmount);
        IERC20(WETH).approve(address(aWETHWrapper), depositAmount);
        uint256 shares = aWETHWrapper.deposit(depositAmount, alice);
        aWETHWrapper.approve(address(collateral_vault), shares);
        collateral_vault.deposit(shares);

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

    // ---------------------------------------------------------------------------------------------
    // AssetZap reference flows (frontend: zap any asset into an intermediate vault in one tx).
    // Each flow deposits credit (LP side) — borrow flows are shown in the tests above.
    // ---------------------------------------------------------------------------------------------

    /// @notice ETH -> WETH asset-zap into the aWETH intermediate vault.
    /// @dev Item 0 wraps ETH 1:1 to WETH via the handler and airdrops it on AssetZap; item 1 zaps in
    ///      airdrop mode (amountIn == 0) with no swap since WETH is the IV underlying.
    function test_aave_frontend_assetZap_ETH_to_WETH() public noGasMetering {
        IEVault intermediateVault = IEVault(intermediateVaultFor[address(aWETHWrapper)]);
        WstethHandler handler = new WstethHandler(WETH, WSTETH);

        uint256 amountIn = 1 ether;
        vm.deal(alice, amountIn);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);
        items[0] = IEVC.BatchItem({
            targetContract: address(handler),
            onBehalfOfAccount: alice,
            value: amountIn,
            data: abi.encodeCall(WstethHandler.wrapETH, (address(assetZap), WETH))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(assetZap),
            onBehalfOfAccount: alice,
            value: 0,
            // WETH is airdropped; the Swapper sweeps it to the IV's wrapper and skims it into wrapper shares before the deposit.
            data: abi.encodeCall(AssetZap.zapUnderlying, (WETH, 0, address(intermediateVault), 1))
        });
        items[2] = IEVC.BatchItem({
            targetContract: address(intermediateVault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(IVault.skim, (type(uint256).max, alice))
        });

        vm.prank(alice);
        evc.batch{value: amountIn}(items);

        uint256 shares = intermediateVault.balanceOf(alice);
        assertGt(shares, 0, "alice credited IV shares");
        assertEq(IERC20(WETH).balanceOf(address(assetZap)), 0, "no WETH residue");
        assertEq(address(assetZap).balance, 0, "no ETH residue");
    }

    /// @notice ETH -> wstETH asset-zap into the aWSTETH intermediate vault.
    /// @dev Item 0 wraps ETH to WETH (handler); item 1 zaps WETH with a Generic-handler swap routing
    ///      WETH -> wstETH via the EVK Swapper before the deposit.
    function test_aave_frontend_assetZap_ETH_to_WSTETH() public noGasMetering {
        IEVault intermediateVault = IEVault(intermediateVaultFor[address(aWSTETHWrapper)]);
        WstethHandler handler = new WstethHandler(WETH, WSTETH);

        uint256 amountIn = 1 ether;
        vm.deal(alice, amountIn);
        uint256 expectedWstEth = IWstETH(WSTETH).getWstETHByStETH(amountIn);

        // Route: WstethHandler delivers wstETH directly to the wrapper (step 1), then a Generic-handler
        // skim absorbs it into wrapper shares at AssetZap (step 2).
        address wrapper = intermediateVault.asset();
        bytes[] memory step1 = AssetZapFrontendHelper.genericSwap(
            WETH, WSTETH, address(handler), abi.encodeCall(WstethHandler.wrapWETH, (amountIn, wrapper))
        );
        bytes[] memory step2 = AssetZapFrontendHelper.genericSwap(
            WSTETH, wrapper, wrapper, abi.encodeCall(IAaveV3ATokenWrapper.skim, (address(assetZap)))
        );
        bytes[] memory swapData = new bytes[](2);
        swapData[0] = step1[0];
        swapData[1] = step2[0];
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);
        items[0] = IEVC.BatchItem({
            targetContract: address(handler),
            onBehalfOfAccount: alice,
            value: amountIn,
            data: abi.encodeCall(WstethHandler.wrapETH, (address(assetZap), WETH))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(assetZap),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(
                AssetZap.zap,
                (WETH, 0, swapData, address(intermediateVault), 1)
            )
        });
        items[2] = IEVC.BatchItem({
            targetContract: address(intermediateVault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(IVault.skim, (type(uint256).max, alice))
        });

        vm.prank(alice);
        evc.batch{value: amountIn}(items);

        uint256 shares = intermediateVault.balanceOf(alice);
        assertGt(shares, 0, "alice credited IV shares");
        // wstETH that reached the IV's asset (aWSTETH wrapper) tracks the staked amount.
        uint256 wstEthDeposited = IAaveV3ATokenWrapper(wrapper).convertToAssets(intermediateVault.convertToAssets(shares));
        assertApproxEqRel(wstEthDeposited, expectedWstEth, 1e12, "staked wstETH deposited at the protocol rate");
        assertEq(IERC20(WETH).balanceOf(address(assetZap)), 0, "no WETH residue");
        assertEq(IERC20(WSTETH).balanceOf(address(assetZap)), 0, "no wstETH residue");
        assertEq(address(assetZap).balance, 0, "no ETH residue");
    }

    /// @notice USDe -> PT-srUSDe asset-zap into the live Aave PT-srUSDe intermediate vault.
    /// @dev The zap swaps USDe -> PT via the real Pendle router (EVK Swapper Generic handler), then deposits
    ///      PT into the live IV's asset (the wrapper's underlying is raw PT-srUSDe). The live vault only accepts
    ///      raw-PT deposits once the Aave PT-srUSDe reserve is active, so the fork is rolled to the block pinned
    ///      by the asset-zap test. rollFork wipes the test's locally-deployed stack, so a fresh AssetZap is
    ///      deployed on the live EVC and a clean EOA is used (makeAddr() can collide with live contracts).
    function test_aave_frontend_assetZap_USDe_to_PT() public noGasMetering {
        vm.rollFork(AssetZapFrontendHelper.PT_FORK_BLOCK);
        IEVault ptIV = IEVault(AssetZapFrontendHelper.IV_AAVE_PT_SRUSDE);
        AssetZap zap = new AssetZap(AssetZapFrontendHelper.EVC_MAINNET, AssetZapFrontendHelper.SWAPPER);

        address user = makeAddr("ptZapUser");
        vm.etch(user, "");
        vm.deal(user, 0);

        uint256 amountIn = 10_000e18;
        // deal() is unreliable for USDe's storage layout; transfer from the sUSDe contract's balance.
        vm.prank(AssetZapFrontendHelper.SUSDE);
        IERC20(AssetZapFrontendHelper.USDE).transfer(user, amountIn);

        (address sy,,) = IPendleMarket(AssetZapFrontendHelper.PENDLE_MARKET_SRUSDE).readTokens();
        address tokenMintSy = AssetZapFrontendHelper.pickTokenMintSy(sy);

        address wrapper = ptIV.asset();

        bytes[] memory swapData;
        {
            bytes memory pendlePayload = abi.encodeCall(
                IPendleRouter.swapExactTokenForPt, (
                wrapper, // PT lands directly at the wrapper; next step skims it
                AssetZapFrontendHelper.PENDLE_MARKET_SRUSDE,
                0,
                AssetZapFrontendHelper.defaultGuess(),
                PendleTokenInput({
                    tokenIn: AssetZapFrontendHelper.USDE,
                    netTokenIn: amountIn,
                    tokenMintSy: tokenMintSy,
                    pendleSwap: address(0),
                    swapData: PendleSwapData({swapType: 0, extRouter: address(0), extCalldata: "", needScale: false})
                }),
                AssetZapFrontendHelper.emptyLimit()
            ));
            bytes[] memory step1 = AssetZapFrontendHelper.genericSwap(
                AssetZapFrontendHelper.USDE, AssetZapFrontendHelper.PT_SRUSDE, AssetZapFrontendHelper.PENDLE_ROUTER, pendlePayload
            );
            bytes[] memory step2 = AssetZapFrontendHelper.genericSwap(
                AssetZapFrontendHelper.PT_SRUSDE, wrapper, wrapper,
                abi.encodeCall(IAaveV3ATokenWrapper.skim, (address(zap)))
            );
            swapData = new bytes[](2);
            swapData[0] = step1[0];
            swapData[1] = step2[0];
        }

        vm.startPrank(user);
        IERC20(AssetZapFrontendHelper.USDE).approve(address(zap), amountIn);
        zap.zap(AssetZapFrontendHelper.USDE, amountIn, swapData, address(ptIV), 1);
        uint256 shares = ptIV.skim(type(uint).max, user);
        vm.stopPrank();

        assertGt(shares, 0, "user credited IV shares");
        assertEq(ptIV.balanceOf(user), shares, "shares credited to user");
        assertGt(IEVault(ptIV.asset()).convertToAssets(ptIV.convertToAssets(shares)), amountIn * 97 / 100, "PT out sane vs USDe in");
        assertEq(IERC20(AssetZapFrontendHelper.USDE).balanceOf(address(zap)), 0, "no USDe residue");
        assertEq(IERC20(AssetZapFrontendHelper.PT_SRUSDE).balanceOf(address(zap)), 0, "no PT residue");
    }

    // ------------------------------------------------------------------ //
    //                AssetZap into collateral vaults (CV)                 //
    //   Same swap routes as the IV tests above; only the destination and  //
    //   the final absorb step change (CV.skim() vs IV.skim(user)).        //
    // ------------------------------------------------------------------ //

    /// @notice ETH -> WETH asset-zap into an Aave WETH collateral vault.
    /// @dev WETH is airdropped (item 0), deposited into aWETH wrapper shares (item 1 zap), and the CV
    ///      absorbs them via `CV.skim()` (item 2) instead of minting IV shares.
    function test_aave_frontend_assetZap_ETH_to_WETH_CV() public noGasMetering {
        address collateralAsset = address(aWETHWrapper);
        aave_createCollateralVault(collateralAsset, uint16(twyneVaultManager.maxTwyneLTVs(intermediateVaultFor[collateralAsset], USDC)));
        AaveV3CollateralVault cv = alice_aave_vault;
        IEVault intermediateVault = IEVault(intermediateVaultFor[collateralAsset]);
        WstethHandler handler = new WstethHandler(WETH, WSTETH);
        address wrapper = intermediateVault.asset();

        uint256 amountIn = 1 ether;
        vm.deal(alice, amountIn);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);
        items[0] = IEVC.BatchItem({
            targetContract: address(handler),
            onBehalfOfAccount: alice,
            value: amountIn,
            data: abi.encodeCall(WstethHandler.wrapETH, (address(assetZap), WETH))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(assetZap),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(AssetZap.zapUnderlying, (WETH, 0, address(cv), 1))
        });
        items[2] = IEVC.BatchItem({
            targetContract: address(cv),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(cv.skim, ())
        });

        vm.prank(alice);
        evc.batch{value: amountIn}(items);

        assertGt(cv.totalAssetsDepositedOrReserved(), 0, "collateral credited");
        assertGt(IERC20(wrapper).balanceOf(address(cv)), 0, "CV holds wrapper shares");
        assertEq(IERC20(WETH).balanceOf(address(assetZap)), 0, "no WETH residue");
        assertEq(address(assetZap).balance, 0, "no ETH residue");
    }

    /// @notice ETH -> wstETH asset-zap into an Aave wstETH collateral vault.
    /// @dev Same WETH -> wstETH (handler) -> wrapper-shares route as the IV test; the CV absorbs via skim().
    function test_aave_frontend_assetZap_ETH_to_WSTETH_CV() public noGasMetering {
        address collateralAsset = address(aWSTETHWrapper);
        aave_createCollateralVault(collateralAsset, uint16(twyneVaultManager.maxTwyneLTVs(intermediateVaultFor[collateralAsset], USDC)));
        AaveV3CollateralVault cv = alice_aave_vault;
        IEVault intermediateVault = IEVault(intermediateVaultFor[collateralAsset]);
        WstethHandler handler = new WstethHandler(WETH, WSTETH);

        uint256 amountIn = 1 ether;
        vm.deal(alice, amountIn);
        uint256 expectedWstEth = IWstETH(WSTETH).getWstETHByStETH(amountIn);
        address wrapper = intermediateVault.asset();

        bytes[] memory step1 = AssetZapFrontendHelper.genericSwap(
            WETH, WSTETH, address(handler), abi.encodeCall(WstethHandler.wrapWETH, (amountIn, wrapper))
        );
        bytes[] memory step2 = AssetZapFrontendHelper.genericSwap(
            WSTETH, wrapper, wrapper, abi.encodeCall(IAaveV3ATokenWrapper.skim, (address(assetZap)))
        );
        bytes[] memory swapData = new bytes[](2);
        swapData[0] = step1[0];
        swapData[1] = step2[0];

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);
        items[0] = IEVC.BatchItem({
            targetContract: address(handler),
            onBehalfOfAccount: alice,
            value: amountIn,
            data: abi.encodeCall(WstethHandler.wrapETH, (address(assetZap), WETH))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(assetZap),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(AssetZap.zap, (WETH, 0, swapData, address(cv), 1))
        });
        items[2] = IEVC.BatchItem({
            targetContract: address(cv),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(cv.skim, ())
        });

        vm.prank(alice);
        evc.batch{value: amountIn}(items);
        assertGt(cv.totalAssetsDepositedOrReserved(), 0, "collateral credited");
        // The CV auto-reserves credit on deposit (boosted yield), so only the user-owned collateral
        // (totalAssetsDepositedOrReserved - maxRelease) corresponds to the staked wstETH.
        assertApproxEqRel(IAaveV3ATokenWrapper(wrapper).convertToAssets(cv.totalAssetsDepositedOrReserved() - cv.maxRelease()), expectedWstEth, 1e12, "staked wstETH deposited at the protocol rate");
        assertEq(IERC20(WETH).balanceOf(address(assetZap)), 0, "no WETH residue");
        assertEq(IERC20(WSTETH).balanceOf(address(assetZap)), 0, "no wstETH residue");
        assertEq(address(assetZap).balance, 0, "no ETH residue");
    }

    /// @notice USDe -> PT-srUSDe asset-zap into the live Aave PT-srUSDe collateral vault.
    /// @dev Mirrors the IV PT test: the same USDe -> PT -> wrapper swap airdrops wrapper shares at the CV,
    ///      then `CV.skim()` (EVC-routed on the live EVC, on behalf of the live borrower) absorbs them. The
    ///      locally-deployed stack is wiped by rollFork, so the live EVC / live CV / fresh AssetZap are used.
    ///      PT-srUSDe credit is Aave-side only on mainnet; this flow is protocol-agnostic.
    function test_aave_frontend_assetZap_USDe_to_PT_CV() public noGasMetering {
        vm.rollFork(AssetZapFrontendHelper.PT_FORK_BLOCK);
        AaveV3CollateralVault cv = AaveV3CollateralVault(AssetZapFrontendHelper.CV_AAVE_PT_SRUSDE);
        address borrower = cv.borrower();
        IEVault ptIV = cv.intermediateVault();
        AssetZap zap = new AssetZap(AssetZapFrontendHelper.EVC_MAINNET, AssetZapFrontendHelper.SWAPPER);

        vm.etch(borrower, "");

        uint256 amountIn = 10_000e18;
        // deal() is unreliable for USDe's storage layout; transfer from the sUSDe contract's balance.
        vm.prank(AssetZapFrontendHelper.SUSDE);
        IERC20(AssetZapFrontendHelper.USDE).transfer(borrower, amountIn);

        (address sy,,) = IPendleMarket(AssetZapFrontendHelper.PENDLE_MARKET_SRUSDE).readTokens();
        address tokenMintSy = AssetZapFrontendHelper.pickTokenMintSy(sy);
        address wrapper = cv.asset();

        bytes[] memory swapData;
        {
            bytes memory pendlePayload = abi.encodeCall(
                IPendleRouter.swapExactTokenForPt, (
                wrapper, // PT lands directly at the wrapper; next step skims it
                AssetZapFrontendHelper.PENDLE_MARKET_SRUSDE,
                0,
                AssetZapFrontendHelper.defaultGuess(),
                PendleTokenInput({
                    tokenIn: AssetZapFrontendHelper.USDE,
                    netTokenIn: amountIn,
                    tokenMintSy: tokenMintSy,
                    pendleSwap: address(0),
                    swapData: PendleSwapData({swapType: 0, extRouter: address(0), extCalldata: "", needScale: false})
                }),
                AssetZapFrontendHelper.emptyLimit()
            ));
            bytes[] memory step1 = AssetZapFrontendHelper.genericSwap(
                AssetZapFrontendHelper.USDE, AssetZapFrontendHelper.PT_SRUSDE, AssetZapFrontendHelper.PENDLE_ROUTER, pendlePayload
            );
            bytes[] memory step2 = AssetZapFrontendHelper.genericSwap(
                AssetZapFrontendHelper.PT_SRUSDE, wrapper, wrapper,
                abi.encodeCall(IAaveV3ATokenWrapper.skim, (address(zap)))
            );
            swapData = new bytes[](2);
            swapData[0] = step1[0];
            swapData[1] = step2[0];
        }

        uint256 collBefore = cv.totalAssetsDepositedOrReserved();
        vm.startPrank(borrower);
        IERC20(AssetZapFrontendHelper.USDE).approve(address(zap), amountIn);
        zap.zap(AssetZapFrontendHelper.USDE, amountIn, swapData, address(cv), 1);
        // CV.skim() is onlyBorrower-gated and must be routed through the (live) EVC.
        IEVC(AssetZapFrontendHelper.EVC_MAINNET).call(
            address(cv), borrower, 0, abi.encodeCall(cv.skim, ())
        );
        vm.stopPrank();

        assertGt(cv.totalAssetsDepositedOrReserved(), collBefore, "collateral increased by PT airdrop");
        assertEq(IERC20(AssetZapFrontendHelper.USDE).balanceOf(address(zap)), 0, "no USDe residue");
        assertEq(IERC20(AssetZapFrontendHelper.PT_SRUSDE).balanceOf(address(zap)), 0, "no PT residue");
    }

    // ---------------------------------------------------------------------------------------------
    // Borrower-side underlying deposit via AssetZap (replaces the removed CV.depositUnderlying).
    // AssetZap.zapUnderlying pulls WETH, wraps it into aWETHWrapper shares, and airdrops them on the
    // CV; the batch then calls cv.skim() to absorb the airdropped shares as collateral.
    // ---------------------------------------------------------------------------------------------
    function test_aave_frontend_depositUnderlyingViaAssetZap() public noGasMetering {
        aave_createCollateralVault(address(aWETHWrapper), 9100);

        uint256 amountIn = COLLATERAL_AMOUNT;
        vm.startPrank(alice);
        uint256 wethBefore = IERC20(WETH).balanceOf(alice);
        IERC20(WETH).approve(address(assetZap), amountIn);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: address(assetZap),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(AssetZap.zapUnderlying, (WETH, amountIn, address(alice_aave_vault), 0))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.skim, ())
        });
        evc.batch(items);
        vm.stopPrank();

        assertEq(wethBefore - IERC20(WETH).balanceOf(alice), amountIn, "full underlying consumed");
        assertGt(alice_aave_vault.totalAssetsDepositedOrReserved(), 0, "collateral credited to CV");
        assertEq(IERC20(WETH).balanceOf(address(assetZap)), 0, "no underlying residue on zap");
        assertEq(aWETHWrapper.balanceOf(address(assetZap)), 0, "no wrapper residue on zap");
    }
}
