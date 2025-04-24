// SPDX-License-Identifier: UNLICENSED

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

contract EulerTestNormalActions is OverCollateralizedTestBase {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_e_creditDeposit() public noGasMetering {
        // Bob deposits into eeWETH_intermediate_vault to earn boosted yield
        vm.startPrank(bob);
        IERC20(eulerWETH).approve(address(eeWETH_intermediate_vault), type(uint256).max);
        eeWETH_intermediate_vault.deposit(CREDIT_LP_AMOUNT, bob);
        vm.stopPrank();

        assertEq(eeWETH_intermediate_vault.totalAssets(), CREDIT_LP_AMOUNT, "Incorrect CREDIT_LP_AMOUNT deposited");
    }

    function test_e_createWETHCollateralVault() public noGasMetering {
        test_e_creditDeposit();

        // Alice creates eWETH collateral vault with USDC target asset
        vm.startPrank(alice);
        alice_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _asset: eulerWETH,
                _targetVault: eulerUSDC,
                _liqLTV: twyneLiqLTV
            })
        );
        vm.stopPrank();

        vm.label(address(alice_collateral_vault), "alice_collateral_vault");
    }

    function test_e_totalAssetsIntermediateVault() public noGasMetering {
        test_e_createWETHCollateralVault();
        // eve donates to collateral vault, ensure this doesn't increase its totalAssets
        vm.startPrank(eve);
        // balanceOf before and after the transfer of eWETH is unchanged
        assertEq(IEVault(eulerWETH).balanceOf(address(eeWETH_intermediate_vault)), eeWETH_intermediate_vault.totalAssets(), "totalAssets value mismatch before airdrop");
        assertEq(IEVault(eulerWETH).balanceOf(address(eeWETH_intermediate_vault)), CREDIT_LP_AMOUNT);
        IERC20(eulerWETH).transfer(address(eeWETH_intermediate_vault), CREDIT_LP_AMOUNT);
        assertEq(eeWETH_intermediate_vault.totalAssets(), CREDIT_LP_AMOUNT, "totalAssets value mismatch after airdrop 1");
        assertEq(IEVault(eulerWETH).balanceOf(address(eeWETH_intermediate_vault)), 2*CREDIT_LP_AMOUNT);

        // Would call skim() normally here, but this is blocked to prevent edge cases
        vm.expectRevert(TwyneErrors.T_OperationDisabled.selector);
        eeWETH_intermediate_vault.skim(CREDIT_LP_AMOUNT, eve);
        vm.stopPrank();
    }

    // Verify how totalAssets works with a donation attack (EVK ignore the amount)
    // This functionality could be disabled by setting the OP_SKIM opcode
    function test_e_totalAssetsCollateralVault() public noGasMetering {
        test_e_createWETHCollateralVault();
        // eve donates to collateral vault, ensure this doesn't increase its totalAssets
        vm.startPrank(eve);
        IERC20(eulerWETH).transfer(address(alice_collateral_vault), COLLATERAL_AMOUNT);
        vm.stopPrank();

        assertEq(alice_collateral_vault.totalAssetsDepositedOrReserved(), 0);
        assertEq(alice_collateral_vault.balanceOf(address(alice_collateral_vault)), 0);
        assertEq(
            IERC20(eulerWETH).balanceOf(address(alice_collateral_vault)),
            COLLATERAL_AMOUNT,
            "Collateral vault not holding correct eulerWETH balance"
        );
    }

    // Verify that the EVK supply cap works as expected (already handled by EVK tests, but let's demonstrate it here)
    function test_e_supplyCap_creditDeposit() public noGasMetering {
        vm.startPrank(address(eeWETH_intermediate_vault.governorAdmin()));
        eeWETH_intermediate_vault.setCaps(32018, 32018);
        vm.stopPrank();

        // Bob deposits into eeWETH_intermediate_vault to earn boosted yield
        vm.startPrank(bob);
        IERC20(eulerWETH).approve(address(eeWETH_intermediate_vault), type(uint256).max);
        // 5 ETH is the supply cap
        eeWETH_intermediate_vault.deposit(5 ether, bob);
        // but revert if any more is deposited
        vm.expectRevert(Errors.E_SupplyCapExceeded.selector);
        eeWETH_intermediate_vault.deposit(1 wei, bob);
        vm.stopPrank();
    }

    function test_e_second_creditDeposit() public noGasMetering {
        test_e_creditDeposit();
        // Bob deposits more into eeWETH_intermediate_vault to earn boosted yield
        vm.startPrank(bob);
        eeWETH_intermediate_vault.deposit(CREDIT_LP_AMOUNT, bob);

        // Confirm complete withdrawal from intermediate vault works
        assertApproxEqRel(eeWETH_intermediate_vault.totalAssets(), 2 * CREDIT_LP_AMOUNT, 1e5);
        eeWETH_intermediate_vault.withdraw(2 * CREDIT_LP_AMOUNT, bob, bob);
        vm.stopPrank();
    }

    // credit LP withdraws their deposit in the intermediate vault
    // 100% can be withdrawn if there is no reserved assets in any collateral vault
    function test_e_creditWithdrawNoInterest() public noGasMetering {
        test_e_creditDeposit();

        assertEq(eeWETH_intermediate_vault.totalAssets(), CREDIT_LP_AMOUNT, "totalAssets isn't the expected value");
        assertEq(eeWETH_intermediate_vault.balanceOf(bob), CREDIT_LP_AMOUNT, "bob has wrong balance");

        // Credit LP Bob withdraws all
        vm.startPrank(bob);
        IERC20(eulerWETH).approve(address(eeWETH_intermediate_vault), type(uint256).max);
        eeWETH_intermediate_vault.withdraw(CREDIT_LP_AMOUNT, bob, bob);
        vm.stopPrank();

        assertEq(eeWETH_intermediate_vault.totalAssets(), 0);
    }

    // Test the case of B = 0 (no borrowed assets from the external protocol) with non-zero C and C_LP
    function test_e_collateralDepositWithoutBorrow() public noGasMetering {
        test_e_createWETHCollateralVault();

        vm.startPrank(alice);
        assertEq(alice_collateral_vault.borrower(), alice);
        assertEq(collateralVaultFactory.getCollateralVaults(alice)[0], address(alice_collateral_vault));

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

        vm.startPrank(bob);
        IERC20(WETH).approve(address(alice_collateral_vault), type(uint).max);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_collateral_vault.depositUnderlying(COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    // credit LP withdraws their deposit in the intermediate vault
    // 100% can be withdrawn if there is no reserved assets in any collateral vault
    function test_e_creditWithdrawWithInterestAndNoFees() public noGasMetering {
        test_e_collateralDepositWithoutBorrow();

        // Confirm fees setup
        assertEq(eeWETH_intermediate_vault.interestFee(), 0, "Unexpected intermediate vault interest fee");
        assertEq(eeWETH_intermediate_vault.feeReceiver(), feeReceiver, "fee receiver address is wrong");
        assertEq(eeWETH_intermediate_vault.protocolFeeShare(), 0, "Unexpected intermediate vault interest fee");

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
        assertEq(IERC20(eulerWETH).balanceOf(address(alice_collateral_vault)), 0, "Incorrect eulerWETH balance remaining in vault");

        // Credit LP Bob withdraws all
        vm.startPrank(bob);
        eeWETH_intermediate_vault.redeem(type(uint).max, bob, bob);
        eeWETH_intermediate_vault.convertFees();
        vm.stopPrank();

        // Confirm zero accrued fees in intermediate vault
        assertEq(eeWETH_intermediate_vault.accumulatedFees(), 0, "Should have zero accumulated fees if fees are disabled");

        assertEq(eeWETH_intermediate_vault.totalSupply(), 0, "Intermediate vault is not empty as expected!");
        assertNotEq(eeWETH_intermediate_vault.totalAssets(), 0, "Awesome, no dust left in the contract at all. How did you do that?");
    }


    // credit LP withdraws their deposit in the intermediate vault
    // 100% can be withdrawn if there is no reserved assets in any collateral vault
    function test_e_creditWithdrawWithInterestAndFees() public noGasMetering {
        test_e_collateralDepositWithoutBorrow();

        // Set non-zero protocolConfig fee
        vm.startPrank(admin);
        protocolConfig.setInterestFeeRange(0.1e4, 1e4); // set fee range to zero
        protocolConfig.setProtocolFeeShare(0.5e4); // set fee to zero
        assertNotEq(eeWETH_intermediate_vault.protocolFeeShare(), 0, "Protocol fee should not be zero");
        vm.stopPrank();

        // Set non-zero governance fee
        vm.startPrank(eeWETH_intermediate_vault.governorAdmin());
        eeWETH_intermediate_vault.setFeeReceiver(feeReceiver);
        eeWETH_intermediate_vault.setInterestFee(0.1e4); // set non-zero governance fee
        assertEq(eeWETH_intermediate_vault.interestFee(), 0.1e4, "Unexpected intermediate vault interest rate");
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
        assertEq(IERC20(eulerWETH).balanceOf(address(alice_collateral_vault)), 0, "Incorrect eulerWETH balance remaining in vault");

        // Credit LP Bob withdraws all
        vm.startPrank(bob);
        eeWETH_intermediate_vault.redeem(type(uint).max, bob, bob);
        assertEq(eeWETH_intermediate_vault.totalSupply(), eeWETH_intermediate_vault.accumulatedFees(), "Remaining assets are not just fees!");
        vm.stopPrank();

        // Withdraw all the accrued fees to fully empty the intermediate vault
        vm.startPrank(feeReceiver);
        assertEq(eeWETH_intermediate_vault.feeReceiver(), feeReceiver, "Unexpected feeReceiver");
        // First, split the fees
        eeWETH_intermediate_vault.convertFees();
        // Withdraw the fees owed to fee receiver (AKA governor receiver)
        uint receiveFees = eeWETH_intermediate_vault.redeem(type(uint).max, feeReceiver, feeReceiver);
        assertNotEq(receiveFees, 0, "Received governor fees was zero?!");
        vm.stopPrank();

        vm.startPrank(protocolFeeReceiver);
        assertEq(eeWETH_intermediate_vault.protocolFeeReceiver(), protocolFeeReceiver, "Unexpected protocolFeeReceiver");
        // Withdraw the fees owed to protocolConfig feeReceiver
        receiveFees = eeWETH_intermediate_vault.redeem(type(uint).max, protocolFeeReceiver, protocolFeeReceiver);
        assertNotEq(receiveFees, 0, "Received protocolConfig fees was zero?!");
        vm.stopPrank();

        assertEq(eeWETH_intermediate_vault.totalSupply(), 0, "Intermediate vault is not empty as expected!");
        assertNotEq(eeWETH_intermediate_vault.totalAssets(), 0, "Awesome, no dust left in the contract at all. How did you do that?");
    }

    // Test the case of C_LP = 0 (no reserved assets) with non-zero C and B
    // This should be identical to using the underlying protocol without Twyne
    function test_e_collateralDepositWithBorrow() public noGasMetering {
        test_e_createWETHCollateralVault();

        uint aliceUSDCBalanceBefore = IERC20(USDC).balanceOf(alice);

        vm.startPrank(alice);
        assertEq(alice_collateral_vault.borrower(), alice);
        assertEq(collateralVaultFactory.getCollateralVaults(alice)[0], address(alice_collateral_vault));

        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint).max);

        // Deposit 1 eWETH, withdraw to the maxBorrow limit allowed by the external EVK vault
        uint256 oneEther = 1 ether;

        uint256 borrowAmountInETH = oneEther * uint(IEVault(eulerUSDC).LTVLiquidation(eulerWETH)) * uint(twyneVaultManager.externalLiqBuffers(alice_collateral_vault.asset())) / (MAXFACTOR * MAXFACTOR);

        // Some shared logic with test_e_maxBorrowFromEulerDirect()
        alice_collateral_vault.setTwyneLiqLTV(uint(IEVault(eulerUSDC).LTVLiquidation(eulerWETH)) * uint(twyneVaultManager.externalLiqBuffers(alice_collateral_vault.asset())) / MAXFACTOR);
        uint borrowValueInUSD = eulerOnChain.getQuote(borrowAmountInETH, eulerWETH, USD);
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
    function test_e_collateralDepositUnderlying() public noGasMetering {
        test_e_createWETHCollateralVault();

        vm.startPrank(alice);
        assertEq(alice_collateral_vault.borrower(), alice);
        assertEq(collateralVaultFactory.getCollateralVaults(alice)[0], address(alice_collateral_vault));

        IERC20(WETH).approve(address(alice_collateral_vault), type(uint).max);

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
    function test_e_permit2CollateralDeposit() public noGasMetering {
        test_e_creditDeposit();

        // repeat but for collateral non-EVK vault
        (address user, uint privKey) = makeAddrAndKey("permit2user");
        vm.startPrank(user);
        address user_collateral_vault = collateralVaultFactory.createCollateralVault({
                _asset: eulerWETH,
                _targetVault: eulerUSDC,
                _liqLTV: twyneLiqLTV
            }
        );

        vm.label(address(user_collateral_vault), "user_collateral_vault");
        deal(address(eulerWETH), user, INITIAL_DEALT_ETOKEN);

        IERC20(eulerWETH).approve(permit2, type(uint).max);
        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: eulerWETH,
                amount: uint160(COLLATERAL_AMOUNT),
                expiration: type(uint48).max,
                nonce: 0
            }),
            spender: user_collateral_vault,
            sigDeadline: type(uint256).max
        });

        uint256 reservedAmount = getReservedAssets(COLLATERAL_AMOUNT, 0, EulerCollateralVault(user_collateral_vault));

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

        uint eulerWETHBalance = IEVault(eulerWETH).balanceOf(user_collateral_vault);
        assertEq(eulerWETHBalance, COLLATERAL_AMOUNT + reservedAmount, "Permit2: Unexpected amount of eulerWETH in collateral vault");
    }

    // Test Permit2 deposit of WETH (not eWETH)
    function test_e_permit2_CollateralDepositUnderlying() public noGasMetering {
        test_e_creditDeposit();

        (address user, uint privKey) = makeAddrAndKey("permit2user");
        vm.startPrank(user);
        address user_collateral_vault = collateralVaultFactory.createCollateralVault({
                _asset: eulerWETH,
                _targetVault: eulerUSDC,
                _liqLTV: twyneLiqLTV
            }
        );

        vm.label(address(user_collateral_vault), "user_collateral_vault");

        deal(address(WETH), user, INITIAL_DEALT_ERC20);
        IERC20(WETH).approve(permit2, type(uint).max);
        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: WETH,
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
    function test_e_evcCanCreateCollateralVault() public noGasMetering {
        vm.startPrank(alice);
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(collateralVaultFactory),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(collateralVaultFactory.createCollateralVault, (eulerWETH, eulerUSDC, twyneLiqLTV))
        });
        (IEVC.BatchItemResult[] memory batchItemsResult,,) = evc.batchSimulation(items);
        address collateral_vault = address(uint160(uint(bytes32(batchItemsResult[0].result))));

        assertEq(collateral_vault.code.length, 0);

        evc.batch(items);
        vm.stopPrank();
        assertGt(collateral_vault.code.length, 0);

        assertEq(CollateralVaultBase(collateral_vault).borrower(), alice);
    }

    // TODO consider adding fuzzing to this test for different warp periods
    // TODO avoid mock oracle, vm.etch the timestamp into the official oracle
    // Test that if time passes, the balance of aTokens in the collateral vault increases and the user can withdraw all
    function test_e_withdrawCollateralAfterWarp() public noGasMetering {
        test_e_createWETHCollateralVault();

        vm.startPrank(alice);

        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint256).max);

        uint256 reservedAmount = getReservedAssets(COLLATERAL_AMOUNT, 0, alice_collateral_vault);

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
            IERC20(eulerWETH).balanceOf(address(alice_collateral_vault)), COLLATERAL_AMOUNT + reservedAmount, "Wrong collateral balance before warp");

        // warp forward, allows Euler balances to increase
        uint256 blockIncrement = 1000;
        vm.roll(block.number + blockIncrement);
        vm.warp(block.timestamp + 12);

        // uint warpedBalance = 50 ether + 0.005649890163242660 ether;
        assertEq(
            IERC20(eulerWETH).balanceOf(address(alice_collateral_vault)), COLLATERAL_AMOUNT + reservedAmount, "Wrong collateral balance after warp");
        assertGt(alice_collateral_vault.maxRelease(), 0, "Wrong release value after warp");
        uint userCollateral = COLLATERAL_AMOUNT - (alice_collateral_vault.maxRelease() - reservedAmount); // deposited collateral - (increase in debt to intermediate vault)
        assertEq(alice_collateral_vault.balanceOf(address(alice_collateral_vault)), userCollateral, "Wrong collateral vault balance after warp");

        uint collateralVaultBalance = alice_collateral_vault.balanceOf(address(alice_collateral_vault));

        // ensure no one else can withdraw from alice's collateral vault
        vm.startPrank(bob);
        vm.expectRevert();
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

        assertEq(IERC20(eulerWETH).balanceOf(address(alice_collateral_vault)), 0,
            "Wrong collateral balance after warp and withdraw"
        );
    }

    // Test the user withdrawing WETH from the collateral vault
    function test_e_redeemUnderlying() public noGasMetering {
        test_e_collateralDepositWithoutBorrow();

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

        uint maxRedeem = IERC20(alice_collateral_vault.asset()).balanceOf(address(alice_collateral_vault)) - alice_collateral_vault.maxRelease();

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.redeemUnderlying, (maxRedeem, alice))
        });

        evc.batch(items);

        vm.stopPrank();
    }

    function test_e_firstBorrowFromEulerDirect() public noGasMetering {
        test_e_collateralDepositWithoutBorrow();

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
    function test_e_firstBorrowFromEulerViaCollateral() public noGasMetering {
        test_e_createWETHCollateralVault();

        // START DEBUG BLOCK
        // console2.log("COLLATERAL_AMOUNT", COLLATERAL_AMOUNT);
        // console2.log("BORROW_USD_AMOUNT", BORROW_USD_AMOUNT);
        // END DEBUG BLOCK

        vm.startPrank(alice);
        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint256).max);

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
    function test_e_postBorrowChecks() public {
        test_e_firstBorrowFromEulerViaCollateral();

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

    // Try reserving the most assets possible
    // The OLD extreme case allowed C_LP = C - 1, but now that rebalance happens on deposit, this shouldn't be possible
    function test_e_maxReserveCase() public noGasMetering {
        test_e_createWETHCollateralVault();

        vm.startPrank(alice);

        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint256).max);
        // First, calculate and use max reserve assets from the intermediate vault
        uint borrowerCollateralAmount = 1 ether;

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        // reserve assets from intermediate vault
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.deposit, borrowerCollateralAmount)
        });
        evc.batch(items);
    }

    // Try max borrowing from the external protocol
    // This imitates the frontend
    // TODO add fuzzing to this test for different c, C_LP, and B amounts
    function test_e_maxBorrowFromEulerDirect() public noGasMetering {
        test_e_createWETHCollateralVault();

        vm.startPrank(alice);

        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint256).max);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        // reserve assets from intermediate vault
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_collateral_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_collateral_vault.deposit, COLLATERAL_AMOUNT)
        });
        evc.batch(items);

        // Second, calculate and use max borrow amount from external protocol
        uint totalAssets = IERC20(eulerWETH).balanceOf(address(alice_collateral_vault));

        // Need to use the Euler oracle because we are borrowing from Euler
        // Borrow the liquidation limit, which is: twyneLiquidationLTV * (vaultOwnedCollateralValue - internalBorrowDebtValue)
        uint maxBorrowValueUSD = eulerOnChain.getQuote(totalAssets - alice_collateral_vault.maxRelease(), eulerWETH, USD);
        uint USDCPrice = eulerOnChain.getQuote(1, USDC, USD); // returns a value times 1e10
        uint maxBorrowAmountUSDC = maxBorrowValueUSD / USDCPrice;
        maxBorrowAmountUSDC = (alice_collateral_vault.twyneLiqLTV() * maxBorrowAmountUSDC) / MAXFACTOR;
        assertNotEq(maxBorrowAmountUSDC, 0, "maxBorrowAmountUSDC is zero, revert");

        // Use the first liquidation condition, in the if statement
        (uint256 externalCollateralValueScaledByLiqLTV, ) = IEVault(alice_collateral_vault.targetVault()).accountLiquidity(address(alice_collateral_vault), true);
        uint256 borrowAmountUSDC = uint256(twyneVaultManager.externalLiqBuffers(alice_collateral_vault.asset())) * externalCollateralValueScaledByLiqLTV;

        alice_collateral_vault.borrow(borrowAmountUSDC/1e16, alice); // why 1e16? because it just works??

        vm.expectRevert(TwyneErrors.VaultStatusLiquidatable.selector);
        alice_collateral_vault.borrow(1, alice);
    }

    // User wishes to close their collateral vault position by repaying all and withdrawing all
    function test_e_repayWithdrawAll() public noGasMetering {
        test_e_firstBorrowFromEulerDirect();

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
        assertEq(alice_collateral_vault.maxRepay(), 0, "1");
        // collateral vault has no debt from intermediate vault
        assertEq(alice_collateral_vault.maxRelease(), 0, "2");

        vm.stopPrank();

        assertEq(IERC20(eulerWETH).balanceOf(address(alice_collateral_vault)), 0, "Incorrect eulerWETH balance remaining in vault");
        // alice WSTETH balance is restored to the dealt amount
        assertApproxEqRel(IERC20(eulerWETH).balanceOf(alice), IEVault(eulerWETH).convertToShares(INITIAL_DEALT_ETOKEN), 1, "wstETH balance is not the original amount");
    }

    // User Permit2 to repay all
    function test_e_permit2FirstRepay() public noGasMetering {
        test_e_firstBorrowFromEulerDirect();

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
        assertEq(IERC20(eulerWETH).balanceOf(address(alice_collateral_vault)), 0, "Incorrect eulerWETH balance remaining in vault");
        // alice WSTETH balance is restored to the dealt amount
        assertApproxEqRel(IERC20(eulerWETH).balanceOf(alice), IEVault(eulerWETH).convertToShares(INITIAL_DEALT_ETOKEN), 1, "wstETH balance is not the original amount");
    }

    // TODO add fuzzing to this type of test with interest accrual
    function test_e_interestAccrualThenRepay() external noGasMetering {
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

        // now repay - first Euler debt, then withdraw all
        vm.startPrank(alice);
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint256).max);
        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint256).max);
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
        assertEq(IERC20(eulerWETH).balanceOf(address(alice_collateral_vault)), 0, "Incorrect eulerWETH balance remaining in vault");

        // alice eulerWETH balance is restored to nearly the dealt amount, minus debt interest accumulation
        // assertEq(IERC20(eulerWETH).balanceOf(alice), IEVault(eulerWETH).convertToShares(INITIAL_DEALT_ETOKEN));
    }

    function test_e_secondBorrow() public noGasMetering {
        // Test case: 2nd user borrows from the same intermediate vault
        // Verify case of 2 user vaults works smoothly

        test_e_firstBorrowFromEulerDirect();

        // Laura creates vault
        vm.startPrank(laura);
        EulerCollateralVault tETH_laura_vault = EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _asset: eulerWETH,
                _targetVault: eulerUSDC,
                _liqLTV: twyneLiqLTV
            })
        );

        // Laura deposits WSOL collateral
        IERC20(eulerWETH).approve(address(tETH_laura_vault), type(uint256).max);

        uint256 reservedAmount = getReservedAssets(COLLATERAL_AMOUNT, 0, tETH_laura_vault);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        // reserve assets from intermediate vault
        items[0] = IEVC.BatchItem({
            targetContract: address(tETH_laura_vault),
            onBehalfOfAccount: laura,
            value: 0,
            data: abi.encodeCall(tETH_laura_vault.deposit, (COLLATERAL_AMOUNT))
        });

        evc.batch(items);

        // confirm correct asset balances
        assertEq(IERC20(eulerWETH).balanceOf(address(tETH_laura_vault)), COLLATERAL_AMOUNT+reservedAmount);
        assertEq(tETH_laura_vault.balanceOf(address(tETH_laura_vault)), COLLATERAL_AMOUNT);

        tETH_laura_vault.borrow(BORROW_USD_AMOUNT, laura);

        // borrower has debt from intermediate vault
        assertEq(tETH_laura_vault.maxRelease(), reservedAmount, "1");
        // collateral vault has debt in euler USDC
        assertEq(tETH_laura_vault.maxRepay(), BORROW_USD_AMOUNT, "2");

        // TODO could add warp and repay steps to verify logic of interest accumulation
    }

    // user sets their custom LTV before borrowing
    function test_e_setTwyneLiqLTVNoBorrow() public noGasMetering {
        test_e_createWETHCollateralVault();

        vm.startPrank(alice);
        // Toggle LTV before any borrows exist
        alice_collateral_vault.setTwyneLiqLTV(twyneVaultManager.maxTwyneLTVs(alice_collateral_vault.asset()));
        vm.stopPrank();
    }

    // user sets their custom LTV after borrowing
    function test_e_setTwyneLiqLTVWithBorrow() public noGasMetering {
        test_e_firstBorrowFromEulerViaCollateral();

        // Toggle LTV now that borrows exist
        vm.startPrank(alice);

        // Twyne's liquidation LTV should be in (0, 1) range
        vm.expectRevert(TwyneErrors.ValueOutOfRange.selector);
        alice_collateral_vault.setTwyneLiqLTV(0);
        vm.expectRevert(TwyneErrors.ValueOutOfRange.selector);
        alice_collateral_vault.setTwyneLiqLTV(1e4);

        uint16 cachedMaxTwyneLTV = twyneVaultManager.maxTwyneLTVs(alice_collateral_vault.asset());
        alice_collateral_vault.setTwyneLiqLTV(cachedMaxTwyneLTV - 800);
        alice_collateral_vault.setTwyneLiqLTV(cachedMaxTwyneLTV - 400);
        alice_collateral_vault.setTwyneLiqLTV(cachedMaxTwyneLTV);
        vm.stopPrank();
    }

    function test_e_teleportEulerPosition() public {
        test_e_creditDeposit();

        uint C = IERC20(eulerWETH).balanceOf(teleporter);
        uint B = 5000 * (10**6);

        // create a debt position on Euler for teleporter
        vm.startPrank(teleporter);
        IEVC eulerEVC = IEVC(IEVault(eulerUSDC).EVC());
        eulerEVC.enableController(teleporter, eulerUSDC);
        eulerEVC.enableCollateral(teleporter, eulerWETH);
        IEVault(eulerUSDC).borrow(B, teleporter);
        vm.stopPrank();

        assertEq(IEVault(eulerUSDC).debtOf(teleporter), B, "user debt not correct before teleport");

        // teleport position
        uint256 snapshot = vm.snapshotState();
        vm.startPrank(teleporter);
        EulerCollateralVault teleporter_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _asset: eulerWETH,
                _targetVault: eulerUSDC,
                _liqLTV: twyneLiqLTV
            })
        );
        vm.label(address(teleporter_collateral_vault), "teleporter_collateral_vault");
        assertEq(teleporter_collateral_vault.borrower(), teleporter, "teleporter is not the borrower");

        IEVault(eulerWETH).approve(address(teleporter_collateral_vault), C);
        uint C_LP = getReservedAssets(C, B, teleporter_collateral_vault);
        teleporter_collateral_vault.teleport(C, B);
        vm.stopPrank();

        assertEq(IEVault(eulerUSDC).debtOf(teleporter), 0, "user debt not correct after teleport");
        assertEq(IEVault(eulerWETH).balanceOf(teleporter), 0, "user collateral not correct after teleport");
        assertEq(IEVault(eulerUSDC).debtOf(address(teleporter_collateral_vault)), B, "teleported debt not correct after teleport");
        assertEq(teleporter_collateral_vault.totalAssetsDepositedOrReserved(), C + C_LP);
        assertEq(teleporter_collateral_vault.balanceOf(address(teleporter_collateral_vault)), C);
        assertEq(eeWETH_intermediate_vault.debtOf(address(teleporter_collateral_vault)), C_LP);

        console2.log("------------------teleport 1 done------------------");

        vm.revertToState(snapshot);
        uint16 eulerUSDCLiqLTV = IEVault(eulerUSDC).LTVLiquidation(eulerWETH);
        uint safeLiqLTV_ext = uint(eulerUSDCLiqLTV) * uint(twyneVaultManager.externalLiqBuffers(eulerWETH)); // 1e8 precision

        // teleport position
        vm.startPrank(teleporter);
        teleporter_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _asset: eulerWETH,
                _targetVault: eulerUSDC,
                _liqLTV: safeLiqLTV_ext / MAXFACTOR
            })
        );
        vm.label(address(teleporter_collateral_vault), "teleporter_collateral_vault");
        assertEq(teleporter_collateral_vault.borrower(), teleporter, "teleporter is not the borrower");

        IEVault(eulerWETH).approve(address(teleporter_collateral_vault), C);
        C_LP = getReservedAssets(C, B, teleporter_collateral_vault);
        assertEq(C_LP, 0, "C_LP should be 0 when liqLTV_twyne == effective_liqLTV_euler");

        teleporter_collateral_vault.teleport(C, B);
        vm.stopPrank();

        assertEq(IEVault(eulerUSDC).debtOf(teleporter), 0, "C_LP should be 0 when liqLTV_twyne == effective_liqLTV_euler");
        assertEq(IEVault(eulerWETH).balanceOf(teleporter), 0, "user collateral not correct after teleport");
        assertEq(IEVault(eulerUSDC).debtOf(address(teleporter_collateral_vault)), B, "teleported debt not correct after teleport");
        assertEq(teleporter_collateral_vault.totalAssetsDepositedOrReserved(), C + C_LP);
        assertEq(teleporter_collateral_vault.balanceOf(address(teleporter_collateral_vault)), C);
        assertEq(eeWETH_intermediate_vault.debtOf(address(teleporter_collateral_vault)), C_LP);
    }

    // TODO Test the scenario where one user is a credit LP and a borrower at the same time

    // TODO Test the scenario where a fake intermediate vault is created
    // and the borrow from it causes near-instant liquidation for the user
}
