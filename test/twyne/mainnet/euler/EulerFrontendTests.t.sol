// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {EulerTestBase, console2} from "./EulerTestBase.t.sol";
import "euler-vault-kit/EVault/shared/types/Types.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {MockChainlinkOracle} from "test/mocks/MockChainlinkOracle.sol";
import {ChainlinkOracle} from "euler-price-oracle/src/adapter/chainlink/ChainlinkOracle.sol";
import {EulerCollateralVault} from "src/twyne/EulerCollateralVault.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Permit2ECDSASigner} from "euler-vault-kit/../test/mocks/Permit2ECDSASigner.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";
import {MockSwapper} from "test/mocks/MockSwapper.sol";
import {Errors as EVCErrors} from "ethereum-vault-connector/Errors.sol";
import {AssetZapFrontendHelper, IWstETH, IPendleMarket, IPendleRouter, PendleTokenInput, PendleSwapData} from "../AssetZapFrontendHelper.sol";
import {AssetZap} from "src/Periphery/AssetZap.sol";
import {IVault} from "euler-vault-kit/EVault/IEVault.sol";
import {IAaveV3ATokenWrapper} from "src/interfaces/IAaveV3ATokenWrapper.sol";
import {CollateralVaultBase} from "src/twyne/CollateralVaultBase.sol";

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
            data: abi.encodeCall(collateralVaultFactory.createEulerCollateralVault, (intermediateVaultFor[eulerWETH], eulerUSDC, twyneLiqLTV))
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

        // Wrap WETH into the eToken (eulerWETH) and approve the collateral vault before depositing
        IERC20(WETH).approve(eulerWETH, COLLATERAL_AMOUNT);
        uint collateralShares = IEVault(eulerWETH).deposit(COLLATERAL_AMOUNT, alice);
        IERC20(eulerWETH).approve(address(user_collateral_vault), collateralShares);

        items = new IEVC.BatchItem[](4);
        // Create collateral vault
        items[0] = IEVC.BatchItem({
            targetContract: address(collateralVaultFactory),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(collateralVaultFactory.createEulerCollateralVault, (intermediateVaultFor[eulerWETH], eulerUSDC, twyneLiqLTV))
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
            data: abi.encodeCall(EulerCollateralVault(user_collateral_vault).deposit, (collateralShares))
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
    //     uint userCollateralValue = oracleRouter.getQuote(
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
    function test_e_1clickLeverage() public noGasMetering {
        e_creditDeposit(eulerWETH);
        MockSwapper mockSwapper = new MockSwapper();
        vm.etch(eulerSwapper, address(mockSwapper).code);

        // Step 1: Create collateral vault for user
        vm.startPrank(alice);
        EulerCollateralVault alice_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createEulerCollateralVault({
                _intermediateVault: intermediateVaultFor[eulerWETH],
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

        deal(WETH, eulerSwapper, minAmountOutWETH + 10);
        // Prepare swap data for the swapper. This is mock data.
        bytes memory swapData = abi.encodeCall(MockSwapper.swap, (USDC, WETH, flashloanAmount, minAmountOutWETH, eulerWETH));
        bytes[] memory multicallData = new bytes[](1);
        // Swapper.multicall is called with `multicallData`
        multicallData[0] = swapData;

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
    }

    // Test 1-click leverage functionality
    function test_e_1clickLeverageBatch() public noGasMetering returns (EulerCollateralVault) {
        e_creditDeposit(eulerWETH);
        MockSwapper mockSwapper = new MockSwapper();
        vm.etch(eulerSwapper, address(mockSwapper).code);

        // Step 1: Create collateral vault for user
        vm.startPrank(alice);
        EulerCollateralVault alice_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createEulerCollateralVault({
                _intermediateVault: intermediateVaultFor[eulerWETH],
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

        deal(WETH, eulerSwapper, minAmountOutWETH + 10);
        // Prepare swap data for the swapper. This is mock data.
        bytes memory swapData = abi.encodeCall(MockSwapper.swap, (USDC, WETH, flashloanAmount, minAmountOutWETH, eulerWETH));
        bytes[] memory multicallData = new bytes[](1);
        // Swapper.multicall is called with `multicallData`
        multicallData[0] = swapData;

        // Execute leverage through EVC batch with operator setup
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);

        // Item 0: Enable operator
        items[0] = IEVC.BatchItem({
            targetContract: address(evc),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeCall(evc.setAccountOperator, (alice, address(leverageOperator), true))
        });

        // Item 1: Execute leverage operation
        items[1] = IEVC.BatchItem({
            targetContract: address(leverageOperator),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(leverageOperator.executeLeverage, (
                address(alice_collateral_vault),
                userUnderlyingCollateralAmount,
                userCollateralAmount,
                flashloanAmount,
                minAmountOutWETH,
                deadline,
                multicallData
            ))
        });

        // Item 2: Disable operator
        items[2] = IEVC.BatchItem({
            targetContract: address(evc),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeCall(evc.setAccountOperator, (alice, address(leverageOperator), false))
        });

        evc.batch(items);
        return alice_collateral_vault;
    }

    function test_1clickDeleverage() public noGasMetering {
        EulerCollateralVault alice_collateral_vault = test_e_1clickLeverageBatch();

        // Now test deleverage
        uint flashloanAmount = alice_collateral_vault.totalAssetsDepositedOrReserved() - alice_collateral_vault.maxRelease(); // WETH flashloan for deleverage
        uint maxDebt = 0; // Maximum remaining debt after deleverage
        uint withdrawCollateralAmount = flashloanAmount; // Amount of collateral to withdraw

        uint minAmountOutUSDC = alice_collateral_vault.maxRepay();
        deal(USDC, eulerSwapper, minAmountOutUSDC + 10);

        // Create deleverage swap data
        bytes[] memory deleverageMulticallData = new bytes[](1);
        {
            bytes memory deleverageSwapData = abi.encodeCall(MockSwapper.swap, (WETH, USDC, flashloanAmount, minAmountOutUSDC, address(deleverageOperator)));
            deleverageMulticallData[0] = deleverageSwapData;
        }

        // Execute deleverage
        IEVC.BatchItem[] memory deleverageItems = new IEVC.BatchItem[](3);
        deleverageItems[0] = IEVC.BatchItem({
            targetContract: address(evc),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeCall(evc.setAccountOperator, (alice, address(deleverageOperator), true))
        });
        deleverageItems[1] = IEVC.BatchItem({
            targetContract: address(deleverageOperator),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(deleverageOperator.executeDeleverage, (
                address(alice_collateral_vault),
                flashloanAmount,
                maxDebt,
                withdrawCollateralAmount,
                deleverageMulticallData
            ))
        });
        deleverageItems[2] = IEVC.BatchItem({
            targetContract: address(evc),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeCall(evc.setAccountOperator, (alice, address(deleverageOperator), false))
        });

        evc.batch(deleverageItems);


        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------
    // AssetZap reference flows (frontend: zap any asset into an intermediate vault in one tx).
    // Each flow deposits credit (LP side) — borrow flows are shown in the tests above.
    // ---------------------------------------------------------------------------------------------

    /// @notice USDe -> PT-srUSDe asset-zap into the live Aave PT-srUSDe intermediate vault.
    /// @dev PT-srUSDe credit is Aave-side on mainnet (there is no Euler PT-srUSDe vault), and the asset-zap is
    ///      protocol-agnostic, so this reference flow is identical for an Euler frontend. The zap swaps USDe -> PT
    ///      via the real Pendle router (EVK Swapper Generic handler), then deposits PT into the live IV's asset
    ///      (the wrapper's underlying is raw PT-srUSDe). The live vault only accepts raw-PT deposits once the Aave
    ///      PT-srUSDe reserve is active, so the fork is rolled to the block pinned by the asset-zap test.
    ///      rollFork wipes the test's locally-deployed stack, so a fresh AssetZap is deployed on the live EVC and
    ///      a clean EOA is used (makeAddr() can collide with live contracts).
    function test_e_frontend_assetZap_USDe_to_PT() public noGasMetering {
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

        bytes memory pendlePayload = abi.encodeCall(
            IPendleRouter.swapExactTokenForPt,
            (
                wrapper, // PT lands directly at the wrapper; the next step skims it
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
            )
        );
        bytes[] memory step1 = AssetZapFrontendHelper.genericSwap(
            AssetZapFrontendHelper.USDE, AssetZapFrontendHelper.PT_SRUSDE, AssetZapFrontendHelper.PENDLE_ROUTER, pendlePayload
        );
        bytes[] memory step2 = AssetZapFrontendHelper.genericSwap(
            AssetZapFrontendHelper.PT_SRUSDE, wrapper, wrapper,
            abi.encodeCall(IAaveV3ATokenWrapper.skim, (address(zap)))
        );
        bytes[] memory swapData = new bytes[](2);
        swapData[0] = step1[0];
        swapData[1] = step2[0];

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

    /// @notice USDe -> PT-srUSDe asset-zap into the live PT-srUSDe collateral vault.
    /// @dev PT-srUSDe credit is Aave-side on mainnet (there is no Euler PT-srUSDe vault), and the asset-zap
    ///      is protocol-agnostic, so this reference CV flow is identical for an Euler frontend: the same
    ///      USDe -> PT -> wrapper swap airdrops wrapper shares at the CV, then `CV.skim()` (EVC-routed on the
    ///      live EVC, on behalf of the live borrower) absorbs them. rollFork wipes the local stack, so the
    ///      live EVC / live CV / fresh AssetZap are used.
    function test_e_frontend_assetZap_USDe_to_PT_CV() public noGasMetering {
        vm.rollFork(AssetZapFrontendHelper.PT_FORK_BLOCK);
        CollateralVaultBase cv = CollateralVaultBase(payable(AssetZapFrontendHelper.CV_AAVE_PT_SRUSDE));
        address borrower = cv.borrower();
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
    // AssetZap.zapUnderlying pulls WETH, wraps it into eulerWETH (eToken) shares, and airdrops them on
    // the CV; the batch then calls cv.skim() to absorb the airdropped shares as collateral.
    // ---------------------------------------------------------------------------------------------
    function test_e_frontend_depositUnderlyingViaAssetZap() public noGasMetering {
        e_createCollateralVault(eulerWETH, 0.9e4);

        uint256 amountIn = COLLATERAL_AMOUNT;
        vm.startPrank(alice);
        uint256 wethBefore = IERC20(WETH).balanceOf(alice);
        IERC20(WETH).approve(address(assetZap), amountIn);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: address(assetZap),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(AssetZap.zapUnderlying, (WETH, amountIn, address(alice_collateral_vault), 0))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.skim, ())
        });
        evc.batch(items);
        vm.stopPrank();

        assertEq(wethBefore - IERC20(WETH).balanceOf(alice), amountIn, "full underlying consumed");
        assertGt(alice_collateral_vault.totalAssetsDepositedOrReserved(), 0, "collateral credited to CV");
        assertEq(IERC20(WETH).balanceOf(address(assetZap)), 0, "no underlying residue on zap");
        assertEq(IEVault(eulerWETH).balanceOf(address(assetZap)), 0, "no wrapper residue on zap");
    }
}
