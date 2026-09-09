// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {MainnetBase, console2} from "../MainnetBase.t.sol";
import {BridgeHookTarget} from "src/TwyneFactory/BridgeHookTarget.sol";
import "euler-vault-kit/EVault/shared/types/Types.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {MorphoCollateralVault, CollateralVaultBase} from "src/twyne/MorphoCollateralVault.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {Errors} from "euler-vault-kit/EVault/shared/Errors.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Permit2ECDSASigner} from "euler-vault-kit/../test/mocks/Permit2ECDSASigner.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {SafeERC20Lib} from "euler-vault-kit/EVault/shared/lib/SafeERC20Lib.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IRMTwyneCurve} from "src/twyne/IRMTwyneCurve.sol";
import {IMorpho, MarketParams, Id, Market} from "morpho/interfaces/IMorpho.sol";
import {IOracle} from "morpho/interfaces/IOracle.sol";
import {MarketParamsLib} from "morpho/libraries/MarketParamsLib.sol";
import {MorphoLib} from "morpho/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "morpho/libraries/periphery/MorphoBalancesLib.sol";
import {ORACLE_PRICE_SCALE} from "morpho/libraries/ConstantsLib.sol";
import {MathLib} from "morpho/libraries/MathLib.sol";

contract MorphoTestBase is MainnetBase {
    using MathLib for uint;

    MorphoCollateralVault alice_morpho_vault;
    MorphoCollateralVault bob_morpho_vault;
    IEVault morpho_intermediate_vault;

    // Morpho market parameters
    address constant MO_COLLATERAL_TOKEN = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0; // WSTETH
    address constant MO_LOAN_TOKEN = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
    address constant MO_ORACLE = 0xbD60A6770b27E084E8617335ddE769241B0e71D8;
    address constant MO_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 constant MO_LLTV = 965000000000000000; // 96.5%

    MarketParams morphoMarketParams;
    Id morphoMarketId;

    uint256 BORROW_WETH_AMOUNT;

    function setUp() public virtual override {
        forkBlock = 23600528;
        forkBlockDiff = block.number - forkBlock;

        vm.rollFork(forkBlock);

        super.setUp();

        // Set up Morpho market parameters
        morphoMarketParams = MarketParams({
            loanToken: MO_LOAN_TOKEN,
            collateralToken: MO_COLLATERAL_TOKEN,
            oracle: MO_ORACLE,
            irm: MO_IRM,
            lltv: MO_LLTV
        });
        morphoMarketId = MarketParamsLib.id(morphoMarketParams);

        // Deploy MorphoCollateralVault implementation
        address morphoCollateralVaultImpl = address(new MorphoCollateralVault(address(evc), morpho));

        vm.startPrank(admin);
        collateralVaultFactory.setBeacon(morpho, address(new UpgradeableBeacon(morphoCollateralVaultImpl, admin)));

        // Create Euler router for Morpho
        oracleRouter = new EulerRouter(address(evc), address(twyneVaultManager));
        vm.label(address(oracleRouter), "morphoOracleRouter");

        collateralVaultFactory.setVaultManager(address(twyneVaultManager));

        // Configure LTV settings
        // For Morpho WSTETH/WETH market, LLTV is 96.5% (9650 in 1e4)
        // We use a 98% buffer so that minLTV = 9650 * 0.98 = 9457
        // This allows twyneLiqLTV to be set higher than external LTV to provide the Twyne "boost"
        externalLiqBufferInitial = 0.99e4; // 98% buffer
        maxLTVInitial = 0.99e4; // 99% - matches Morpho LLTV
        // twyneLiqLTV must be >= 9900 * 9900 / 10000 = 9801
        twyneLiqLTV = 9800; // Set to max allowed
        require(twyneLiqLTV <= maxLTVInitial, "twyneLiqLTV is not set properly");

        // Morpho intermediate vaults are self-denominated to support multiple loan markets.
        morpho_intermediate_vault = newIntermediateVaultForMorpho(MO_COLLATERAL_TOKEN, address(oracleRouter), MO_COLLATERAL_TOKEN);
        vm.label(address(morpho_intermediate_vault), "WSTETH intermediate vault");

        twyneVaultManager.setMaxLiquidationLTV(address(morpho_intermediate_vault), MO_LOAN_TOKEN, maxLTVInitial, 0);
        twyneVaultManager.setExternalLiqBuffer(address(morpho_intermediate_vault), MO_LOAN_TOKEN, externalLiqBufferInitial, 0);

        // Set supported Morpho market
        twyneVaultManager.setAllowedMorphoMarket(morpho, address(morpho_intermediate_vault), morphoMarketId, true);

        vm.stopPrank();

        // Set fixture arrays
        fixtureCollateralAssets = [MO_COLLATERAL_TOKEN];
        fixtureTargetAssets = [MO_LOAN_TOKEN];

        // Labels
        vm.label(MO_COLLATERAL_TOKEN, "WSTETH");
        vm.label(MO_LOAN_TOKEN, "WETH");
        vm.label(morpho, "Morpho");
        vm.label(MO_ORACLE, "MorphoOracle");
        vm.label(MO_IRM, "MorphoIRM");

        address[5] memory characters = [alice, bob, eve, liquidator, teleporter];

        // Deal tokens to all test characters
        for (uint charIndex; charIndex < characters.length; charIndex++) {
            vm.deal(characters[charIndex], 10 ether);
            // Deal collateral token (WSTETH)
            deal(MO_COLLATERAL_TOKEN, characters[charIndex], INITIAL_DEALT_ERC20);
            // Deal loan token (WETH)
            deal(MO_LOAN_TOKEN, characters[charIndex], INITIAL_DEALT_ERC20);
        }

        // Calculate initial prices and borrow amounts
        uint256 collateralPrice = IOracle(MO_ORACLE).price();

        // Calculate borrow amount based on LTV
        // WSTETH -> WETH via Morpho oracle
        BORROW_WETH_AMOUNT = COLLATERAL_AMOUNT.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).wMulDown(MO_LLTV) * 95 / 100;
    }

    function newIntermediateVaultForMorpho(address _asset, address _oracle, address _unitOfAccount) internal returns (IEVault) {
        IEVault new_vault = IEVault(factory.createProxy(address(0), true, abi.encodePacked(_asset, _oracle, _unitOfAccount)));

        // Set hook so all borrows and flashloans use the bridge
        new_vault.setHookConfig(address(new BridgeHookTarget(address(collateralVaultFactory))), OP_BORROW | OP_LIQUIDATE | OP_FLASHLOAN | OP_PULL_DEBT);

        // Set interest rate model
        new_vault.setInterestRateModel(address(new IRMTwyneCurve({
            minInterest_: 0,
            linearParameter_: 750,
            polynomialParameter_: 49250,
            nonlinearPoint_: 5e17 // 50%
        })));

        new_vault.setMaxLiquidationDiscount(0.2e4);
        new_vault.setLiquidationCoolOffTime(1);
        new_vault.setFeeReceiver(feeReceiver);
        new_vault.setInterestFee(0);
        assertEq(new_vault.protocolFeeShare(), 0, "Protocol fee not zero");

        // Set up oracle for the intermediate vault
        // Only set the intermediate vault as a resolved vault (it's ERC4626)
        // Don't set the raw collateral token (_asset) - it's not ERC4626
        twyneVaultManager.setOracleResolvedVault(_oracle, address(new_vault), true);

        twyneVaultManager.setIntermediateVault(new_vault, true);
        new_vault.setGovernorAdmin(address(twyneVaultManager));
        assertEq(new_vault.unitOfAccount(), _asset, "Morpho intermediate vault must be self-denominated");

        assertEq(new_vault.configFlags() & CFG_DONT_SOCIALIZE_DEBT, 0, "debt isn't socialized");
        return new_vault;
    }

    // Helper function to calculate reserved assets for Morpho
    function getReservedAssetsForMorpho(uint256 depositAmount, MorphoCollateralVault collateralVault) internal view returns (uint reservedAssets) {
        uint externalLiqBuffer = uint(collateralVault.twyneVaultManager().externalLiqBuffers(address(collateralVault.intermediateVault()), collateralVault.targetAsset()));
        uint liqLTV_twyne = collateralVault.twyneLiqLTV();
        MarketParams memory mp = collateralVault.marketParams();
        uint liqLTV_external = mp.lltv * externalLiqBuffer / 1e14; // Convert to 1e4 precision

        if (liqLTV_twyne * 1e18 <= liqLTV_external) {
            return 0;
        }

        uint LTVdiff = (MAXFACTOR * liqLTV_twyne) - liqLTV_external;
        reservedAssets = Math.ceilDiv(depositAmount * LTVdiff, liqLTV_external);
    }

    // Helper to get Morpho LLTV in 1e4 precision
    function getMorphoLTVIn1e4() internal pure returns (uint16) {
        return uint16(MO_LLTV / 1e14); // 9650
    }

    ///
    // Test helper functions - similar to Euler/Aave patterns
    ///

    function morpho_creditDeposit(address collateralAsset) public noGasMetering {
        vm.assume(collateralAsset == MO_COLLATERAL_TOKEN);

        vm.startPrank(bob);
        IERC20(collateralAsset).approve(address(morpho_intermediate_vault), type(uint256).max);
        morpho_intermediate_vault.deposit(CREDIT_LP_AMOUNT, bob);
        vm.stopPrank();

        assertEq(morpho_intermediate_vault.balanceOf(bob), CREDIT_LP_AMOUNT, "Bob should have shares");
        assertEq(IERC20(collateralAsset).balanceOf(address(morpho_intermediate_vault)), CREDIT_LP_AMOUNT, "Intermediate vault should hold collateral");
    }

    function morpho_createCollateralVault(address collateralAsset, uint16 liqLTV) public noGasMetering {
        vm.assume(collateralAsset == MO_COLLATERAL_TOKEN);

        // Check LTV bounds
        uint16 extLiqBuffer = twyneVaultManager.externalLiqBuffers(address(morpho_intermediate_vault), MO_LOAN_TOKEN);
        uint16 morphoLTV = getMorphoLTVIn1e4();
        vm.assume(uint(morphoLTV) * uint(extLiqBuffer) <= uint256(liqLTV) * MAXFACTOR);
        vm.assume(liqLTV <= twyneVaultManager.maxTwyneLTVs(address(morpho_intermediate_vault), MO_LOAN_TOKEN));

        vm.startPrank(alice);
        collateralVaultFactory.createMorphoCollateralVault({
            _intermediateVault: address(morpho_intermediate_vault),
            _targetVault: morpho,
            _marketParams: morphoMarketParams,
            _liqLTV: liqLTV
        });

        // Get the newly created vault from the collateralVaults array
        address[] memory vaults = collateralVaultFactory.getCollateralVaults(alice);
        alice_morpho_vault = MorphoCollateralVault(vaults[vaults.length - 1]);
        vm.stopPrank();

        vm.label(address(alice_morpho_vault), "alice_morpho_vault");
        assertEq(alice_morpho_vault.borrower(), alice, "Vault borrower should be alice");
        assertEq(alice_morpho_vault.twyneLiqLTV(), liqLTV, "Vault LTV should match");
    }

    function morpho_collateralDepositWithoutBorrow(address collateralAsset, uint16 liqLTV) public noGasMetering {
        morpho_creditDeposit(collateralAsset);
        morpho_createCollateralVault(collateralAsset, liqLTV);
        console2.log("WSTETH Balance before creation: ", IERC20(collateralAsset).balanceOf(address(alice_morpho_vault)));
        vm.startPrank(alice);
        IERC20(collateralAsset).approve(address(alice_morpho_vault), type(uint256).max);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.deposit, (COLLATERAL_AMOUNT))
        });

        evc.batch(items);
        vm.stopPrank();
        console2.log("WSTETH Balance after deposit: ", IERC20(collateralAsset).balanceOf(address(alice_morpho_vault)));
        // Verify deposit
        assertEq(alice_morpho_vault.balanceOf(address(alice_morpho_vault)), COLLATERAL_AMOUNT, "Vault should show correct balance");
    }

    function morpho_firstBorrowDirect(address collateralAsset) public noGasMetering {
        morpho_collateralDepositWithoutBorrow(collateralAsset, twyneLiqLTV);

        uint256 reservedAmount = getReservedAssetsForMorpho(COLLATERAL_AMOUNT, alice_morpho_vault);

        vm.startPrank(alice);
        alice_morpho_vault.borrow(BORROW_WETH_AMOUNT, alice);
        vm.stopPrank();

        // Verify borrow state
        assertEq(alice_morpho_vault.maxRelease(), reservedAmount, "Reserved amount mismatch");
        assertApproxEqAbs(alice_morpho_vault.maxRepay(), BORROW_WETH_AMOUNT, 1, "Morpho debt mismatch");
        assertEq(IERC20(MO_LOAN_TOKEN).balanceOf(alice), INITIAL_DEALT_ERC20 + BORROW_WETH_AMOUNT, "Alice should have received borrowed WETH");
    }

    function morpho_repayWithdrawAll(address collateralAsset) public noGasMetering {
        morpho_firstBorrowDirect(collateralAsset);

        vm.startPrank(alice);
        IERC20(MO_LOAN_TOKEN).approve(address(alice_morpho_vault), type(uint256).max);
        IERC20(collateralAsset).approve(address(alice_morpho_vault), type(uint256).max);

        // Repay all Morpho debt
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.repay, (type(uint256).max))
        });
        evc.batch(items);

        // Withdraw all collateral
        IEVC.BatchItem[] memory withdrawItems = new IEVC.BatchItem[](1);
        withdrawItems[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.withdraw, (type(uint).max, alice))
        });
        evc.batch(withdrawItems);
        vm.stopPrank();

        assertEq(alice_morpho_vault.maxRepay(), 0, "Should have no Morpho debt");
        assertEq(alice_morpho_vault.maxRelease(), 0, "Should have no intermediate vault debt");
        assertEq(IERC20(collateralAsset).balanceOf(address(alice_morpho_vault)), 0, "Vault should have no collateral");
    }

    function morpho_interestAccrualThenRepay(address collateralAsset) public noGasMetering {
        morpho_firstBorrowDirect(collateralAsset);

        uint originalMaxRelease = alice_morpho_vault.maxRelease();
        assertApproxEqAbs(alice_morpho_vault.maxRepay(), BORROW_WETH_AMOUNT, 1, "Initial debt mismatch");

        // Move forward in time
        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 12);

        // Verify interest accrued
        assertGt(alice_morpho_vault.maxRelease(), originalMaxRelease, "Should have more intermediate vault debt");
        assertGt(alice_morpho_vault.maxRepay(), BORROW_WETH_AMOUNT, "Should have more Morpho debt");

        // Repay and withdraw
        vm.startPrank(alice);
        IERC20(MO_LOAN_TOKEN).approve(address(alice_morpho_vault), type(uint256).max);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.repay, (type(uint256).max))
        });
        evc.batch(items);

        // Withdraw
        deal(MO_LOAN_TOKEN, address(alice_morpho_vault), INITIAL_DEALT_ERC20); // For interest
        IEVC.BatchItem[] memory withdrawItems = new IEVC.BatchItem[](1);
        withdrawItems[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.withdraw, (type(uint).max, alice))
        });
        evc.batch(withdrawItems);
        vm.stopPrank();

        assertEq(alice_morpho_vault.maxRepay(), 0, "Should have no debt after repay");
        assertEq(alice_morpho_vault.maxRelease(), 0, "Should have no release after repay");
    }

    function morpho_secondBorrow(address collateralAsset) public noGasMetering {
        morpho_firstBorrowDirect(collateralAsset);

        // Bob creates vault
        vm.startPrank(bob);
        collateralVaultFactory.createMorphoCollateralVault({
            _intermediateVault: address(morpho_intermediate_vault),
            _targetVault: morpho,
            _marketParams: morphoMarketParams,
            _liqLTV: twyneLiqLTV
        });
        address[] memory bobVaults = collateralVaultFactory.getCollateralVaults(bob);
        bob_morpho_vault = MorphoCollateralVault(bobVaults[bobVaults.length - 1]);
        vm.label(address(bob_morpho_vault), "bob_morpho_vault");

        uint256 reservedAmount = getReservedAssetsForMorpho(COLLATERAL_AMOUNT, bob_morpho_vault);

        IERC20(collateralAsset).approve(address(bob_morpho_vault), type(uint256).max);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(bob_morpho_vault),
            onBehalfOfAccount: bob,
            value: 0,
            data: abi.encodeCall(bob_morpho_vault.deposit, (COLLATERAL_AMOUNT))
        });
        evc.batch(items);

        bob_morpho_vault.borrow(BORROW_WETH_AMOUNT, bob);
        vm.stopPrank();

        assertEq(bob_morpho_vault.maxRelease(), reservedAmount, "Bob reserved amount mismatch");
        assertApproxEqAbs(bob_morpho_vault.maxRepay(), BORROW_WETH_AMOUNT, 1, "Bob Morpho debt mismatch");
    }

    function morpho_setTwyneLiqLTVNoBorrow(address collateralAsset) public noGasMetering {
        morpho_createCollateralVault(collateralAsset, twyneLiqLTV);

        vm.startPrank(alice);
        uint16 newLTV = twyneVaultManager.maxTwyneLTVs(address(morpho_intermediate_vault), alice_morpho_vault.targetAsset());
        alice_morpho_vault.setTwyneLiqLTV(newLTV);
        vm.stopPrank();

        assertEq(alice_morpho_vault.twyneLiqLTV(), newLTV, "LTV not updated");
    }

    function morpho_setTwyneLiqLTVWithBorrow(address collateralAsset) public noGasMetering {
        morpho_firstBorrowDirect(collateralAsset);

        vm.startPrank(alice);

        // Should revert for invalid LTVs
        vm.expectRevert(TwyneErrors.ValueOutOfRange.selector);
        alice_morpho_vault.setTwyneLiqLTV(0);
        vm.expectRevert(TwyneErrors.ValueOutOfRange.selector);
        alice_morpho_vault.setTwyneLiqLTV(1e4);

        // Valid LTV changes
        uint16 cachedMaxTwyneLTV = twyneVaultManager.maxTwyneLTVs(address(morpho_intermediate_vault), alice_morpho_vault.targetAsset());
        alice_morpho_vault.setTwyneLiqLTV(cachedMaxTwyneLTV - 20);
        alice_morpho_vault.setTwyneLiqLTV(cachedMaxTwyneLTV - 40);
        alice_morpho_vault.setTwyneLiqLTV(cachedMaxTwyneLTV);
        vm.stopPrank();
    }

    function morpho_permit2CollateralDeposit(address collateralAsset) public noGasMetering {
        morpho_creditDeposit(collateralAsset);
        morpho_createCollateralVault(collateralAsset, twyneLiqLTV);

        vm.startPrank(alice);
        IERC20(collateralAsset).approve(permit2, type(uint256).max);

        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: collateralAsset,
                amount: uint160(COLLATERAL_AMOUNT),
                expiration: type(uint48).max,
                nonce: 0
            }),
            spender: address(alice_morpho_vault),
            sigDeadline: type(uint256).max
        });
        Permit2ECDSASigner permit2Signer = new Permit2ECDSASigner(address(permit2));

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
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
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.deposit, (COLLATERAL_AMOUNT))
        });

        evc.batch(items);
        vm.stopPrank();

        assertEq(alice_morpho_vault.balanceOf(address(alice_morpho_vault)), COLLATERAL_AMOUNT, "Deposit via permit2 failed");
    }

    function morpho_withdrawCollateralAfterWarp(address collateralAsset, uint warpBlockAmount) public noGasMetering {
        vm.assume(warpBlockAmount > 0 && warpBlockAmount < 10000000);

        morpho_collateralDepositWithoutBorrow(collateralAsset, twyneLiqLTV);

        vm.roll(block.number + warpBlockAmount);
        vm.warp(block.timestamp + 12);

        vm.startPrank(alice);
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.withdraw, (type(uint).max, alice))
        });
        evc.batch(items);
        vm.stopPrank();

        assertEq(alice_morpho_vault.balanceOf(address(alice_morpho_vault)), 0, "Should be able to withdraw all");
    }

    function morpho_skim(address collateralAsset) public noGasMetering {
        morpho_collateralDepositWithoutBorrow(collateralAsset, twyneLiqLTV);

        uint256 skimAmount = 1 ether;
        deal(collateralAsset, address(alice_morpho_vault), COLLATERAL_AMOUNT + alice_morpho_vault.maxRelease() + skimAmount);

        uint256 balanceBefore = alice_morpho_vault.totalAssetsDepositedOrReserved();

        vm.startPrank(alice);
        alice_morpho_vault.skim();
        vm.stopPrank();

        assertGt(alice_morpho_vault.totalAssetsDepositedOrReserved(), balanceBefore, "Skim should increase assets");
    }

    function morpho_postBorrowChecks(address collateralAsset) public noGasMetering {
        morpho_firstBorrowDirect(collateralAsset);

        // Verify Morpho position
        uint256 morphoCollateral = alice_morpho_vault.collateralBalance();
        assertGt(morphoCollateral, 0, "Should have Morpho collateral");

        uint256 morphoDebt = alice_morpho_vault.maxRepay();
        assertApproxEqAbs(morphoDebt, BORROW_WETH_AMOUNT, 1, "Morpho debt mismatch");

        // Verify intermediate vault state
        uint256 reservedAssets = alice_morpho_vault.maxRelease();
        assertGt(reservedAssets, 0, "Should have reserved assets");

        // Verify total assets
        uint256 totalAssets = alice_morpho_vault.totalAssetsDepositedOrReserved();
        assertEq(totalAssets, COLLATERAL_AMOUNT + reservedAssets, "Total assets mismatch");
    }

    function morpho_totalAssetsIntermediateVault(address collateralAsset, uint16 liqLTV) public noGasMetering {
        morpho_creditDeposit(collateralAsset);
        morpho_createCollateralVault(collateralAsset, liqLTV);

        uint256 totalAssetsBefore = morpho_intermediate_vault.totalAssets();
        assertEq(totalAssetsBefore, CREDIT_LP_AMOUNT, "Initial total assets mismatch");
    }

    function morpho_totalAssetsCollateralVault(address collateralAsset, uint16 liqLTV) public noGasMetering {
        morpho_collateralDepositWithoutBorrow(collateralAsset, liqLTV);

        uint256 userBalance = alice_morpho_vault.balanceOf(address(alice_morpho_vault));
        assertEq(userBalance, COLLATERAL_AMOUNT, "User balance mismatch");
    }

    function morpho_supplyCap_creditDeposit(address collateralAsset) public noGasMetering {
        vm.assume(collateralAsset == MO_COLLATERAL_TOKEN);

        // Set supply cap directly on the intermediate vault
        vm.startPrank(address(twyneVaultManager));
        morpho_intermediate_vault.setCaps(1, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(collateralAsset).approve(address(morpho_intermediate_vault), type(uint256).max);
        vm.expectRevert(Errors.E_SupplyCapExceeded.selector);
        morpho_intermediate_vault.deposit(CREDIT_LP_AMOUNT, bob);
        vm.stopPrank();

        // Reset cap
        vm.startPrank(address(twyneVaultManager));
        morpho_intermediate_vault.setCaps(0, 0);
        vm.stopPrank();
    }

    function morpho_second_creditDeposit(address collateralAsset) public noGasMetering {
        morpho_creditDeposit(collateralAsset);

        vm.startPrank(eve);
        IERC20(collateralAsset).approve(address(morpho_intermediate_vault), type(uint256).max);
        morpho_intermediate_vault.deposit(CREDIT_LP_AMOUNT, eve);
        vm.stopPrank();

        assertEq(morpho_intermediate_vault.balanceOf(eve), CREDIT_LP_AMOUNT, "Eve should have shares");
    }

    function morpho_creditWithdrawNoInterest(address collateralAsset) public noGasMetering {
        morpho_creditDeposit(collateralAsset);

        uint256 bobSharesBefore = morpho_intermediate_vault.balanceOf(bob);

        vm.startPrank(bob);
        morpho_intermediate_vault.redeem(bobSharesBefore, bob, bob);
        vm.stopPrank();

        assertEq(morpho_intermediate_vault.balanceOf(bob), 0, "Bob should have no shares");
        assertApproxEqAbs(IERC20(collateralAsset).balanceOf(bob), INITIAL_DEALT_ERC20, 1, "Bob should get back collateral");
    }

    function morpho_collateralDepositWithBorrow(address collateralAsset) public noGasMetering {
        morpho_creditDeposit(collateralAsset);

        // Create vault with max LTV to minimize reserved assets
        uint16 maxLTV = twyneVaultManager.maxTwyneLTVs(address(morpho_intermediate_vault), MO_LOAN_TOKEN);
        morpho_createCollateralVault(collateralAsset, maxLTV);

        vm.startPrank(alice);
        IERC20(collateralAsset).approve(address(alice_morpho_vault), type(uint256).max);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.deposit, (COLLATERAL_AMOUNT))
        });
        evc.batch(items);

        // Borrow
        alice_morpho_vault.borrow(BORROW_WETH_AMOUNT, alice);
        vm.stopPrank();

        assertApproxEqAbs(alice_morpho_vault.maxRepay(), BORROW_WETH_AMOUNT, 1, "Borrow amount mismatch");
    }

    function morpho_evcCanCreateCollateralVault(address collateralAsset) public noGasMetering {
        vm.assume(collateralAsset == MO_COLLATERAL_TOKEN);

        morpho_creditDeposit(collateralAsset);

        vm.startPrank(alice);
        IERC20(collateralAsset).approve(address(evc), type(uint256).max);

        // Create vault via EVC batch
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(collateralVaultFactory),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(
                collateralVaultFactory.createMorphoCollateralVault,
                (address(morpho_intermediate_vault), morpho, morphoMarketParams, twyneLiqLTV)
            )
        });

        evc.batch(items);
        vm.stopPrank();

        address[] memory vaults = collateralVaultFactory.getCollateralVaults(alice);
        assertGt(vaults.length, 0, "Alice should have a vault");
    }

    function morpho_permit2FirstRepay(address collateralAsset) public noGasMetering {
        morpho_firstBorrowDirect(collateralAsset);

        vm.startPrank(alice);
        IERC20(MO_LOAN_TOKEN).approve(permit2, type(uint).max);
        uint maxRepay = alice_morpho_vault.maxRepay();
        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: MO_LOAN_TOKEN,
                amount: uint160(maxRepay),
                expiration: type(uint48).max,
                nonce: 0
            }),
            spender: address(alice_morpho_vault),
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
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.repay, (maxRepay))
        });
        items[2] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.withdraw, (alice_morpho_vault.balanceOf(address(alice_morpho_vault)), alice))
        });

        evc.batch(items);
        vm.stopPrank();

        assertEq(alice_morpho_vault.maxRepay(), 0, "Should have no debt");
        assertEq(alice_morpho_vault.maxRelease(), 0, "Should have no release");
    }

    function morpho_creditWithdrawWithInterestAndNoFees(address collateralAsset, uint warpBlockAmount) public noGasMetering {
        vm.assume(warpBlockAmount > 0 && warpBlockAmount < 10000000);

        morpho_collateralDepositWithoutBorrow(collateralAsset, twyneLiqLTV);
        IEVault intermediate_vault = morpho_intermediate_vault;

        // Confirm fees setup
        assertEq(intermediate_vault.interestFee(), 0, "Unexpected intermediate vault interest fee");
        assertEq(intermediate_vault.feeReceiver(), feeReceiver, "fee receiver address is wrong");
        assertEq(intermediate_vault.protocolFeeShare(), 0, "Unexpected intermediate vault interest fee");


        // 2. Warp time to accrue interest
        vm.roll(block.number + warpBlockAmount);
        vm.warp(block.timestamp + 365 days);

        // Confirm vault is rebalanceable
        assertGt(alice_morpho_vault.canRebalance(), 0, "Vault is not rebalanceable");

        // 4. Alice withdraws her collateral
        vm.startPrank(alice);
        uint256 aliceShares = alice_morpho_vault.balanceOf(address(alice_morpho_vault));
        alice_morpho_vault.withdraw(aliceShares, alice);
        vm.stopPrank();

        // Alice should have some aWETHWrapper tokens now
        assertGt(IERC20(collateralAsset).balanceOf(alice), 0, "Alice should have aWETHWrapper tokens");
        assertEq(IERC20(collateralAsset).balanceOf(address(alice_morpho_vault)), 0, "Incorrect aWETHWrapper balance remaining in vault");
        // 5. Credit LP Bob withdraws all with accrued interest
        vm.startPrank(bob);
        morpho_intermediate_vault.redeem(type(uint).max, bob, bob);
        morpho_intermediate_vault.convertFees(); // Should do nothing as fees are 0
        vm.stopPrank();

        // Confirm zero accrued fees in intermediate vault
        assertEq(morpho_intermediate_vault.accumulatedFees(), 0, "Should have zero accumulated fees");

        assertApproxEqAbs(morpho_intermediate_vault.totalSupply(), 0, 10, "Intermediate vault is not empty as expected!");

    }

    function morpho_creditWithdrawWithInterestAndFees(address collateralAsset) public noGasMetering {
        // Set non-zero protocolConfig fee
        vm.startPrank(admin);
        protocolConfig.setInterestFeeRange(0.1e4, 1e4); // set fee range to zero
        protocolConfig.setProtocolFeeShare(0.5e4); // set fee to zero
        assertNotEq(morpho_intermediate_vault.protocolFeeShare(), 0, "Protocol fee should not be zero");
        vm.stopPrank();


        // Set non-zero governance fee
        vm.startPrank(morpho_intermediate_vault.governorAdmin());
        morpho_intermediate_vault.setFeeReceiver(feeReceiver);
        morpho_intermediate_vault.setInterestFee(0.1e4); // set non-zero governance fee
        assertEq(morpho_intermediate_vault.interestFee(), 0.1e4, "Unexpected intermediate vault interest rate");
        vm.stopPrank();

        morpho_collateralDepositWithoutBorrow(collateralAsset, twyneLiqLTV);

        uint256 bobSharesBefore = morpho_intermediate_vault.balanceOf(bob);

        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 365 days);

        // Confirm that time passing makes the collateral vault rebalanceable
        assertGt(alice_morpho_vault.canRebalance(), 0, "Vault is not rebalanceable even with time passing");

        console2.log("WSTETH Balance: ", IERC20(collateralAsset).balanceOf(address(alice_morpho_vault)));

        // 5. Alice withdraws her collateral
        vm.startPrank(alice);
        uint256 aliceShares = alice_morpho_vault.balanceOf(address(alice_morpho_vault));
        alice_morpho_vault.withdraw(aliceShares, alice);
        vm.stopPrank();

        assertEq(IERC20(collateralAsset).balanceOf(address(alice_morpho_vault)), 0, "Incorrect aWethWrapper balance remaining in vault");

        vm.startPrank(bob);
        uint256 assetsReceived = morpho_intermediate_vault.redeem(bobSharesBefore, bob, bob);
        assertEq(morpho_intermediate_vault.totalSupply(), morpho_intermediate_vault.accumulatedFees(), "Remaining assets are not just fees!");
        vm.stopPrank();

        assertGt(assetsReceived, 0, "Bob should receive assets");

        // Withdraw all the accrued fees to fully empty the intermediate vault
        vm.startPrank(feeReceiver);
        assertEq(morpho_intermediate_vault.feeReceiver(), feeReceiver, "Unexpected feeReceiver");
        // First, split the fees
        morpho_intermediate_vault.convertFees();
        // Withdraw the fees owed to fee receiver (AKA governor receiver)
        uint receiveFees = morpho_intermediate_vault.redeem(type(uint).max, feeReceiver, feeReceiver);
        assertNotEq(receiveFees, 0, "Received governor fees was zero?!");
        vm.stopPrank();

        vm.startPrank(protocolFeeReceiver);
        assertEq(morpho_intermediate_vault.protocolFeeReceiver(), protocolFeeReceiver, "Unexpected protocolFeeReceiver");
        // Withdraw the fees owed to protocolConfig feeReceiver
        receiveFees = morpho_intermediate_vault.redeem(type(uint).max, protocolFeeReceiver, protocolFeeReceiver);
        assertNotEq(receiveFees, 0, "Received protocolConfig fees was zero?!");
        vm.stopPrank();

        assertEq(morpho_intermediate_vault.totalSupply(), 0, "Intermediate vault is not empty as expected!");
        assertNotEq(morpho_intermediate_vault.totalAssets(), 0, "Awesome, no dust left in the contract at all. How did you do that?");
    }

    function morpho_maxBorrowDirect(address collateralAsset, uint16 collateralMultiplier) public noGasMetering {
        vm.assume(collateralMultiplier > 0 && collateralMultiplier <= 2e4);

        morpho_creditDeposit(collateralAsset);
        morpho_createCollateralVault(collateralAsset, twyneLiqLTV);

        uint256 scaledCollateral = COLLATERAL_AMOUNT * collateralMultiplier / 1e4;
        deal(collateralAsset, alice, scaledCollateral);

        vm.startPrank(alice);
        IERC20(collateralAsset).approve(address(alice_morpho_vault), type(uint256).max);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.deposit, (scaledCollateral))
        });
        evc.batch(items);

        // Calculate max borrow based on Morpho LTV
        uint256 collateralPrice = IOracle(MO_ORACLE).price();
        uint256 maxBorrow = scaledCollateral.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).wMulDown(MO_LLTV) * 95 / 100;

        if (maxBorrow > 0) {
            alice_morpho_vault.borrow(maxBorrow, alice);
            assertApproxEqAbs(alice_morpho_vault.maxRepay(), maxBorrow, 1, "Max borrow mismatch");
        }
        vm.stopPrank();
    }
    function morpho_borrowBufferMaxBorrow(address collateralAsset) public noGasMetering {
        morpho_creditDeposit(collateralAsset);

        // Set the max borrow buffer x = 5% before vault creation (governance-only).
        vm.startPrank(admin);
        twyneVaultManager.setBorrowBuffer(address(morpho_intermediate_vault), MO_LOAN_TOKEN, 500);
        vm.stopPrank();

        morpho_createCollateralVault(collateralAsset, twyneLiqLTV);

        // Deposit collateral
        vm.startPrank(alice);
        IERC20(collateralAsset).approve(address(alice_morpho_vault), type(uint256).max);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.deposit, (COLLATERAL_AMOUNT))
        });
        evc.batch(items);

        // Independent check: right after deposit there is no debt or interest drift, and credit is
        // freshly reserved to support the chosen LTV, so the dynamic liqLTV_t = twyneLiqLTV (the chosen
        // leg binds under ample credit). Derive maxBorrow straight from spec Eq. 1 in 1e4 space —
        // ceiling on the ramp term, matching the contract's conservative rounding — rather than mirroring
        // maxBorrow()'s internal 1e8 cross-multiplication. A bug in that scaling would surface here.
        uint256 price = IOracle(MO_ORACLE).price();
        uint256 liqLTV_e = MO_LLTV / 1e14; // 9650 (1e4)
        uint256 maxTwyneLiqLTV = twyneVaultManager.maxTwyneLTVs(address(morpho_intermediate_vault), alice_morpho_vault.targetAsset());
        uint256 liqLTV_t = alice_morpho_vault.twyneLiqLTV(); // dynamic liqLTV_t = chosen (ample credit)
        uint256 borrowBuffer = 500;
        uint256 borrowLTV_t =
            liqLTV_t - Math.ceilDiv(borrowBuffer * (liqLTV_t - liqLTV_e), maxTwyneLiqLTV - liqLTV_e);
        uint256 userCollateral =
            alice_morpho_vault.totalAssetsDepositedOrReserved() - alice_morpho_vault.maxRelease();
        uint256 maxBorrow = borrowLTV_t * userCollateral * price / (1e4 * ORACLE_PRICE_SCALE);
        assertEq(alice_morpho_vault.maxBorrow(), maxBorrow, "maxBorrow != spec Eq. 1 value");

        // Borrow up to maxBorrow. The post-action check overestimates maxRepay() by up to ~1 wei
        // (Morpho debt-share rounding), so borrow maxBorrow-1 to stay within it.
        alice_morpho_vault.borrow(maxBorrow - 1, alice);
        assertApproxEqAbs(alice_morpho_vault.maxRepay(), maxBorrow - 1, 1, "at-maxBorrow debt mismatch");

        // Borrowing past maxBorrow reverts with the Twyne error. 2 wei is within Morpho's own lltv
        // (which sits above Twyne's maxBorrow) but exceeds the ~1 wei of post-action headroom, proving
        // it is Twyne's maxBorrow — not Morpho's — that rejects the borrow.
        vm.expectRevert(TwyneErrors.T_BorrowExceedsMaxLTV.selector);
        alice_morpho_vault.borrow(2, alice);
        vm.stopPrank();
    }

    function morpho_borrowBufferDefaultsToNone(address collateralAsset) public noGasMetering {
        // With 0 morpho borrow buffer, the borrow LTV equals the dynamic liquidation LTV.
        morpho_collateralDepositWithoutBorrow(collateralAsset, twyneLiqLTV);

        // borrowBuffer = 0 ⇒ no ramp ⇒ borrowLTV_t = dynamic liqLTV_t = twyneLiqLTV (ample credit,
        // fresh deposit), so maxBorrow = liqLTV_t · userCollateral · price. Derived directly from the
        // definition, not by mirroring maxBorrow()'s internal scaling.
        uint256 price = IOracle(MO_ORACLE).price();
        uint256 liqLTV_t = alice_morpho_vault.twyneLiqLTV();
        uint256 userCollateral =
            alice_morpho_vault.totalAssetsDepositedOrReserved() - alice_morpho_vault.maxRelease();
        uint256 maxBorrow = liqLTV_t * userCollateral * price / (1e4 * ORACLE_PRICE_SCALE);
        assertEq(
            alice_morpho_vault.maxBorrow(),
            maxBorrow,
            "default borrow buffer (d=0) should be liqLTV_dyn * C"
        );
    }

    /// @notice The max-borrow ramp is enforced on collateral WITHDRAW (a health-degrading action),
    ///         not only on borrow. At maxBorrow, even a 1-wei collateral withdrawal pushes the borrow
    ///         LTV above borrowLTV_t while staying well below the _canLiquidate thresholds, so the ramp —
    ///         not the liquidation check — must reject it.
    function morpho_borrowRampBlocksWithdraw(address collateralAsset) public noGasMetering {
        morpho_creditDeposit(collateralAsset);
        vm.startPrank(admin);
        twyneVaultManager.setBorrowBuffer(address(morpho_intermediate_vault), MO_LOAN_TOKEN, 500);
        vm.stopPrank();
        morpho_createCollateralVault(collateralAsset, twyneLiqLTV);

        vm.startPrank(alice);
        IERC20(collateralAsset).approve(address(alice_morpho_vault), type(uint256).max);
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.deposit, (COLLATERAL_AMOUNT))
        });
        evc.batch(items);

        // Borrow right up to maxBorrow. The post-action check needs ~1 wei headroom (maxRepay rounding),
        // so borrow maxBorrow-1; this still sits at borrow LTV == borrowLTV_t < liqLTV_t.
        uint256 maxBorrow = alice_morpho_vault.maxBorrow();
        alice_morpho_vault.borrow(maxBorrow - 1, alice);

        // A 1-wei collateral withdraw is health-degrading and must be rejected by the ramp.
        uint256 withdrawable = alice_morpho_vault.balanceOf(address(alice_morpho_vault));
        require(withdrawable > 0, "no withdrawable collateral at maxBorrow");
        vm.expectRevert(TwyneErrors.T_BorrowExceedsMaxLTV.selector);
        alice_morpho_vault.withdraw(1, alice);
        vm.stopPrank();
    }

    /// @notice Spec Eq. 1 monotonicity: with a compliant ramp slope
    ///         (k = borrowBuffer/(maxTwyneLiqLTV − liqLTV_e) < 1), raising twyneLiqLTV RAISES maxBorrow
    ///         (d borrowLTV_t/d liqLTV_t = 1 − k > 0). A position borrowed to maxBorrow at a lower
    ///         twyneLiqLTV therefore stays under maxBorrow after raising, so the gated setTwyneLiqLTV
    ///         succeeds and maxBorrow strictly increases. borrowBuffer must be < maxTwyneLiqLTV − liqLTV_e;
    ///         here that is 9900 − 9650 = 250, so borrowBuffer = 200 ⇒ k = 0.8.
    function morpho_borrowRampMonotonicInLiqLTV(address collateralAsset) public noGasMetering {
        morpho_creditDeposit(collateralAsset);
        // Spec-compliant slope: borrowBuffer (200) < maxTwyneLiqLTV − liqLTV_e (250) ⇒ k = 0.8 < 1.
        vm.startPrank(admin);
        twyneVaultManager.setBorrowBuffer(address(morpho_intermediate_vault), MO_LOAN_TOKEN, 200);
        vm.stopPrank();
        morpho_createCollateralVault(collateralAsset, 9700);

        vm.startPrank(alice);
        IERC20(collateralAsset).approve(address(alice_morpho_vault), type(uint256).max);
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.deposit, (COLLATERAL_AMOUNT))
        });
        evc.batch(items);

        // Borrow to maxBorrow (-1 for the ~1 wei post-action headroom).
        uint256 maxBorrowBefore = alice_morpho_vault.maxBorrow();
        alice_morpho_vault.borrow(maxBorrowBefore - 1, alice);

        // Raising twyneLiqLTV (9700 → 9800) raises maxBorrow (monotonicity, 1 − k > 0). The position,
        // borrowed to the old maxBorrow-1, stays under the new higher maxBorrow, so the gated action
        // succeeds and maxBorrow strictly increases.
        alice_morpho_vault.setTwyneLiqLTV(9800);
        assertGt(alice_morpho_vault.maxBorrow(), maxBorrowBefore, "maxBorrow should rise with twyneLiqLTV (k<1)");
        vm.stopPrank();
    }

    /// @notice The ramp is enforced in checkVaultStatus via a batch-start snapshot delta. Non-degrading
    ///         actions (deposit) shrink the excess over maxBorrow, so the delta check passes even at maxBorrow —
    ///         a position above maxBorrow may be topped-up/repaid, just not degraded further (see
    ///         morpho_borrowRampBlocksWithdraw for the degrading contrast).
    function morpho_borrowRampAllowsNonDegradingAtMaxBorrow(address collateralAsset) public noGasMetering {
        morpho_creditDeposit(collateralAsset);
        vm.startPrank(admin);
        twyneVaultManager.setBorrowBuffer(address(morpho_intermediate_vault), MO_LOAN_TOKEN, 500);
        vm.stopPrank();
        morpho_createCollateralVault(collateralAsset, twyneLiqLTV);

        vm.startPrank(alice);
        IERC20(collateralAsset).approve(address(alice_morpho_vault), type(uint256).max);
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.deposit, (COLLATERAL_AMOUNT))
        });
        evc.batch(items);

        uint256 maxBorrow = alice_morpho_vault.maxBorrow();
        alice_morpho_vault.borrow(maxBorrow - 1, alice); // maxBorrow-1: post-action check needs ~1 wei headroom

        // Topping up collateral is health-improving: the ramp does not block it at maxBorrow.
        deal(collateralAsset, alice, COLLATERAL_AMOUNT);
        IEVC.BatchItem[] memory topUp = new IEVC.BatchItem[](1);
        topUp[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.deposit, (COLLATERAL_AMOUNT))
        });
        evc.batch(topUp); // succeeds — no T_BorrowExceedsMaxLTV
        vm.stopPrank();
    }

    /// @notice A position driven over maxBorrow by a governance buffer raise (not by a vault
    ///         action) may be repaid or topped up — the excess over maxBorrow shrinks — but not
    ///         degraded by a new borrow, which would grow the excess. This is exactly the
    ///         capability the checkVaultStatus snapshot delta unlocks; an absolute check there
    ///         would trap the position (it could neither repay nor top up).
    function morpho_borrowRampOverMaxBorrowAllowsRepay(address collateralAsset) public noGasMetering {
        morpho_creditDeposit(collateralAsset);

        // 5% borrow buffer; position borrowed up to maxBorrow-1 (within maxBorrow).
        vm.startPrank(admin);
        twyneVaultManager.setBorrowBuffer(address(morpho_intermediate_vault), MO_LOAN_TOKEN, 500);
        vm.stopPrank();
        morpho_createCollateralVault(collateralAsset, twyneLiqLTV);

        vm.startPrank(alice);
        IERC20(collateralAsset).approve(address(alice_morpho_vault), type(uint256).max);
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.deposit, (COLLATERAL_AMOUNT))
        });
        evc.batch(items);

        uint256 maxBorrow = alice_morpho_vault.maxBorrow();
        alice_morpho_vault.borrow(maxBorrow - 1, alice); // maxBorrow-1: ~1 wei post-action headroom

        // Governance raises the buffer. setBorrowBuffer touches only VaultManager storage
        // and emits an event — no vault action, so no checkVaultStatus fires and the transient
        // excess snapshot stays 0. The position is now over maxBorrow: maxRepay (≈ old maxBorrow)
        // exceeds the lowered maxBorrow.
        vm.startPrank(admin);
        twyneVaultManager.setBorrowBuffer(address(morpho_intermediate_vault), MO_LOAN_TOKEN, 800);
        vm.stopPrank();

        uint256 debt = alice_morpho_vault.maxRepay();
        assertGt(debt, alice_morpho_vault.maxBorrow(), "precond: position should be over maxBorrow");

        vm.startPrank(alice);
        // A new borrow grows the excess over maxBorrow beyond the batch-start snapshot → reverts.
        // Tested before any ameliorating action so the revert fires from the clear over-maxBorrow state.
        vm.expectRevert(TwyneErrors.T_BorrowExceedsMaxLTV.selector);
        alice_morpho_vault.borrow(1, alice);

        // Repay shrinks the excess over maxBorrow → checkVaultStatus passes (delta non-increasing).
        IERC20(MO_LOAN_TOKEN).approve(address(alice_morpho_vault), type(uint256).max);
        alice_morpho_vault.repay(debt / 4);
        assertLt(alice_morpho_vault.maxRepay(), debt, "repay should reduce debt");

        // Topping up collateral raises maxBorrow, shrinking the excess → passes.
        deal(collateralAsset, alice, COLLATERAL_AMOUNT);
        IEVC.BatchItem[] memory topUp = new IEVC.BatchItem[](1);
        topUp[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.deposit, (COLLATERAL_AMOUNT))
        });
        evc.batch(topUp); // succeeds — excess shrinks
        vm.stopPrank();
    }

    /// @notice The ramp is enforced on setTwyneLiqLTV, a health-degrading action: with a compliant
    ///         slope (k < 1), LOWERING twyneLiqLTV lowers maxBorrow, so a position borrowed to the
    ///         old maxBorrow lands over the new, lower maxBorrow — the excess over maxBorrow grows past the
    ///         batch-start snapshot and the action reverts. The decrease 9700 → 9680 is chosen so the
    ///         debt stays BELOW the new liquidation boundary (9680 > old maxBorrow 9660): the revert comes
    ///         from the ramp, not _canLiquidate. Repaying within the new maxBorrow first is the escape hatch.
    function morpho_borrowRampBlocksLiqLTVDecrease(address collateralAsset) public noGasMetering {
        morpho_creditDeposit(collateralAsset);
        // Spec-compliant slope: borrowBuffer (200) < maxTwyneLiqLTV − liqLTV_e (9900 − 9650 = 250) ⇒ k = 0.8.
        vm.startPrank(admin);
        twyneVaultManager.setBorrowBuffer(address(morpho_intermediate_vault), MO_LOAN_TOKEN, 200);
        vm.stopPrank();
        morpho_createCollateralVault(collateralAsset, 9700);

        vm.startPrank(alice);
        IERC20(collateralAsset).approve(address(alice_morpho_vault), type(uint256).max);
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.deposit, (COLLATERAL_AMOUNT))
        });
        evc.batch(items);

        // Borrow right up to maxBorrow at twyneLiqLTV 9700 (−1 wei: post-action maxRepay rounding headroom).
        // Spec Eq. 1: maxBorrow(9700) = 9700 − ⌈200·(9700−9650)/250⌉ = 9660 (1e4).
        uint256 maxBorrowBefore = alice_morpho_vault.maxBorrow();
        alice_morpho_vault.borrow(maxBorrowBefore - 1, alice);

        // Lowering twyneLiqLTV 9700 → 9680 drops maxBorrow to 9680 − ⌈200·(9680−9650)/250⌉ = 9656 while
        // debt is unchanged: the excess grows from 0 → T_BorrowExceedsMaxLTV. The position is NOT
        // liquidatable at the new boundary (9660 < 9680), so only the ramp can be rejecting this.
        vm.expectRevert(TwyneErrors.T_BorrowExceedsMaxLTV.selector);
        alice_morpho_vault.setTwyneLiqLTV(9680);

        // Escape hatch: repay down within the new maxBorrow, then the same liqLTV decrease succeeds.
        // maxBorrow derived independently from spec Eq. 1 in 1e4 space, as in morpho_borrowBufferMaxBorrow.
        uint256 price = IOracle(MO_ORACLE).price();
        uint256 userCollateral =
            alice_morpho_vault.totalAssetsDepositedOrReserved() - alice_morpho_vault.maxRelease();
        uint256 newBorrowLimit = 9656 * userCollateral * price / (1e4 * ORACLE_PRICE_SCALE);
        uint256 debt = alice_morpho_vault.maxRepay();
        require(debt > newBorrowLimit, "precond: debt should exceed the new, lower maxBorrow");
        IERC20(MO_LOAN_TOKEN).approve(address(alice_morpho_vault), type(uint256).max);
        alice_morpho_vault.repay(debt - newBorrowLimit + 10); // +10 wei: Morpho repay share-rounding margin

        alice_morpho_vault.setTwyneLiqLTV(9680); // succeeds — excess is 0 at the new, lower maxBorrow
        assertEq(alice_morpho_vault.twyneLiqLTV(), 9680, "liqLTV decrease should apply once within maxBorrow");
        assertEq(alice_morpho_vault.maxBorrow(), newBorrowLimit, "maxBorrow != spec Eq. 1 value at 9680");
        vm.stopPrank();
    }

    /// @notice The enforced metric is excess-per-collateral, not absolute excess. An over-maxBorrow
    ///         position that repays dB = borrowLimit·dC/C and withdraws dC in ONE batch — holding the
    ///         absolute excess flat (or even shrinking it, via the +100 wei margin on dB) while
    ///         operating LTV rises — must still revert: E1·C0 > E0·C1 because collateral fell.
    function morpho_borrowRampBlocksRepayAndWithdraw(address collateralAsset) public noGasMetering {
        morpho_creditDeposit(collateralAsset);
        vm.startPrank(admin);
        twyneVaultManager.setBorrowBuffer(address(morpho_intermediate_vault), MO_LOAN_TOKEN, 500);
        vm.stopPrank();
        morpho_createCollateralVault(collateralAsset, twyneLiqLTV);

        vm.startPrank(alice);
        IERC20(collateralAsset).approve(address(alice_morpho_vault), type(uint256).max);
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.deposit, (COLLATERAL_AMOUNT))
        });
        evc.batch(items);
        uint256 borrowLimit0 = alice_morpho_vault.maxBorrow();
        alice_morpho_vault.borrow(borrowLimit0 - 1, alice); // −1 wei: post-action maxRepay rounding headroom
        vm.stopPrank();

        // Governance raises the buffer: no vault action, no status check — the position is now
        // over maxBorrow, as in morpho_borrowRampOverMaxBorrowAllowsRepay.
        vm.startPrank(admin);
        twyneVaultManager.setBorrowBuffer(address(morpho_intermediate_vault), MO_LOAN_TOKEN, 800);
        vm.stopPrank();

        uint256 debt = alice_morpho_vault.maxRepay();
        uint256 borrowLimit = alice_morpho_vault.maxBorrow();
        uint256 userCollateral =
            alice_morpho_vault.totalAssetsDepositedOrReserved() - alice_morpho_vault.maxRelease();
        require(debt > borrowLimit, "precond: position should be over maxBorrow");

        // Pair a repay with a withdrawal: dB = borrowLimit·dC/C (+100 wei so the absolute excess strictly shrinks).
        uint256 dC = COLLATERAL_AMOUNT / 10;
        uint256 dB = (borrowLimit * dC) / userCollateral + 100;

        vm.startPrank(alice);
        IERC20(MO_LOAN_TOKEN).approve(address(alice_morpho_vault), type(uint256).max);
        items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.repay, (dB))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.withdraw, (dC, alice))
        });
        vm.expectRevert(TwyneErrors.T_BorrowExceedsMaxLTV.selector);
        evc.batch(items);
        vm.stopPrank();
    }

    /// @notice REGRESSION: an over-maxBorrow position must NOT be able to LEVERAGE UP — take a new
    ///         borrow alongside a proportional deposit in one batch — even though the excess-per-
    ///         collateral ratio (E1·C0 ≤ E0·C1) alone reports "improving". The absolute-debt cap
    ///         (maxRepay₁ ≤ maxRepay₀ for E0 > 0) blocks it. Ameliorating moves still pass.
    function morpho_borrowRampOverMaxBorrowBlocksLeverage(address collateralAsset) public noGasMetering {
        morpho_creditDeposit(collateralAsset);
        vm.startPrank(admin);
        twyneVaultManager.setBorrowBuffer(address(morpho_intermediate_vault), MO_LOAN_TOKEN, 500);
        vm.stopPrank();
        morpho_createCollateralVault(collateralAsset, twyneLiqLTV);

        vm.startPrank(alice);
        IERC20(collateralAsset).approve(address(alice_morpho_vault), type(uint256).max);
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.deposit, (COLLATERAL_AMOUNT))
        });
        evc.batch(items);
        // Borrow to maxBorrow-1 (within maxBorrow; -1 for post-action maxRepay rounding headroom).
        uint256 maxBorrow = alice_morpho_vault.maxBorrow();
        alice_morpho_vault.borrow(maxBorrow - 1, alice);
        vm.stopPrank();

        // Governance raises the buffer: no vault action, no status check — position is now over
        // maxBorrow, exactly as in morpho_borrowRampOverMaxBorrowAllowsRepay.
        vm.startPrank(admin);
        twyneVaultManager.setBorrowBuffer(address(morpho_intermediate_vault), MO_LOAN_TOKEN, 800);
        vm.stopPrank();

        uint256 debt0 = alice_morpho_vault.maxRepay();
        uint256 borrowLimit = alice_morpho_vault.maxBorrow();
        uint256 userCollateral =
            alice_morpho_vault.totalAssetsDepositedOrReserved() - alice_morpho_vault.maxRelease();
        require(debt0 > borrowLimit, "precond: position should be over maxBorrow");

        // The leverage attempt: deposit dC, then borrow dB at the (lower) borrow-LTV slope. The ratio
        // metric alone would accept this (E1/C1 < E0/C0); the absolute-debt cap must reject it.
        uint256 dC = COLLATERAL_AMOUNT / 10;
        uint256 dB = borrowLimit * dC / userCollateral;
        dB -= 1000; // margin: keep E strictly non-growing through Morpho debt-share rounding

        deal(collateralAsset, alice, COLLATERAL_AMOUNT); // fund the leverage deposit
        vm.startPrank(alice);
        IEVC.BatchItem[] memory lev = new IEVC.BatchItem[](2);
        lev[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.deposit, (dC))
        });
        lev[1] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.borrow, (dB, alice))
        });
        vm.expectRevert(TwyneErrors.T_BorrowExceedsMaxLTV.selector);
        evc.batch(lev); // FIX: leverage-up of an over-maxBorrow position is blocked

        // Surgical check: amelioration still works on the same over-maxBorrow position. A collateral
        // top-up (debt flat) succeeds — the fix blocks only net debt growth, not health-improving moves.
        deal(collateralAsset, alice, COLLATERAL_AMOUNT);
        IEVC.BatchItem[] memory topUp = new IEVC.BatchItem[](1);
        topUp[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.deposit, (COLLATERAL_AMOUNT))
        });
        evc.batch(topUp); // succeeds — debt unchanged, excess shrinks
        assertEq(alice_morpho_vault.maxRepay(), debt0, "top-up must not change debt");
        vm.stopPrank();
    }

    /// @notice Interest accrual can push a healthy position over maxBorrow without any vault action.
    ///         Morpho's maxRepay() is accrual-aware, so the next action's snapshot already sees
    ///         E0 > 0 (the over-maxBorrow regime): a further borrow is blocked by the absolute-debt
    ///         cap, while a repay ameliorates. The over-maxBorrow state here comes purely from debt
    ///         growth — not a buffer raise — exercising the same invariants via a different trigger.
    function morpho_borrowRampAccrualOverMaxBorrow(address collateralAsset) public noGasMetering {
        morpho_creditDeposit(collateralAsset);
        // High twyneLiqLTV (9800) + buffer 200 leave a gap between maxBorrow (≈9680-leg) and the
        // liquidation point, so interest can grow the debt past maxBorrow without liquidating.
        vm.startPrank(admin);
        twyneVaultManager.setBorrowBuffer(address(morpho_intermediate_vault), MO_LOAN_TOKEN, 200);
        vm.stopPrank();
        morpho_createCollateralVault(collateralAsset, 9800);

        vm.startPrank(alice);
        IERC20(collateralAsset).approve(address(alice_morpho_vault), type(uint256).max);
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_morpho_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_morpho_vault.deposit, (COLLATERAL_AMOUNT))
        });
        evc.batch(items);

        // Borrow to maxBorrow − 1 (right at the limit); the over-maxBorrow state below is purely
        // from interest accrual.
        uint256 maxBorrow = alice_morpho_vault.maxBorrow();
        alice_morpho_vault.borrow(maxBorrow - 1, alice);
        vm.stopPrank();

        // Warp: interest accrues. maxRepay() is accrual-aware, so it reflects the grown debt now.
        vm.warp(block.timestamp + 60 days);
        require(
            alice_morpho_vault.maxRepay() > alice_morpho_vault.maxBorrow(),
            "accrual did not push debt over maxBorrow (increase warp)"
        );
        assertFalse(alice_morpho_vault.canLiquidate(), "accrual pushed the position into liquidation (decrease warp)");

        vm.startPrank(alice);
        // Already over maxBorrow from accrual: a new borrow grows debt further → blocked.
        vm.expectRevert(TwyneErrors.T_BorrowExceedsMaxLTV.selector);
        alice_morpho_vault.borrow(1, alice);

        // Repay ameliorates (E0 > 0 branch: any debt reduction passes).
        IERC20(MO_LOAN_TOKEN).approve(address(alice_morpho_vault), type(uint256).max);
        uint256 debtBeforeRepay = alice_morpho_vault.maxRepay();
        alice_morpho_vault.repay(debtBeforeRepay / 4);
        assertLt(alice_morpho_vault.maxRepay(), debtBeforeRepay, "repay should reduce debt");
        vm.stopPrank();
    }
}
