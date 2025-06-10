// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {TwyneVaultTestBase, console2} from "./TwyneVaultTestBase.t.sol";
import "euler-vault-kit/EVault/shared/types/Types.sol";
import {ChainlinkOracle} from "euler-price-oracle/src/adapter/chainlink/ChainlinkOracle.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {EulerCollateralVault} from "src/twyne/EulerCollateralVault.sol";

import {BridgeHookTarget} from "src/TwyneFactory/BridgeHookTarget.sol";
import {IRMTwyneCurve} from "src/twyne/IRMTwyneCurve.sol";
import {MockPriceOracle} from "euler-vault-kit/../test/mocks/MockPriceOracle.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {HealthStatViewer} from "src/twyne/HealthStatViewer.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";

interface IWETH is IERC20 {
    receive() external payable;
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

contract OverCollateralizedTestBase is TwyneVaultTestBase {
    uint256 aliceKey; // Alice needs a private key for permit2 signing
    address alice;
    address bob = makeAddr("bob"); // benevolent bob, supplies intermediate asset
    address eve = makeAddr("eve"); // evil eve, blackhat and uses Twyne in ways we don't want
    address liquidator = makeAddr("liquidator"); // liquidator of unhealthy positions
    address teleporter = makeAddr("teleporter");

    ChainlinkOracle USDC_USD_oracle;
    EulerRouter oracleRouter;
    MockPriceOracle mockOracle;
    EulerRouter eulerExternalOracle;

    error InvalidInvariant();
    error NoConfiguredOracle();

    VaultManager twyneVaultManager;
    HealthStatViewer healthViewer;
    EulerCollateralVault alice_collateral_vault;
    EulerCollateralVault alice_WSTETH_collateral_vault;
    IEVault eeWETH_intermediate_vault;
    IEVault eeWSTETH_intermediate_vault;

    uint16 maxLTVInitial;
    uint16 externalLiqBufferInitial;
    uint16 constant twyneLiqLTV = 0.9e4;
    uint constant MAXFACTOR = 1e4;
    uint256 constant INITIAL_DEALT_ERC20 = 100 ether;
    uint256 INITIAL_DEALT_ETOKEN = 20 ether;
    uint256 CREDIT_LP_AMOUNT = 8 ether;
    uint256 COLLATERAL_AMOUNT = 5 ether;
    uint256 BORROW_USD_AMOUNT;
    uint256 WETH_USD_PRICE_INITIAL;
    uint256 constant USDC_USD_PRICE_INITIAL = 1e18 * 1e18 / 1e6;

    function newIntermediateVault(address _asset, address _oracle, address _unitOfAccount) internal returns (IEVault) {
        IEVault new_vault = IEVault(factory.createProxy(address(0), true, abi.encodePacked(_asset, _oracle, _unitOfAccount)));

        // set test values, these are placeholders for testing
        // set hook so all borrows and flashloans to use the bridge
        new_vault.setHookConfig(address(new BridgeHookTarget(address(collateralVaultFactory))), OP_BORROW | OP_LIQUIDATE | OP_FLASHLOAN | OP_SKIM);
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
        new_vault.setInterestFee(0); // set zero governance fee
        assertEq(new_vault.protocolFeeShare(), 0, "Protocol fee not zero");  // confirm zero protocol fee

        // add intermediate vault share price convert as price oracle
        twyneVaultManager.setOracleResolvedVault(address(new_vault), true);
        twyneVaultManager.setOracleResolvedVault(_asset, true); // need to set this for recursive resolveOracle() lookup
        eulerExternalOracle = EulerRouter(EulerRouter(IEVault(_asset).oracle()).getConfiguredOracle(IEVault(_asset).asset(), USD));
        assertTrue(keccak256(abi.encodePacked(eulerExternalOracle.name())) == keccak256(abi.encodePacked("ChainlinkOracle")) || keccak256(abi.encodePacked(eulerExternalOracle.name())) == keccak256(abi.encodePacked("CrossAdapter"))); // if oracle is not chainlink, then cool-off period is recommended
        twyneVaultManager.doCall(address(twyneVaultManager.oracleRouter()), 0, abi.encodeCall(EulerRouter.govSetConfig, (IEVault(_asset).asset(), USD, address(eulerExternalOracle))));
        twyneVaultManager.setIntermediateVault(new_vault);
        new_vault.setGovernorAdmin(address(twyneVaultManager));

        assertEq(new_vault.configFlags() & CFG_DONT_SOCIALIZE_DEBT, 0, "debt isn't socialized");
        return new_vault;
    }

    function dealEToken(address eToken, address receiver, uint256 amount) internal returns (uint256 received) {
        address underlyingAsset = IEVault(eToken).asset();
        // scale down the amount if the eToken has less decimals
        if (IEVault(underlyingAsset).decimals() < 18) {
            amount /= (10 ** (18 - IERC20(underlyingAsset).decimals()));
        }
        // deal the underlying asset to the user, then let them approve and deposit to the EVault
        deal(underlyingAsset, receiver, amount);
        vm.startPrank(receiver);
        IERC20(underlyingAsset).approve(eToken, type(uint256).max);

        // cache balanceBefore to measure number of eTokens received
        uint256 balanceBefore = IERC20(eToken).balanceOf(receiver);
        IEVault(eToken).deposit(amount, receiver);
        uint256 balanceAfter = IERC20(eToken).balanceOf(receiver);
        received = balanceAfter - balanceBefore;
        vm.stopPrank();
    }

    // helper function to mimic frontend functionality in determining how much asset to reserve from the intermediate vault
    function getReservedAssets(uint256 depositAmountWETH, EulerCollateralVault collateralVault) internal view returns (uint reservedAssets) {
        address targetVault = collateralVault.targetVault();
        address collateralAsset = collateralVault.asset();
        uint externalLiqBuffer =  uint(collateralVault.twyneVaultManager().externalLiqBuffers(collateralAsset));
        uint liqLTV_twyne = collateralVault.twyneLiqLTV();

        return getReservedAssets(depositAmountWETH, targetVault, collateralAsset, externalLiqBuffer, liqLTV_twyne);
    }

    function getReservedAssets(
        uint256 depositAmountWETH,
        address targetVault,
        address collateralAsset,
        uint externalLiqBuffer,
        uint liqLTV_twyne
    ) internal view returns (uint reservedAssets) {

        uint liqLTV_external = uint(IEVault(targetVault).LTVLiquidation(collateralAsset)) * externalLiqBuffer; // 1e8

        uint LTVdiff = (MAXFACTOR * liqLTV_twyne) - liqLTV_external;

        // Compute C_LP = C * (liqLTV_t - liqLTV_e) / liqLTV_e + epsilon
        reservedAssets = Math.ceilDiv(depositAmountWETH * LTVdiff, liqLTV_external);
    }

    function isValidCollateralAsset(address collateralAsset) public view returns (bool) {
        for (uint collateralIndex; collateralIndex<fixtureCollateralAssets.length; collateralIndex++) {
            if (fixtureCollateralAssets[collateralIndex] == collateralAsset) {
                return true;
            }
        }
        return false;
    }

    function isValidTargetAsset(address targetAsset) public view returns (bool) {
        for (uint targetIndex; targetIndex<fixtureTargetAssets.length; targetIndex++) {
            if (fixtureTargetAssets[targetIndex] == targetAsset) {
                return true;
            }
        }
        return false;
    }

    function setUp() public virtual override {
        super.setUp();

        (alice, aliceKey) = makeAddrAndKey("alice"); // active trader alice, trades dog coins

        // Create vault manager and configure
        vm.startPrank(admin);

        twyneVaultManager = new VaultManager(admin, address(collateralVaultFactory));

        healthViewer = new HealthStatViewer();

        // Set BORROW_USD_AMOUNT dynamically
        uint256 externalEulerLTV = IEVault(eulerUSDC).LTVBorrow(eulerWETH);
        uint256 externalScaling = 1e4;
        WETH_USD_PRICE_INITIAL = eulerOnChain.getQuote(1e18, WETH, USD);
        BORROW_USD_AMOUNT = (COLLATERAL_AMOUNT) * WETH_USD_PRICE_INITIAL * (externalEulerLTV) / (externalScaling * 1e18 * 1e12);

        // Create Euler router
        oracleRouter = new EulerRouter(address(evc), address(twyneVaultManager));
        vm.label(address(oracleRouter), "oracleRouter");

        twyneVaultManager.setOracleRouter(address(oracleRouter));
        collateralVaultFactory.setVaultManager(address(twyneVaultManager));

        vm.stopPrank();

        // Add labels
        vm.label(eulerUSDC, "eulerUSDC");
        vm.label(eulerWETH, "eulerWETH");
        vm.label(eulerWSTETH, "eulerWSTETH");
        vm.label(WETH, "WETH");

        // Create and test oracle types
        // Create mock oracle for WETH-eWETH 1-to-1 conversion
        mockOracle = new MockPriceOracle();

        vm.startPrank(admin);

        maxLTVInitial = 0.93e4;
        externalLiqBufferInitial = 1e4;
        require(twyneLiqLTV <= maxLTVInitial, "twyneLiqLTV is not set properly");

        for (uint collateralIndex; collateralIndex<fixtureCollateralAssets.length; collateralIndex++) {
            address collateralAsset = fixtureCollateralAssets[collateralIndex];
            twyneVaultManager.setMaxLiquidationLTV(collateralAsset, maxLTVInitial);
            twyneVaultManager.setExternalLiqBuffer(collateralAsset, externalLiqBufferInitial);
            // First, create the intermediate vault for each collateral asset
            IEVault intermediateVault = newIntermediateVault(collateralAsset, address(oracleRouter), USD);
            string memory intermediate_vault_label = string.concat(IEVault(collateralAsset).symbol(), " intermediate vault");
            vm.label(address(intermediateVault), intermediate_vault_label);
            // Now make sure the intermediate vault is allowed to borrow all target assets
            for (uint targetIndex; targetIndex<fixtureTargetAssets.length; targetIndex++) {
                twyneVaultManager.setAllowedTargetVault(address(intermediateVault), fixtureTargetAssets[targetIndex]);
            }
        }

        // Create eeWETH intermediate vault
        eeWETH_intermediate_vault = IEVault(twyneVaultManager.getIntermediateVault(eulerWETH)); //newIntermediateVault(eulerWETH, address(oracleRouter), USD);

        // Create eeWSTETH intermediate vault
        eeWSTETH_intermediate_vault = IEVault(twyneVaultManager.getIntermediateVault(eulerWSTETH)); //newIntermediateVault(eulerWSTETH, address(oracleRouter), USD);

        // set targetAsset -> USD oracle, specifically for the partial external liquidation edge case
        // twyneVaultManager.doCall(address(twyneVaultManager.oracleRouter()), 0, abi.encodeCall(EulerRouter.govSetConfig, (IEVault(eulerUSDC).asset(), USD, address(eulerExternalOracle))));
        for (uint targetIndex; targetIndex<fixtureTargetAssets.length; targetIndex++) {
            // address matchingOracle = eulerExternalOracle.getConfiguredOracle(IEVault(fixtureTargetAssets[targetAsset]).asset(), USD);
            address targetAssetVault = fixtureTargetAssets[targetIndex];
            address targetAsset = IEVault(targetAssetVault).asset();
            address matchingOracle = EulerRouter(IEVault(targetAssetVault).oracle()).getConfiguredOracle(targetAsset, USD);

            // Now handle the edge case of vault asset is ERC4626
            // Specifically, this is the case for Euler USDS vaults, where the vault actually has sUSDS as the asset and resolves the price of sUSDS->USDS before setting the oracle for USDS->USD
            address resolvedAddress = EulerRouter(IEVault(targetAssetVault).oracle()).resolvedVaults(targetAsset);
            if(matchingOracle == address(0) && resolvedAddress != address(0)) {
                address newTargetAsset = IEVault(targetAsset).asset();
                matchingOracle = EulerRouter(IEVault(targetAssetVault).oracle()).getConfiguredOracle(newTargetAsset, USD);
                // if a matching oracle is found (not address(0)), then the proper oracle can be set. Otherwise, revert and handle the edge case manually
                if(matchingOracle != address(0)) {
                    twyneVaultManager.setOracleResolvedVault(targetAsset, true);
                    twyneVaultManager.doCall(address(twyneVaultManager.oracleRouter()), 0, abi.encodeCall(EulerRouter.govSetConfig, (IEVault(targetAsset).asset(), USD, matchingOracle)));
                    assertEq(eulerExternalOracle.name(), "ChainlinkOracle"); // if oracle is not chainlink, then cool-off period is recommended
                } else {
                    revert NoConfiguredOracle();
                }
            } else { // else case is the normal case the vault asset is NOT an ERC4626
                twyneVaultManager.doCall(address(twyneVaultManager.oracleRouter()), 0, abi.encodeCall(EulerRouter.govSetConfig, (targetAsset, USD, matchingOracle)));
                assertEq(eulerExternalOracle.name(), "ChainlinkOracle"); // if oracle is not chainlink, then cool-off period is recommended
            }
        }


        vm.stopPrank();
        assertEq(eeWETH_intermediate_vault.governorAdmin(), address(twyneVaultManager));
        assertEq(eeWSTETH_intermediate_vault.governorAdmin(), address(twyneVaultManager));


        // Deal assets
        // First, admin needs some gas
        vm.deal(admin, 10 ether);

        address[5] memory characters = [alice, bob, eve, liquidator, teleporter];

        if (block.chainid == 1 || block.chainid == 8453) { // mainnet and base
            // nothing to do here
        } else if (block.chainid == 146) { // sonic
            // modify amounts to deposit less due to Euler's supply caps on Sonic
            uint fraction = 20;
            INITIAL_DEALT_ETOKEN /= fraction;
            CREDIT_LP_AMOUNT /= fraction;
            COLLATERAL_AMOUNT /= fraction;
            BORROW_USD_AMOUNT /= fraction;
        }

        // Deal all tokens: collateral asset eToken, collateral asset underlying, target asset eToken, target asset underlying
        for (uint charIndex; charIndex<characters.length; charIndex++) {
            // give some ether for gas
            vm.deal(characters[charIndex], 10 ether);
            // deal all the collateral assets and underlying
            for (uint collateralIndex; collateralIndex<fixtureCollateralAssets.length; collateralIndex++) {
                dealEToken(fixtureCollateralAssets[collateralIndex], characters[charIndex], INITIAL_DEALT_ETOKEN);
                deal(IEVault(fixtureCollateralAssets[collateralIndex]).asset(), characters[charIndex], INITIAL_DEALT_ERC20);
                vm.label(fixtureCollateralAssets[collateralIndex], IEVault(fixtureCollateralAssets[collateralIndex]).symbol());
            }
            // deal all the target assets and underlying
            for (uint targetIndex; targetIndex<fixtureTargetAssets.length; targetIndex++) {
                dealEToken(fixtureTargetAssets[targetIndex], characters[charIndex], INITIAL_DEALT_ETOKEN);
                deal(IEVault(fixtureTargetAssets[targetIndex]).asset(), characters[charIndex], INITIAL_DEALT_ERC20);
                vm.label(fixtureTargetAssets[targetIndex], IEVault(fixtureTargetAssets[targetIndex]).symbol());
            }
        }

    }
}
