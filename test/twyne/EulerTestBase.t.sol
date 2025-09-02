// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {OverCollateralizedTestBase, console2} from "./OverCollateralizedTestBase.t.sol";
import "euler-vault-kit/EVault/shared/types/Types.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {EulerCollateralVault, CollateralVaultBase} from "src/twyne/EulerCollateralVault.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {Errors} from "euler-vault-kit/EVault/shared/Errors.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Permit2ECDSASigner} from "euler-vault-kit/../test/mocks/Permit2ECDSASigner.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {MockChainlinkOracle} from "test/mocks/MockChainlinkOracle.sol";
import {ChainlinkOracle} from "euler-price-oracle/src/adapter/chainlink/ChainlinkOracle.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {SafeERC20Lib} from "euler-vault-kit/EVault/shared/lib/SafeERC20Lib.sol";

contract EulerTestBase is OverCollateralizedTestBase {
    function setUp() public virtual override {
        super.setUp();
    }

    // parent
    function e_creditDeposit(address collateralAssets) public noGasMetering {
        vm.assume(isValidCollateralAsset(collateralAssets));
        IEVault intermediate_vault = IEVault(twyneVaultManager.getIntermediateVault(collateralAssets));
        // Bob deposits into intermediate_vault to earn boosted yield
        vm.startPrank(bob);
        IERC20(collateralAssets).approve(address(intermediate_vault), type(uint256).max);
        uint8 decimals = IERC20(IEVault(collateralAssets).asset()).decimals();
        if (decimals < 18) {
            CREDIT_LP_AMOUNT /= (10 ** (18 - decimals));
            COLLATERAL_AMOUNT /= (10 ** (18 - decimals));
            INITIAL_DEALT_ETOKEN /= (10 ** (18 - decimals));
        }
        intermediate_vault.deposit(CREDIT_LP_AMOUNT, bob);
        vm.stopPrank();

        assertEq(intermediate_vault.totalAssets(), CREDIT_LP_AMOUNT, "Incorrect CREDIT_LP_AMOUNT deposited");
    }

    // parent
    function e_createCollateralVault(address collateralAssets, uint16 liqLTV) public noGasMetering {
        // copy logic from checkLiqLTV
        uint16 minLTV = IEVault(eulerUSDC).LTVLiquidation(eulerWETH);
        uint16 extLiqBuffer = twyneVaultManager.externalLiqBuffers(eulerWETH);
        vm.assume(uint(minLTV) * uint(extLiqBuffer) <= uint256(liqLTV) * MAXFACTOR);
        vm.assume(liqLTV <= twyneVaultManager.maxTwyneLTVs(eulerWETH));

        e_creditDeposit(collateralAssets);

        // Alice creates eWETH collateral vault with USDC target asset
        vm.startPrank(alice);
        alice_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _asset: collateralAssets,
                _targetVault: eulerUSDC,
                _liqLTV: liqLTV
            })
        );
        vm.stopPrank();

        vm.label(address(alice_collateral_vault), "alice_collateral_vault");
    }

    // parent
    function e_totalAssetsIntermediateVault(address collateralAssets, uint16 liqLTV) public noGasMetering {
        e_createCollateralVault(collateralAssets, liqLTV);
        IEVault intermediate_vault = IEVault(twyneVaultManager.getIntermediateVault(collateralAssets));
        // eve donates to collateral vault, ensure this doesn't increase its totalAssets
        vm.startPrank(eve);
        // balanceOf before and after the transfer of eWETH is unchanged
        assertEq(IEVault(collateralAssets).balanceOf(address(intermediate_vault)), intermediate_vault.totalAssets(), "totalAssets value mismatch before airdrop");
        assertEq(IEVault(collateralAssets).balanceOf(address(intermediate_vault)), CREDIT_LP_AMOUNT);
        IERC20(collateralAssets).transfer(address(intermediate_vault), CREDIT_LP_AMOUNT);
        assertEq(intermediate_vault.totalAssets(), CREDIT_LP_AMOUNT, "totalAssets value mismatch after airdrop 1");
        assertEq(IEVault(collateralAssets).balanceOf(address(intermediate_vault)), 2*CREDIT_LP_AMOUNT);

        // Would call skim() normally here, but this is blocked to prevent edge cases
        vm.expectRevert(TwyneErrors.T_OperationDisabled.selector);
        intermediate_vault.skim(CREDIT_LP_AMOUNT, eve);
        vm.stopPrank();
    }

    // Verify how totalAssets works with a donation attack (EVK ignore the amount)
    // This functionality could be disabled by setting the OP_SKIM opcode
    function e_totalAssetsCollateralVault(address collateralAssets, uint16 liqLTV) public noGasMetering {
        e_createCollateralVault(collateralAssets, liqLTV);
        // eve donates to collateral vault, ensure this doesn't increase its totalAssets
        vm.startPrank(eve);
        IERC20(collateralAssets).transfer(address(alice_collateral_vault), COLLATERAL_AMOUNT);
        vm.stopPrank();

        assertEq(alice_collateral_vault.totalAssetsDepositedOrReserved(), 0);
        assertEq(alice_collateral_vault.balanceOf(address(alice_collateral_vault)), 0);
        assertEq(
            IERC20(collateralAssets).balanceOf(address(alice_collateral_vault)),
            COLLATERAL_AMOUNT,
            "Collateral vault not holding correct eulerWETH balance"
        );
    }

    // parent
    // Verify that the EVK supply cap works as expected (already handled by EVK tests, but let's demonstrate it here)
    function e_supplyCap_creditDeposit(address collateralAssets) public noGasMetering {
        vm.assume(isValidCollateralAsset(collateralAssets));
        IEVault intermediate_vault = IEVault(twyneVaultManager.getIntermediateVault(collateralAssets));

        vm.startPrank(address(intermediate_vault.governorAdmin()));
        uint16 supplyCap = 32000 + IERC20(IEVault(collateralAssets).asset()).decimals();
        intermediate_vault.setCaps(supplyCap, supplyCap);
        vm.stopPrank();

        // Bob deposits into intermediate_vault to earn boosted yield
        vm.startPrank(bob);
        IERC20(collateralAssets).approve(address(intermediate_vault), type(uint256).max);
        // 5 ETH is the supply cap
        intermediate_vault.deposit(5 * (10 ** IERC20(IEVault(collateralAssets).asset()).decimals()), bob);
        // but revert if any more is deposited
        vm.expectRevert(Errors.E_SupplyCapExceeded.selector);
        intermediate_vault.deposit(1 wei, bob);
        vm.stopPrank();
    }

    // parent
    function e_second_creditDeposit(address collateralAssets) public noGasMetering {
        e_creditDeposit(collateralAssets);
        IEVault intermediate_vault = IEVault(twyneVaultManager.getIntermediateVault(collateralAssets));
        // Bob deposits more into eeWETH_intermediate_vault to earn boosted yield
        vm.startPrank(bob);
        intermediate_vault.deposit(CREDIT_LP_AMOUNT, bob);

        // Confirm complete withdrawal from intermediate vault works
        assertApproxEqRel(intermediate_vault.totalAssets(), 2 * CREDIT_LP_AMOUNT, 1e5);
        intermediate_vault.withdraw(2 * CREDIT_LP_AMOUNT, bob, bob);
        vm.stopPrank();
    }

    // parent
    // credit LP withdraws their deposit in the intermediate vault
    // 100% can be withdrawn if there is no reserved assets in any collateral vault
    function e_creditWithdrawNoInterest(address collateralAssets) public noGasMetering {
        e_creditDeposit(collateralAssets);
        IEVault intermediate_vault = IEVault(twyneVaultManager.getIntermediateVault(collateralAssets));

        assertEq(intermediate_vault.totalAssets(), CREDIT_LP_AMOUNT, "totalAssets isn't the expected value");
        assertEq(intermediate_vault.balanceOf(bob), CREDIT_LP_AMOUNT, "bob has wrong balance");

        // Credit LP Bob withdraws all
        vm.startPrank(bob);
        IERC20(collateralAssets).approve(address(intermediate_vault), type(uint256).max);
        intermediate_vault.withdraw(CREDIT_LP_AMOUNT, bob, bob);
        vm.stopPrank();

        assertEq(intermediate_vault.totalAssets(), 0);
    }

    // parent
    // Test the case of B = 0 (no borrowed assets from the external protocol) with non-zero C and C_LP
    function e_collateralDepositWithoutBorrow(address collateralAssets, uint16 liqLTV) public noGasMetering {
        e_createCollateralVault(collateralAssets, liqLTV);

        vm.startPrank(alice);
        assertEq(alice_collateral_vault.borrower(), alice);
        assertEq(collateralVaultFactory.getCollateralVaults(alice)[0], address(alice_collateral_vault));

        IERC20(collateralAssets).approve(address(alice_collateral_vault), type(uint).max);

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

        vm.startPrank(bob);
        IERC20(WETH).approve(address(alice_collateral_vault), type(uint).max);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_collateral_vault.depositUnderlying(COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    // parent
    // credit LP withdraws their deposit in the intermediate vault
    // 100% can be withdrawn if there is no reserved assets in any collateral vault
    function e_creditWithdrawWithInterestAndNoFees(address collateralAssets, uint warpBlockAmount) public noGasMetering {
        vm.assume(warpBlockAmount < forkBlockDiff);
        e_collateralDepositWithoutBorrow(collateralAssets, 0.9e4);

        IEVault intermediate_vault = IEVault(twyneVaultManager.getIntermediateVault(collateralAssets));

        // Confirm fees setup
        assertEq(intermediate_vault.interestFee(), 0, "Unexpected intermediate vault interest fee");
        assertEq(intermediate_vault.feeReceiver(), feeReceiver, "fee receiver address is wrong");
        assertEq(intermediate_vault.protocolFeeShare(), 0, "Unexpected intermediate vault interest fee");

        // warp forward to simulate any balance increase
        vm.roll(block.number + warpBlockAmount);
        vm.warp(block.timestamp + 365 days);

        // Confirm that time passing makes the collateral vault rebalanceable
        assertGt(alice_collateral_vault.canRebalance(), 0, "Vault is not rebalanceable even with time passing");

        // Now overwrite the oracle address to avoid stale price revert condition
        // address matchingOracle = EulerRouter(IEVault(targetAssetVault).oracle()).getConfiguredOracle(targetAsset, USD);
        // address resolvedAddress = EulerRouter(IEVault(targetAssetVault).oracle()).resolvedVaults(targetAsset);
        //     if(matchingOracle == address(0) && resolvedAddress != address(0)) {
        //         address newTargetAsset = IEVault(targetAsset).asset();
        //         matchingOracle = EulerRouter(IEVault(targetAssetVault).oracle()).getConfiguredOracle(newTargetAsset, USD);
        //         // if a matching oracle is found (not address(0)), then the proper oracle can be set. Otherwise, revert and handle the edge case manually
        //         if(matchingOracle != address(0)) {
        //             twyneVaultManager.setOracleResolvedVault(targetAsset, true);
        //             twyneVaultManager.doCall(address(twyneVaultManager.oracleRouter()), 0, abi.encodeCall(EulerRouter.govSetConfig, (IEVault(targetAsset).asset(), USD, matchingOracle)));
        //         } else {
        //             revert NoConfiguredOracle();
        //         }
        //     }

        address configured_asset_USD_Oracle = oracleRouter.getConfiguredOracle(IEVault(collateralAssets).asset(), USD);
        address resolvedAddress = EulerRouter(oracleRouter).resolvedVaults(IEVault(collateralAssets).asset());
        if(configured_asset_USD_Oracle == address(0) && resolvedAddress != address(0)) {
            console2.log("ERROR FOUND");
        } else {
            address chainlinkFeed = ChainlinkOracle(configured_asset_USD_Oracle).feed();
            MockChainlinkOracle mockChainlink = new MockChainlinkOracle(IEVault(collateralAssets).asset(), USD, chainlinkFeed, 61 seconds);
            vm.etch(configured_asset_USD_Oracle, address(mockChainlink).code);
        }

        // Alice withdraws her borrowing position from the collateral vault
        vm.startPrank(alice);
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);

        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.withdraw, (alice_collateral_vault.balanceOf(address(alice_collateral_vault)), alice))
        });

        evc.batch(items);
        vm.stopPrank();
        assertEq(IERC20(collateralAssets).balanceOf(address(alice_collateral_vault)), 0, "Incorrect eulerWETH balance remaining in vault");

        // Credit LP Bob withdraws all
        vm.startPrank(bob);
        intermediate_vault.redeem(type(uint).max, bob, bob);
        intermediate_vault.convertFees();
        vm.stopPrank();

        // Confirm zero accrued fees in intermediate vault
        assertEq(intermediate_vault.accumulatedFees(), 0, "Should have zero accumulated fees if fees are disabled");

        assertEq(intermediate_vault.totalSupply(), 0, "Intermediate vault is not empty as expected!");
        assertNotEq(intermediate_vault.totalAssets(), 0, "Awesome, no dust left in the contract at all. How did you do that?");
    }

    // credit LP withdraws their deposit in the intermediate vault
    // 100% can be withdrawn if there is no reserved assets in any collateral vault
    function e_creditWithdrawWithInterestAndFees(address collateralAssets) public noGasMetering {
        e_collateralDepositWithoutBorrow(collateralAssets, 0.9e4);

        IEVault intermediate_vault = IEVault(twyneVaultManager.getIntermediateVault(collateralAssets));

        // Set non-zero protocolConfig fee
        vm.startPrank(admin);
        protocolConfig.setInterestFeeRange(0.1e4, 1e4); // set fee range to zero
        protocolConfig.setProtocolFeeShare(0.5e4); // set fee to zero
        assertNotEq(intermediate_vault.protocolFeeShare(), 0, "Protocol fee should not be zero");
        vm.stopPrank();

        // Set non-zero governance fee
        vm.startPrank(intermediate_vault.governorAdmin());
        intermediate_vault.setFeeReceiver(feeReceiver);
        intermediate_vault.setInterestFee(0.1e4); // set non-zero governance fee
        assertEq(intermediate_vault.interestFee(), 0.1e4, "Unexpected intermediate vault interest rate");
        vm.stopPrank();

        // warp forward to simulate any balance increase
        uint256 blockIncrement = 1000;
        vm.roll(block.number + blockIncrement);
        vm.warp(block.timestamp + 365 days);

        // Confirm that time passing makes the collateral vault rebalanceable
        assertGt(alice_collateral_vault.canRebalance(), 0, "Vault is not rebalanceable even with time passing");

        // Now overwrite the oracle address to avoid stale price revert condition
        address configuredWETH_USD_Oracle = oracleRouter.getConfiguredOracle(WETH, USD);
        address chainlinkFeed = ChainlinkOracle(configuredWETH_USD_Oracle).feed();
        MockChainlinkOracle mockChainlink = new MockChainlinkOracle(WETH, USD, chainlinkFeed, 61 seconds);
        vm.etch(configuredWETH_USD_Oracle, address(mockChainlink).code);

        // Alice withdraws her borrowing position from the collateral vault
        vm.startPrank(alice);
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);

        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.withdraw, (alice_collateral_vault.balanceOf(address(alice_collateral_vault)), alice))
        });

        evc.batch(items);
        vm.stopPrank();
        assertEq(IERC20(collateralAssets).balanceOf(address(alice_collateral_vault)), 0, "Incorrect eulerWETH balance remaining in vault");

        // Credit LP Bob withdraws all
        vm.startPrank(bob);
        intermediate_vault.redeem(type(uint).max, bob, bob);
        assertEq(intermediate_vault.totalSupply(), intermediate_vault.accumulatedFees(), "Remaining assets are not just fees!");
        vm.stopPrank();

        // Withdraw all the accrued fees to fully empty the intermediate vault
        vm.startPrank(feeReceiver);
        assertEq(intermediate_vault.feeReceiver(), feeReceiver, "Unexpected feeReceiver");
        // First, split the fees
        intermediate_vault.convertFees();
        // Withdraw the fees owed to fee receiver (AKA governor receiver)
        uint receiveFees = intermediate_vault.redeem(type(uint).max, feeReceiver, feeReceiver);
        assertNotEq(receiveFees, 0, "Received governor fees was zero?!");
        vm.stopPrank();

        vm.startPrank(protocolFeeReceiver);
        assertEq(intermediate_vault.protocolFeeReceiver(), protocolFeeReceiver, "Unexpected protocolFeeReceiver");
        // Withdraw the fees owed to protocolConfig feeReceiver
        receiveFees = intermediate_vault.redeem(type(uint).max, protocolFeeReceiver, protocolFeeReceiver);
        assertNotEq(receiveFees, 0, "Received protocolConfig fees was zero?!");
        vm.stopPrank();

        assertEq(intermediate_vault.totalSupply(), 0, "Intermediate vault is not empty as expected!");
        assertNotEq(intermediate_vault.totalAssets(), 0, "Awesome, no dust left in the contract at all. How did you do that?");
    }

    // Test the case of C_LP = 0 (no reserved assets) with non-zero C and B
    // This should be identical to using the underlying protocol without Twyne
    function e_collateralDepositWithBorrow(address collateralAssets) public noGasMetering {
        e_createCollateralVault(collateralAssets, 0.9e4);

        uint aliceUSDCBalanceBefore = IERC20(USDC).balanceOf(alice);

        vm.startPrank(alice);
        assertEq(alice_collateral_vault.borrower(), alice);
        assertEq(collateralVaultFactory.getCollateralVaults(alice)[0], address(alice_collateral_vault));

        IERC20(collateralAssets).approve(address(alice_collateral_vault), type(uint).max);

        // Deposit 1 eWETH, withdraw to the maxBorrow limit allowed by the external EVK vault
        uint256 oneEther = uint256(IERC20(collateralAssets).decimals());

        uint256 borrowAmountInETH = Math.min(
            oneEther * uint(IEVault(eulerUSDC).LTVBorrow(collateralAssets)) / MAXFACTOR,
            oneEther * uint(IEVault(eulerUSDC).LTVLiquidation(collateralAssets)) * uint(twyneVaultManager.externalLiqBuffers(alice_collateral_vault.asset())) / (MAXFACTOR * MAXFACTOR)
        );

        // Some shared logic with test_e_maxBorrowFromEulerDirect()
        alice_collateral_vault.setTwyneLiqLTV(uint(IEVault(eulerUSDC).LTVLiquidation(collateralAssets)) * uint(twyneVaultManager.externalLiqBuffers(alice_collateral_vault.asset())) / MAXFACTOR);
        uint borrowValueInUSD = eulerOnChain.getQuote(borrowAmountInETH, collateralAssets, USD);
        uint USDCPrice = eulerOnChain.getQuote(1, USDC, USD); // returns a value times 1e10
        uint borrowAmountInUSDC = borrowValueInUSD / USDCPrice;

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        // reserve assets from intermediate vault
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.deposit, (oneEther))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.borrow, (borrowAmountInUSDC, alice))
        });

        evc.batch(items);

        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(WETH).approve(address(alice_collateral_vault), type(uint).max);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_collateral_vault.depositUnderlying(1);
        vm.stopPrank();

        uint aliceUSDCBalanceAfter = IERC20(USDC).balanceOf(alice);
        assertEq(aliceUSDCBalanceAfter - aliceUSDCBalanceBefore, borrowAmountInUSDC, "Unexpected amount of USDC held by Alice");
    }

    // Deposit WETH instead of eWETH into Twyne
    // This allows users to bypass the Euler Finance frontend entirely
    function e_collateralDepositUnderlying(address collateralAssets) public noGasMetering {
        e_createCollateralVault(collateralAssets, 0.9e4);

        vm.startPrank(alice);
        assertEq(alice_collateral_vault.borrower(), alice);
        assertEq(collateralVaultFactory.getCollateralVaults(alice)[0], address(alice_collateral_vault));

        IERC20(IEVault(collateralAssets).asset()).approve(address(alice_collateral_vault), type(uint).max);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        // reserve assets from intermediate vault
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.depositUnderlying, COLLATERAL_AMOUNT)
        });

        evc.batch(items);
        vm.stopPrank();
    }

    // Test Permit2 deposit of eWETH (not WETH)
    function e_permit2CollateralDeposit(address collateralAssets) public noGasMetering {
        e_creditDeposit(collateralAssets);

        // repeat but for collateral non-EVK vault
        (address user, uint privKey) = makeAddrAndKey("permit2user");
        vm.startPrank(user);
        address user_collateral_vault = collateralVaultFactory.createCollateralVault({
                _asset: collateralAssets,
                _targetVault: eulerUSDC,
                _liqLTV: twyneLiqLTV
            }
        );

        // confirm that without permit2, the deposit action fails
        vm.expectPartialRevert(SafeERC20Lib.E_TransferFromFailed.selector);
        EulerCollateralVault(user_collateral_vault).deposit(uint160(COLLATERAL_AMOUNT));

        vm.label(address(user_collateral_vault), "user_collateral_vault");
        deal(address(collateralAssets), user, INITIAL_DEALT_ETOKEN);

        IERC20(collateralAssets).approve(permit2, type(uint).max);
        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: collateralAssets,
                amount: uint160(COLLATERAL_AMOUNT),
                expiration: type(uint48).max,
                nonce: 0
            }),
            spender: user_collateral_vault,
            sigDeadline: type(uint256).max
        });

        uint256 reservedAmount = getReservedAssets(COLLATERAL_AMOUNT, EulerCollateralVault(user_collateral_vault));

        Permit2ECDSASigner permit2Signer = new Permit2ECDSASigner(address(permit2));
        // build a deposit batch with permit2
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0].targetContract = permit2;
        items[0].onBehalfOfAccount = user;
        items[0].value = 0;
        items[0].data = abi.encodeWithSignature(
            "permit(address,((address,uint160,uint48,uint48),address,uint256),bytes)",
            user,
            permitSingle,
            permit2Signer.signPermitSingle(privKey, permitSingle)
        );

        items[1].targetContract = address(user_collateral_vault);
        items[1].onBehalfOfAccount = user;
        items[1].value = 0;
        items[1].data = abi.encodeCall(EulerCollateralVault(user_collateral_vault).deposit, (uint160(COLLATERAL_AMOUNT)));

        evc.batch(items);
        vm.stopPrank();

        uint collateralAssetBalance = IEVault(collateralAssets).balanceOf(user_collateral_vault);
        assertEq(collateralAssetBalance, COLLATERAL_AMOUNT + reservedAmount, "Permit2: Unexpected amount of collateralAsset in collateral vault");
    }

    // Test Permit2 deposit of WETH (not eWETH)
    function e_permit2_CollateralDepositUnderlying(address collateralAssets) public noGasMetering {
        e_creditDeposit(collateralAssets);

        (address user, uint privKey) = makeAddrAndKey("permit2user");
        vm.startPrank(user);
        address user_collateral_vault = collateralVaultFactory.createCollateralVault({
                _asset: collateralAssets,
                _targetVault: eulerUSDC,
                _liqLTV: twyneLiqLTV
            }
        );

        // confirm that without permit2, the deposit action fails
        vm.expectPartialRevert(SafeERC20Lib.E_TransferFromFailed.selector);
        EulerCollateralVault(user_collateral_vault).deposit(uint160(COLLATERAL_AMOUNT));

        vm.label(address(user_collateral_vault), "user_collateral_vault");

        deal(IEVault(collateralAssets).asset(), user, INITIAL_DEALT_ERC20);
        IERC20(IEVault(collateralAssets).asset()).approve(permit2, type(uint).max);
        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: IEVault(collateralAssets).asset(),
                amount: uint160(COLLATERAL_AMOUNT),
                expiration: type(uint48).max,
                nonce: 0
            }),
            spender: user_collateral_vault,
            sigDeadline: type(uint256).max
        });

        Permit2ECDSASigner permit2Signer = new Permit2ECDSASigner(address(permit2));
        // build a deposit batch with permit2
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0].targetContract = permit2;
        items[0].onBehalfOfAccount = user;
        items[0].value = 0;
        items[0].data = abi.encodeWithSignature(
            "permit(address,((address,uint160,uint48,uint48),address,uint256),bytes)",
            user,
            permitSingle,
            permit2Signer.signPermitSingle(privKey, permitSingle)
        );

        items[1].targetContract = address(user_collateral_vault);
        items[1].onBehalfOfAccount = user;
        items[1].value = 0;
        items[1].data = abi.encodeCall(EulerCollateralVault(user_collateral_vault).depositUnderlying, (COLLATERAL_AMOUNT));

        evc.batch(items);
        vm.stopPrank();
    }

    // Test the creation of a collateral vault in a batch (the frontend does this)
    function e_evcCanCreateCollateralVault(address collateralAssets) public noGasMetering {
        vm.assume(isValidCollateralAsset(collateralAssets));
        vm.startPrank(alice);
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(collateralVaultFactory),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(collateralVaultFactory.createCollateralVault, (collateralAssets, eulerUSDC, twyneLiqLTV))
        });
        (IEVC.BatchItemResult[] memory batchItemsResult,,) = evc.batchSimulation(items);
        address collateral_vault = address(uint160(uint(bytes32(batchItemsResult[0].result))));

        assertEq(collateral_vault.code.length, 0);

        evc.batch(items);
        vm.stopPrank();
        assertGt(collateral_vault.code.length, 0);

        assertEq(CollateralVaultBase(collateral_vault).borrower(), alice);
    }

    // Test that if time passes, user can withdraw all it's share of the collateral
    function e_withdrawCollateralAfterWarp(address collateralAssets, uint warpBlockAmount) public noGasMetering {
        vm.assume(warpBlockAmount < forkBlockDiff); // this keeps the block number less than or equal to the current block. Depends on which chain is being tested
        e_createCollateralVault(collateralAssets, 0.9e4);

        vm.startPrank(alice);

        IERC20(collateralAssets).approve(address(alice_collateral_vault), type(uint256).max);

        uint256 reservedAmount = getReservedAssets(COLLATERAL_AMOUNT, alice_collateral_vault);

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

        // Perform balance checks
        assertEq(alice_collateral_vault.balanceOf(address(alice_collateral_vault)), COLLATERAL_AMOUNT, "Wrong collateral vault balance before warp");
        assertEq(alice_collateral_vault.totalAssetsDepositedOrReserved(), COLLATERAL_AMOUNT + reservedAmount, "Wrong totalAssetsDepositedOrReserved before warp");
        assertEq(
            IERC20(collateralAssets).balanceOf(address(alice_collateral_vault)), COLLATERAL_AMOUNT + reservedAmount, "Wrong collateral balance before warp");

        // warp forward, allows Euler balances to increase
        vm.roll(block.number + warpBlockAmount);
        vm.warp(block.timestamp + 600);

        assertEq(
            IERC20(collateralAssets).balanceOf(address(alice_collateral_vault)), COLLATERAL_AMOUNT + reservedAmount, "Wrong collateral balance after warp");
        assertGt(alice_collateral_vault.maxRelease(), 0, "Wrong release value after warp");
        uint userCollateral = COLLATERAL_AMOUNT - (alice_collateral_vault.maxRelease() - reservedAmount); // deposited collateral - (increase in debt to intermediate vault)
        assertEq(alice_collateral_vault.balanceOf(address(alice_collateral_vault)), userCollateral, "Wrong collateral vault balance after warp");

        uint collateralVaultBalance = alice_collateral_vault.balanceOf(address(alice_collateral_vault));

        // ensure no one else can withdraw from alice's collateral vault
        vm.startPrank(bob);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_collateral_vault.withdraw(collateralVaultBalance, alice);
        vm.stopPrank();

        vm.startPrank(alice);

        // reserve assets from intermediate vault
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.withdraw, (userCollateral, alice))
        });

        evc.batch(items);
        vm.stopPrank();

        assertEq(IERC20(collateralAssets).balanceOf(address(alice_collateral_vault)), 0,
            "Wrong collateral balance after warp and withdraw"
        );
    }

    // Test the user withdrawing WETH from the collateral vault
    function e_redeemUnderlying(address collateralAssets) public noGasMetering {
        e_collateralDepositWithoutBorrow(collateralAssets, 0.9e4);

        // Confirm redeemUnderlying cannot be called by anyone
        vm.startPrank(bob);

        // Bob cannot call redeemUnderlying with a zero amount
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_collateral_vault.redeemUnderlying(0, bob);
        // Bob cannot call redeemUnderlying with a non-zero amount
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_collateral_vault.redeemUnderlying(1, bob);
        // Bob cannot call redeemUnderlying even with alice as receiver
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_collateral_vault.redeemUnderlying(1, alice);

        vm.stopPrank();

        // alice can use redeemUnderlying though
        vm.startPrank(alice);

        uint256 snapshot = vm.snapshotState();
        uint maxRedeem = IERC20(alice_collateral_vault.asset()).balanceOf(address(alice_collateral_vault)) - alice_collateral_vault.maxRelease();

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.redeemUnderlying, (maxRedeem, alice))
        });

        evc.batch(items);

        assertEq(alice_collateral_vault.totalAssetsDepositedOrReserved(), 0);
        assertEq(alice_collateral_vault.maxRelease(), 0);

        vm.revertToState(snapshot);

        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.redeemUnderlying, (type(uint).max, alice))
        });

        evc.batch(items);

        assertEq(alice_collateral_vault.totalAssetsDepositedOrReserved(), 0);
        assertEq(alice_collateral_vault.maxRelease(), 0);
        vm.stopPrank();
    }

    function e_firstBorrowFromEulerDirect(address collateralAssets) public noGasMetering {
        e_collateralDepositWithoutBorrow(collateralAssets, 0.9e4);

        uint256 aliceBalanceBefore = IERC20(USDC).balanceOf(alice);

        vm.startPrank(alice);

        alice_collateral_vault.borrow(BORROW_USD_AMOUNT, alice);

        // borrower got target asset
        assertEq(
            IERC20(USDC).balanceOf(alice) - aliceBalanceBefore,
            BORROW_USD_AMOUNT,
            "Borrower not holding correct target assets"
        );
        // alice_collateral_vault holds the Euler debt
        assertEq(
            alice_collateral_vault.maxRepay(),
            BORROW_USD_AMOUNT,
            "collateral vault holding incorrect Euler debt"
        );
    }

    // Collateral vault borrows from the external protocol
    function e_firstBorrowFromEulerViaCollateral(address collateralAssets) public noGasMetering {
        e_createCollateralVault(collateralAssets, 0.9e4);

        // START DEBUG BLOCK
        // console2.log("COLLATERAL_AMOUNT", COLLATERAL_AMOUNT);
        // console2.log("BORROW_USD_AMOUNT", BORROW_USD_AMOUNT);
        // END DEBUG BLOCK

        vm.startPrank(alice);
        IERC20(collateralAssets).approve(address(alice_collateral_vault), type(uint256).max);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        // reserve assets from intermediate vault
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.deposit, (COLLATERAL_AMOUNT))
        });
        // borrow target asset
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.borrow, (BORROW_USD_AMOUNT, alice)) // note 115_000 is a price dependent value. Should be near max LTV
        });

        evc.batch(items);
    }

    // Separate the checks that are run after the borrow operation so that they are only run once
    // instead of running on every test that runs the borrow test first
    function e_postBorrowChecks(address collateralAssets) public {
        e_firstBorrowFromEulerViaCollateral(collateralAssets);

        // alice_collateral_vault has eulerWETH collateral
        assertEq(alice_collateral_vault.balanceOf(address(alice_collateral_vault)), COLLATERAL_AMOUNT);

        // borrower got target asset
        assertEq(
            IERC20(USDC).balanceOf(alice) - INITIAL_DEALT_ERC20,
            BORROW_USD_AMOUNT,
            "Borrower not holding correct target assets"
        );
        // alice_collateral_vault holds the Euler debt
        assertEq(
            alice_collateral_vault.maxRepay(),
            BORROW_USD_AMOUNT,
            "collateral vault holding incorrect Euler debt"
        );
    }

    // Try max borrowing from the external protocol. This imitates the frontend's max borrow option
    function e_maxBorrowFromEulerDirect(address collateralAssets, uint16 collateralMultiplier) public noGasMetering {
        vm.assume(collateralMultiplier <= MAXFACTOR);
        vm.assume(collateralMultiplier > 0);
        e_createCollateralVault(collateralAssets, 0.9e4);

        // Adjust COLLATERAL_AMOUNT by a random multiplier value
        COLLATERAL_AMOUNT *= collateralMultiplier;
        COLLATERAL_AMOUNT /= MAXFACTOR;

        uint snapshot = vm.snapshotState();
        vm.startPrank(admin);
        twyneVaultManager.setExternalLiqBuffer(collateralAssets, 0.95e4);
        vm.stopPrank();

        vm.startPrank(alice);

        IERC20(collateralAssets).approve(address(alice_collateral_vault), type(uint256).max);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        // reserve assets from intermediate vault
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.deposit, COLLATERAL_AMOUNT)
        });
        evc.batch(items);

        // Use the first liquidation condition in _canLiquidate
        (uint256 externalCollateralValueScaledByLiqLTV, ) = IEVault(alice_collateral_vault.targetVault()).accountLiquidity(address(alice_collateral_vault), true);
        uint256 borrowAmountUSD = uint256(twyneVaultManager.externalLiqBuffers(alice_collateral_vault.asset())) * externalCollateralValueScaledByLiqLTV / MAXFACTOR;

        uint USDCPrice = eulerOnChain.getQuote(1, USDC, USD); // returns a value times 1e10
        uint borrowAmountUSDC = borrowAmountUSD / USDCPrice;

        alice_collateral_vault.borrow(borrowAmountUSDC, alice);

        vm.expectRevert(TwyneErrors.VaultStatusLiquidatable.selector);
        alice_collateral_vault.borrow(1, alice);
        vm.stopPrank();

        vm.revertToState(snapshot);

        vm.startPrank(admin);
        twyneVaultManager.setExternalLiqBuffer(collateralAssets, 1e4);
        vm.stopPrank();

        vm.startPrank(alice);

        IERC20(collateralAssets).approve(address(alice_collateral_vault), type(uint256).max);

        // reserve assets from intermediate vault
        evc.batch(items);

        // Use the second liquidation condition in _canLiquidate
        (externalCollateralValueScaledByLiqLTV, ) = IEVault(alice_collateral_vault.targetVault()).accountLiquidity(address(alice_collateral_vault), true);
        borrowAmountUSD = eulerOnChain.getQuote(
            alice_collateral_vault.totalAssetsDepositedOrReserved() * uint(IEVault(eulerUSDC).LTVBorrow(collateralAssets)) / MAXFACTOR,
            collateralAssets,
            USD
        );

        borrowAmountUSDC = borrowAmountUSD / USDCPrice;

        alice_collateral_vault.borrow(borrowAmountUSDC, alice);

        vm.expectRevert(Errors.E_AccountLiquidity.selector);
        alice_collateral_vault.borrow(1, alice);
        vm.stopPrank();
    }

    // User wishes to close their collateral vault position by repaying all and withdrawing all
    function e_repayWithdrawAll(address collateralAssets) public noGasMetering {
        e_firstBorrowFromEulerDirect(collateralAssets);

        vm.startPrank(alice);
        // now repay the USDC to the target vault and withdraw
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint256).max);
        assertEq(IERC20(USDC).allowance(alice, address(alice_collateral_vault)), type(uint256).max);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // repay debt to Euler
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.repay, (BORROW_USD_AMOUNT))
        });

        // and now in eaUSDC vault
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.withdraw, (alice_collateral_vault.balanceOf(address(alice_collateral_vault)), alice))
        });

        evc.batch(items);

        // collateral vault has no debt in Euler USDC
        assertEq(alice_collateral_vault.maxRepay(), 0, "maxRepay is not zero");
        // collateral vault has no debt from intermediate vault
        assertEq(alice_collateral_vault.maxRelease(), 0, "maxRelease is not zero");

        vm.stopPrank();

        assertEq(IERC20(collateralAssets).balanceOf(address(alice_collateral_vault)), 0, "Incorrect eulerWETH balance remaining in vault");
        // alice balance is restored to the dealt amount
    }

    // User Permit2 to repay all
    function e_permit2FirstRepay(address collateralAssets) public noGasMetering {
        e_firstBorrowFromEulerDirect(collateralAssets);

        vm.startPrank(alice);
        // now repay USDC to the collateral vault, which will forward the funds to Euler
        IERC20(USDC).approve(permit2, type(uint).max);
        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: USDC,
                amount: uint160(BORROW_USD_AMOUNT),
                expiration: type(uint48).max,
                nonce: 0
            }),
            spender: address(alice_collateral_vault),
            sigDeadline: type(uint256).max
        });
        Permit2ECDSASigner permit2Signer = new Permit2ECDSASigner(address(permit2));

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);

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
            data: abi.encodeCall(alice_collateral_vault.repay, (BORROW_USD_AMOUNT))
        });
        items[2] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.withdraw, (alice_collateral_vault.balanceOf(address(alice_collateral_vault)), alice))
        });

        evc.batch(items);
        vm.stopPrank();

        // collateral vault has no debt in Euler USDC
        assertEq(alice_collateral_vault.maxRepay(), 0);
        // collateral vault has no debt from intermediate vault
        assertEq(alice_collateral_vault.maxRelease(), 0);

        // 1 wei of value is stuck in collateral vault
        assertEq(alice_collateral_vault.balanceOf(address(alice_collateral_vault)), 0, "incorrect alice balance");
        assertEq(IERC20(collateralAssets).balanceOf(address(alice_collateral_vault)), 0, "Incorrect eulerWETH balance remaining in vault");
        // alice WSTETH balance is restored to the dealt amount
        assertApproxEqRel(IERC20(collateralAssets).balanceOf(alice), IEVault(collateralAssets).convertToShares(INITIAL_DEALT_ETOKEN), 1, "wstETH balance is not the original amount");
    }

    // TODO add fuzzing to this type of test with interest accrual
    function e_interestAccrualThenRepay(address collateralAssets) public noGasMetering {
        e_firstBorrowFromEulerDirect(collateralAssets);

        // alice_collateral_vault holds the Euler debt
        uint originalMaxRelease = alice_collateral_vault.maxRelease();
        assertEq(alice_collateral_vault.maxRepay(), BORROW_USD_AMOUNT, "collateral vault holding incorrect Euler debt");

        // Move forward in time to observe increase in debts
        uint256 blockIncrement = 1000;
        vm.roll(block.number + blockIncrement);
        vm.warp(block.timestamp + 12);

        // borrower has MORE debt in eUSDC
        assertGt(alice_collateral_vault.maxRelease(), originalMaxRelease, "borrow should have more debt than before");
        // collateral vault now has MORE debt in eUSDC
        assertGt(alice_collateral_vault.maxRepay(), BORROW_USD_AMOUNT, "2");

        // now repay - first Euler debt, then withdraw all
        vm.startPrank(alice);
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint256).max);
        IERC20(collateralAssets).approve(address(alice_collateral_vault), type(uint256).max);
        assertEq(IERC20(USDC).allowance(alice, address(alice_collateral_vault)), type(uint256).max);

        // repay debt to Euler
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.repay, (type(uint256).max))
        });
        evc.batch(items);

        // withdraw all assets
        IEVC.BatchItem[] memory newItems = new IEVC.BatchItem[](1);
        newItems[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.withdraw, (type(uint).max, alice))
        });

        deal(USDC, address(alice_collateral_vault), INITIAL_DEALT_ERC20); // minting USDC to alice to account for interest accrual
        evc.batch(newItems);
        vm.stopPrank();

        // collateral vault has no debt in Euler USDC
        assertEq(alice_collateral_vault.maxRepay(), 0);
        // borrower alice has no debt from intermediate vault
        assertEq(alice_collateral_vault.maxRelease(), 0);
        assertEq(alice_collateral_vault.balanceOf(address(alice_collateral_vault)), 0);
        assertEq(IERC20(collateralAssets).balanceOf(address(alice_collateral_vault)), 0, "Incorrect eulerWETH balance remaining in vault");

        // alice eulerWETH balance is restored to nearly the dealt amount, minus debt interest accumulation
        // assertEq(IERC20(eulerWETH).balanceOf(alice), IEVault(eulerWETH).convertToShares(INITIAL_DEALT_ETOKEN));
    }

    function e_secondBorrow(address collateralAssets) public noGasMetering {
        // Test case: 2nd user borrows from the same intermediate vault
        // Verify case of 2 user vaults works smoothly

        e_firstBorrowFromEulerDirect(collateralAssets);

        // Bob creates vault
        vm.startPrank(bob);
        EulerCollateralVault bob_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _asset: collateralAssets,
                _targetVault: eulerUSDC,
                _liqLTV: twyneLiqLTV
            })
        );

        // Bob deposits collateralAssets collateral
        IERC20(collateralAssets).approve(address(bob_collateral_vault), type(uint256).max);

        uint256 reservedAmount = getReservedAssets(COLLATERAL_AMOUNT, bob_collateral_vault);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        // reserve assets from intermediate vault
        items[0] = IEVC.BatchItem({
            targetContract: address(bob_collateral_vault),
            onBehalfOfAccount: bob,
            value: 0,
            data: abi.encodeCall(bob_collateral_vault.deposit, (COLLATERAL_AMOUNT))
        });

        evc.batch(items);

        // confirm correct asset balances
        assertEq(IERC20(collateralAssets).balanceOf(address(bob_collateral_vault)), COLLATERAL_AMOUNT+reservedAmount);
        assertEq(bob_collateral_vault.balanceOf(address(bob_collateral_vault)), COLLATERAL_AMOUNT);

        bob_collateral_vault.borrow(BORROW_USD_AMOUNT, bob);

        // borrower has debt from intermediate vault
        assertEq(bob_collateral_vault.maxRelease(), reservedAmount, "1");
        // collateral vault has debt in euler USDC
        assertEq(bob_collateral_vault.maxRepay(), BORROW_USD_AMOUNT, "2");

        // TODO could add warp and repay steps to verify logic of interest accumulation
    }

    // user sets their custom LTV before borrowing
    function e_setTwyneLiqLTVNoBorrow(address collateralAssets) public noGasMetering {
        e_createCollateralVault(collateralAssets, 0.9e4);

        vm.startPrank(alice);
        // Toggle LTV before any borrows exist
        alice_collateral_vault.setTwyneLiqLTV(twyneVaultManager.maxTwyneLTVs(alice_collateral_vault.asset()));
        vm.stopPrank();
    }

    // user sets their custom LTV after borrowing
    function e_setTwyneLiqLTVWithBorrow(address collateralAssets) public noGasMetering {
        e_firstBorrowFromEulerViaCollateral(collateralAssets);

        // Toggle LTV now that borrows exist
        vm.startPrank(alice);

        // Twyne's liquidation LTV should be in (0, 1) range
        vm.expectRevert(TwyneErrors.ValueOutOfRange.selector);
        alice_collateral_vault.setTwyneLiqLTV(0);
        vm.expectRevert(TwyneErrors.ValueOutOfRange.selector);
        alice_collateral_vault.setTwyneLiqLTV(1e4);

        uint16 cachedMaxTwyneLTV = twyneVaultManager.maxTwyneLTVs(alice_collateral_vault.asset());
        alice_collateral_vault.setTwyneLiqLTV(cachedMaxTwyneLTV - 200);
        alice_collateral_vault.setTwyneLiqLTV(cachedMaxTwyneLTV - 400);
        alice_collateral_vault.setTwyneLiqLTV(cachedMaxTwyneLTV);
        vm.stopPrank();
    }

    function e_teleportEulerPosition(address collateralAssets) public noGasMetering {
        e_creditDeposit(collateralAssets);

        IEVault intermediate_vault = IEVault(twyneVaultManager.getIntermediateVault(collateralAssets));

        uint C = 10 ether;
        uint B = 5000 * (10**6);

        // create a debt position on Euler for teleporter
        vm.startPrank(teleporter);
        // teleporter should only have 10 ether of eWETH for this test, to simulate moving the entire position to Twyne
        IERC20(collateralAssets).transfer(bob, IEVault(collateralAssets).balanceOf(teleporter) - C);

        IEVC eulerEVC = IEVC(IEVault(eulerUSDC).EVC());
        eulerEVC.enableController(teleporter, eulerUSDC);
        eulerEVC.enableCollateral(teleporter, collateralAssets);
        IEVault(eulerUSDC).borrow(B, teleporter);
        vm.stopPrank();

        assertEq(IEVault(eulerUSDC).debtOf(teleporter), B, "user debt not correct before teleport");

        // teleport position
        uint256 snapshot = vm.snapshotState();
        vm.startPrank(teleporter);
        EulerCollateralVault teleporter_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _asset: collateralAssets,
                _targetVault: eulerUSDC,
                _liqLTV: twyneLiqLTV
            })
        );
        vm.label(address(teleporter_collateral_vault), "teleporter_collateral_vault");
        assertEq(teleporter_collateral_vault.borrower(), teleporter, "teleporter is not the borrower");

        IEVault(collateralAssets).approve(address(teleporter_collateral_vault), C);
        uint C_LP = getReservedAssets(C, teleporter_collateral_vault);
        teleporter_collateral_vault.teleport(C, B, 0);
        vm.stopPrank();

        assertEq(IEVault(eulerUSDC).debtOf(teleporter), 0, "user debt not correct after teleport");
        assertEq(IEVault(collateralAssets).balanceOf(teleporter), 0, "user collateral not correct after teleport");
        assertEq(IEVault(eulerUSDC).debtOf(address(teleporter_collateral_vault)), B, "teleported debt not correct after teleport");
        assertEq(teleporter_collateral_vault.totalAssetsDepositedOrReserved(), C + C_LP);
        assertEq(teleporter_collateral_vault.balanceOf(address(teleporter_collateral_vault)), C);
        assertEq(intermediate_vault.debtOf(address(teleporter_collateral_vault)), C_LP);

        console2.log("------------------teleport 1 done------------------");

        vm.revertToState(snapshot);
        uint16 eulerUSDCLiqLTV = IEVault(eulerUSDC).LTVLiquidation(collateralAssets);
        uint safeLiqLTV_ext = uint(eulerUSDCLiqLTV) * uint(twyneVaultManager.externalLiqBuffers(collateralAssets)); // 1e8 precision

        // teleport position
        vm.startPrank(teleporter);
        teleporter_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _asset: collateralAssets,
                _targetVault: eulerUSDC,
                _liqLTV: safeLiqLTV_ext / MAXFACTOR
            })
        );
        vm.label(address(teleporter_collateral_vault), "teleporter_collateral_vault");
        assertEq(teleporter_collateral_vault.borrower(), teleporter, "teleporter is not the borrower");

        IEVault(collateralAssets).approve(address(teleporter_collateral_vault), C);
        C_LP = getReservedAssets(C, teleporter_collateral_vault);
        assertEq(C_LP, 0, "C_LP should be 0 when liqLTV_twyne == effective_liqLTV_euler");

        teleporter_collateral_vault.teleport(C, B, 0);
        vm.stopPrank();

        assertEq(IEVault(eulerUSDC).debtOf(teleporter), 0, "C_LP should be 0 when liqLTV_twyne == effective_liqLTV_euler");
        assertEq(IEVault(collateralAssets).balanceOf(teleporter), 0, "user collateral not correct after teleport");
        assertEq(IEVault(eulerUSDC).debtOf(address(teleporter_collateral_vault)), B, "teleported debt not correct after teleport");
        assertEq(teleporter_collateral_vault.totalAssetsDepositedOrReserved(), C + C_LP);
        assertEq(teleporter_collateral_vault.balanceOf(address(teleporter_collateral_vault)), C);
        assertEq(intermediate_vault.debtOf(address(teleporter_collateral_vault)), C_LP);
    }

    function e_depositUnderlyingToIntermediateVault(address collateralAssets) public {
        vm.assume(isValidCollateralAsset(collateralAssets));

        // Setup: create intermediate vault with deposits
        IEVault intermediateVault = IEVault(twyneVaultManager.getIntermediateVault(collateralAssets));
        address underlyingAsset = IEVault(collateralAssets).asset();

        uint256 depositAmount = 1e18;

        {
            uint8 decimals = IERC20(IEVault(collateralAssets).asset()).decimals();
            if (decimals < 18) {
                depositAmount /= (10 ** (18 - decimals));
            }
        }

        // Give alice underlying assets
        deal(underlyingAsset, alice, depositAmount);

        // Take snapshot before testing
        uint256 snapshot = vm.snapshotState();

        // TEST 1: Direct call with plain approval
        vm.startPrank(alice);

        // Set up plain ERC20 approval
        IERC20(underlyingAsset).approve(address(eulerWrapper), depositAmount);

        // Record balances before
        uint256 aliceUnderlyingBefore = IERC20(underlyingAsset).balanceOf(alice);
        uint256 aliceIntermediateSharesBefore = intermediateVault.balanceOf(alice);

        // Call the function directly
        uint256 sharesReceived = eulerWrapper.depositUnderlyingToIntermediateVault(
            intermediateVault,
            depositAmount
        );

        vm.stopPrank();

        // Verify results for direct call
        assertEq(IERC20(underlyingAsset).balanceOf(alice), aliceUnderlyingBefore - depositAmount, "Alice underlying balance incorrect");
        assertEq(intermediateVault.balanceOf(alice), aliceIntermediateSharesBefore + sharesReceived, "Alice intermediate shares incorrect");
        assertEq(IERC20(underlyingAsset).balanceOf(address(eulerWrapper)), 0, "Wrapper should not hold underlying");
        assertEq(IEVault(collateralAssets).balanceOf(address(eulerWrapper)), 0, "Wrapper should not hold euler shares");
        assertGt(sharesReceived, 0, "Should receive some shares");

        // Revert to snapshot for batch test
        vm.revertToState(snapshot);

        // TEST 2: Batch call with permit2
        vm.startPrank(alice);

        // First approve permit2 to spend the tokens
        IERC20(underlyingAsset).approve(permit2, type(uint256).max);

        // Create permit2 signature
        Permit2ECDSASigner permit2Signer = new Permit2ECDSASigner(address(permit2));
        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: underlyingAsset,
                amount: uint160(depositAmount),
                expiration: type(uint48).max,
                nonce: 0
            }),
            spender: address(eulerWrapper),
            sigDeadline: type(uint256).max
        });

        // Record balances before batch
        uint256 aliceUnderlyingBeforeBatch = IERC20(underlyingAsset).balanceOf(alice);
        uint256 aliceIntermediateSharesBeforeBatch = intermediateVault.balanceOf(alice);

        // Call the function through EVC batch with permit2
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // First item: permit2 permit
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

        // Second item: deposit function
        items[1] = IEVC.BatchItem({
            targetContract: address(eulerWrapper),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(
                eulerWrapper.depositUnderlyingToIntermediateVault,
                (intermediateVault, depositAmount)
            )
        });

        evc.batch(items);

        // Calculate sharesReceived by checking balance difference
        uint256 aliceIntermediateSharesAfterBatch = intermediateVault.balanceOf(alice);
        uint256 sharesReceivedBatch = aliceIntermediateSharesAfterBatch - aliceIntermediateSharesBeforeBatch;

        vm.stopPrank();

        // Verify results for batch call
        assertEq(IERC20(underlyingAsset).balanceOf(alice), aliceUnderlyingBeforeBatch - depositAmount, "Alice underlying balance incorrect in batch");
        assertEq(intermediateVault.balanceOf(alice), aliceIntermediateSharesBeforeBatch + sharesReceivedBatch, "Alice intermediate shares incorrect in batch");
        assertEq(IERC20(underlyingAsset).balanceOf(address(eulerWrapper)), 0, "Wrapper should not hold underlying in batch");
        assertEq(IEVault(collateralAssets).balanceOf(address(eulerWrapper)), 0, "Wrapper should not hold euler shares in batch");
        assertGt(sharesReceivedBatch, 0, "Should receive some shares in batch");

        // Both tests should yield the same amount of shares
        assertEq(sharesReceived, sharesReceivedBatch, "Direct and batch calls should yield same shares");
    }

    function e_depositETHToIntermediateVault(address collateralAssets) public {
        vm.assume(isValidCollateralAsset(collateralAssets));

        // Only test with WETH-based assets since ETH deposits only work with WETH
        address underlyingAsset = IEVault(collateralAssets).asset();

        uint256 ethDepositAmount = 1 ether;
        vm.deal(alice, ethDepositAmount);

        IEVault intermediateVault = IEVault(twyneVaultManager.getIntermediateVault(collateralAssets));

        if (underlyingAsset != WETH) {
            // Test that depositETHToIntermediateVault reverts when used with non-WETH underlying
            vm.expectRevert(TwyneErrors.OnlyWETH.selector);
            eulerWrapper.depositETHToIntermediateVault{value: 1e18}(intermediateVault);
            vm.stopPrank();
            return;
        }


        uint256 snapshot = vm.snapshotState();

        // TEST 1: Direct call
        vm.startPrank(alice);

        uint256 aliceETHBefore = alice.balance;
        uint256 aliceIntermediateSharesBefore = intermediateVault.balanceOf(alice);

        uint256 sharesReceived = eulerWrapper.depositETHToIntermediateVault{value: ethDepositAmount}(
            intermediateVault
        );

        vm.stopPrank();

        assertEq(alice.balance, aliceETHBefore - ethDepositAmount, "Alice ETH balance incorrect");
        assertEq(intermediateVault.balanceOf(alice), aliceIntermediateSharesBefore + sharesReceived, "Alice intermediate shares incorrect");
        assertEq(IERC20(WETH).balanceOf(address(eulerWrapper)), 0, "Wrapper should not hold WETH");
        assertEq(IEVault(collateralAssets).balanceOf(address(eulerWrapper)), 0, "Wrapper should not hold euler shares");
        assertEq(address(eulerWrapper).balance, 0, "Wrapper should not hold ETH");
        assertGt(sharesReceived, 0, "Should receive some shares");

        vm.revertToState(snapshot);

        // TEST 2: Batch call through EVC
        vm.startPrank(alice);

        uint256 aliceETHBeforeBatch = alice.balance;
        uint256 aliceIntermediateSharesBeforeBatch = intermediateVault.balanceOf(alice);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);

        // ETH deposit function
        items[0] = IEVC.BatchItem({
            targetContract: address(eulerWrapper),
            onBehalfOfAccount: alice,
            value: ethDepositAmount,
            data: abi.encodeCall(eulerWrapper.depositETHToIntermediateVault, (intermediateVault))
        });

        evc.batch{value: ethDepositAmount}(items);

        uint256 aliceIntermediateSharesAfterBatch = intermediateVault.balanceOf(alice);
        uint256 sharesReceivedBatch = aliceIntermediateSharesAfterBatch - aliceIntermediateSharesBeforeBatch;

        vm.stopPrank();

        // Verify results for batch call
        assertEq(alice.balance, aliceETHBeforeBatch - ethDepositAmount, "Alice ETH balance incorrect in batch");
        assertEq(intermediateVault.balanceOf(alice), aliceIntermediateSharesBeforeBatch + sharesReceivedBatch, "Alice intermediate shares incorrect in batch");
        assertEq(IERC20(WETH).balanceOf(address(eulerWrapper)), 0, "Wrapper should not hold WETH in batch");
        assertEq(IEVault(collateralAssets).balanceOf(address(eulerWrapper)), 0, "Wrapper should not hold euler shares in batch");
        assertEq(address(eulerWrapper).balance, 0, "Wrapper should not hold ETH in batch");
        assertGt(sharesReceivedBatch, 0, "Should receive some shares in batch");

        // Both tests should yield the same amount of shares
        assertEq(sharesReceived, sharesReceivedBatch, "Direct and batch calls should yield same shares");
    }

    // TODO Test the scenario where one user is a credit LP and a borrower at the same time

    // TODO Test the scenario where a fake intermediate vault is created
    // and the borrow from it causes near-instant liquidation for the user

    function e_skim(address collateralAssets) public noGasMetering {
        // Setup: Alice creates a collateral vault and deposits
        e_collateralDepositWithBorrow(collateralAssets);

        vm.startPrank(alice);

        // Initial state
        uint256 initialTotalAssets = alice_collateral_vault.totalAssetsDepositedOrReserved();
        uint256 initialVaultBalance = IERC20(collateralAssets).balanceOf(address(alice_collateral_vault));
        uint initialBorrow = alice_collateral_vault.maxRepay();
        uint256 aliceBalanceBefore = initialTotalAssets - alice_collateral_vault.maxRelease();

        // skim with no excess should be a noop
        assertEq(initialTotalAssets, initialVaultBalance, "Should start with matching totals");

        // Calling skim when there's no excess should not change anything
        alice_collateral_vault.skim();
        assertEq(alice_collateral_vault.totalAssetsDepositedOrReserved(), initialTotalAssets, "Skim with no excess should not change total");
        vm.stopPrank();

        // Someone airdrops tokens directly to the vault
        address airdropper = makeAddr("airdropper");
        dealEToken(collateralAssets, airdropper, 2 ether);

        uint256 airdropAmount = IERC20(collateralAssets).balanceOf(airdropper);

        // Bob transfers eTokens directly to the vault (simulating accidental transfer)
        vm.startPrank(airdropper);
        IERC20(collateralAssets).transfer(address(alice_collateral_vault), airdropAmount);
        vm.stopPrank();

        // Verify the vault now has extra tokens
        uint256 vaultBalanceAfterTransfer = IERC20(collateralAssets).balanceOf(address(alice_collateral_vault));
        assertEq(vaultBalanceAfterTransfer, initialVaultBalance + airdropAmount, "Vault should have extra tokens");
        assertEq(alice_collateral_vault.totalAssetsDepositedOrReserved(), initialTotalAssets, "totalAssets should not change yet");

        // Test: Only borrower can call skim
        vm.startPrank(airdropper);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_collateral_vault.skim();
        vm.stopPrank();

        // Test: Borrower calls skim through EVC
        vm.startPrank(alice);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.skim, ())
        });

        evc.batch(items);

        uint256 finalTotalAssets = alice_collateral_vault.totalAssetsDepositedOrReserved();
        uint256 finalVaultBalance = IERC20(collateralAssets).balanceOf(address(alice_collateral_vault));
        uint256 aliceBalanceAfter = finalTotalAssets - alice_collateral_vault.maxRelease();


        assertEq(finalTotalAssets, finalVaultBalance, "After skim: totalAssets should match vault balance");
        assertEq(alice_collateral_vault.maxRepay(), initialBorrow, "After skim: borrow amount shouldn't change");
        assertEq(aliceBalanceAfter - aliceBalanceBefore, airdropAmount, "After skim: borrower's collateral should increase by airdrop amout");

        vm.stopPrank();
    }
}
