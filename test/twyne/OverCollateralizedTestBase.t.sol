// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import {TwyneVaultTestBase, console2} from "./TwyneVaultTestBase.t.sol";
import "euler-vault-kit/EVault/shared/types/Types.sol";
import {ChainlinkOracle} from "euler-price-oracle/src/adapter/chainlink/ChainlinkOracle.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {EulerCollateralVault} from "src/twyne/EulerCollateralVault.sol";

import {BridgeHookTarget} from "src/TwyneFactory/BridgeHookTarget.sol";
import {IRMLinearKink} from "euler-vault-kit/InterestRateModels/IRMLinearKink.sol";
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
    using TypesLib for uint256;

    address bridgeFactory;

    /**
     * Assume:
     * - Twyne user Alice holds WSTETH and wants USDC
     * - Twyne depositor Bob holds aUSDC, the intermediate asset
     * - Twyne user Laura holds WSTETH, WSOL, and COMP and wants USDC
     */
    uint256 aliceKey; // Alice needs a private key for permit2 signing
    address alice;
    address bob = makeAddr("bob"); // benevolent bob, supplies intermediate asset
    address laura = makeAddr("laura"); // long tail laura, holds long tail assets
    address eve = makeAddr("eve"); // evil eve, blackhat and uses Twyne in ways we don't want
    address liquidator = makeAddr("liquidator"); // liquidator of unhealthy positions
    address teleporter = makeAddr("teleporter");

    ChainlinkOracle USDC_USD_oracle;
    EulerRouter oracleRouter;
    MockPriceOracle mockOracle;
    EulerRouter eulerExternalOracle;

    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error InvalidInvariant();

    VaultManager twyneVaultManager;
    HealthStatViewer healthViewer;
    EulerCollateralVault alice_collateral_vault;
    EulerCollateralVault alice_WSTETH_collateral_vault;
    IEVault eeWETH_intermediate_vault;
    IEVault eeWSTETH_intermediate_vault;
    address dUSDC;

    uint constant twyneLiqLTV = 0.98e4;
    uint constant MAXFACTOR = 1e4;
    uint256 constant INITIAL_DEALT_ERC20 = 1000 ether;
    uint256 INITIAL_DEALT_ETOKEN = 500 ether;
    uint256 CREDIT_LP_AMOUNT = 100 ether;
    uint256 COLLATERAL_AMOUNT = 50 ether;
    uint256 BORROW_USD_AMOUNT;
    uint256 WETH_USD_PRICE_INITIAL;
    uint256 constant USDC_USD_PRICE_INITIAL = 1e18 * 1e18 / 1e6;
    uint256 badEVKDebtAmount;

    function newIntermediateVault(address _asset, address _oracle, address _unitOfAccount) internal returns (IEVault) {
        IEVault new_vault = IEVault(factory.createProxy(address(0), true, abi.encodePacked(_asset, _oracle, _unitOfAccount)));

        // set test values, these are placeholders for testing
        // set hook so all borrows and flashloans to use the bridge
        new_vault.setHookConfig(address(new BridgeHookTarget(address(collateralVaultFactory))), OP_BORROW | OP_LIQUIDATE | OP_FLASHLOAN | OP_SKIM);
        // Base=0.00% APY,  Kink(80.00%)=20.00% APY  Max=120.00% APY
        new_vault.setInterestRateModel(address(new IRMLinearKink(0, 1681485479, 22360681293, 3435973836)));
        new_vault.setMaxLiquidationDiscount(0.2e4);
        new_vault.setLiquidationCoolOffTime(1);
        new_vault.setFeeReceiver(feeReceiver);
        new_vault.setInterestFee(0); // set zero governance fee
        assertEq(new_vault.protocolFeeShare(), 0, "Protocol fee not zero");  // confirm zero protocol fee

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

    function dealEToken(address eToken, address receiver, uint256 amount) internal returns (uint256 received) {
        if (eToken == eulerWETH) {
            vm.deal(receiver, amount);
            vm.startPrank(receiver);
            IERC20(WETH).approve(eToken, type(uint256).max);

            // cache balanceBefore to measure number of eTokens received
            uint256 balanceBefore = IERC20(eToken).balanceOf(receiver);
            IEVault(eToken).deposit(amount, receiver);
            uint256 balanceAfter = IERC20(eToken).balanceOf(receiver);
            received = balanceAfter - balanceBefore;
            vm.stopPrank();
            assertApproxEqRel(IEVault(eToken).convertToAssets(received), amount, 1e5, "wrong tokens dealt");
        }
    }

    // helper function to mimic frontend functionality in determining how much asset to reserve from the intermediate vault
    function getReservedAssets(uint256 depositAmountWETH, uint256 borrowAmountUSDC, EulerCollateralVault collateralVault) internal view returns (uint reservedAssets) {
        uint liqLTV_external = uint(IEVault(collateralVault.targetVault()).LTVLiquidation(collateralVault.asset())) * uint(collateralVault.twyneVaultManager().externalLiqBuffer()); // 1e8
        uint liqLTV_twyne = collateralVault.twyneLiqLTV();
        IEVault intermediateVault = collateralVault.intermediateVault();

        uint LTVdiff = (MAXFACTOR * liqLTV_twyne) - liqLTV_external;

        // Compute C_LP = C * (liqLTV_t - liqLTV_e) / liqLTV_e + epsilon
        reservedAssets = Math.ceilDiv(depositAmountWETH * LTVdiff, liqLTV_external);
        // reservedAssets = depositAmountWETH * ((MAXFACTOR * liqLTV_twyne) - liqLTV_external) / liqLTV_external
        // reservedAssets + depositAmountWETH = depositAmountWETH * liqLTV_twyne * MAXFACTOR

        // Compute C_max = C_LP_available * liqLTV_e / (liqLTV_t - liqLTV_e)
        uint C_max = LTVdiff == 0 ? type(uint).max : intermediateVault.cash() * liqLTV_external / LTVdiff;


        // User sets collateral amount C <= C_max
        require(depositAmountWETH < C_max, InvalidInvariant());
        // require(depositAmountWETH * LTVdiff < intermediateVault.cash() * liqLTV_external, InvalidInvariant());

        // Set max borrow to B_max = (1-borrow_buffer) * liqLTV_t * C_process
        uint B_max_eWETH = (1e4 - twyneVaultManager.externalLiqBuffer()) * liqLTV_twyne * depositAmountWETH;
        uint B_max_USD = oracleRouter.getQuote(B_max_eWETH, eulerWETH, USD);
        // User sets borrow amount B <= B_max. This is really just a frontend check, we don't need this in contracts
        require(borrowAmountUSDC <= B_max_USD, InvalidInvariant());
    }

    function setUp() public virtual override {
        super.setUp();

        (alice, aliceKey) = makeAddrAndKey("alice"); // active trader alice, trades dog coins

        // Create vault manager and configure
        vm.startPrank(admin);

        twyneVaultManager = new VaultManager(admin, address(collateralVaultFactory));
        twyneVaultManager.setMaxLiquidationLTV(0.98e4);
        twyneVaultManager.setExternalLiqBuffer(0.95e4);

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

        // fund accounts
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(laura, 10 ether);
        vm.deal(admin, 10 ether);
        vm.deal(liquidator, 10 ether);
        vm.deal(teleporter, 10 ether);

        dUSDC = IEVault(eulerUSDC).dToken();

        // Add labels
        vm.label(dUSDC, "dUSDC");
        vm.label(eulerUSDC, "eulerUSDC");
        vm.label(eulerWETH, "eulerWETH");
        vm.label(eulerWSTETH, "eulerWSTETH");
        vm.label(WETH, "WETH");

        // Create and test oracle types
        // Create mock oracle for WETH-eWETH 1-to-1 conversion
        mockOracle = new MockPriceOracle();

        vm.startPrank(admin);
        // Create eeWETH intermediate vault
        eeWETH_intermediate_vault = newIntermediateVault(eulerWETH, address(oracleRouter), USD);
        vm.label(address(eeWETH_intermediate_vault), "eeWETH_intermediate_vault");

        // Create eeWSTETH intermediate vault
        eeWSTETH_intermediate_vault = newIntermediateVault(eulerWSTETH, address(oracleRouter), USD);
        vm.label(address(eeWSTETH_intermediate_vault), "eeWSTETH_intermediate_vault");

        // Choose allowed credit/debt assets for eulerWETH
        twyneVaultManager.setAllowedTargetVault(address(eeWETH_intermediate_vault), eulerUSDC);

        // Choose allowed credit/debt assets for eulerWETH
        twyneVaultManager.setAllowedTargetVault(address(eeWSTETH_intermediate_vault), eulerUSDC);

        vm.stopPrank();
        assertEq(eeWETH_intermediate_vault.governorAdmin(), address(twyneVaultManager));
        assertEq(eeWSTETH_intermediate_vault.governorAdmin(), address(twyneVaultManager));

        address eulerRouter = IEVault(eulerWETH).oracle();
        assertEq(eulerRouter, IEVault(eulerUSDC).oracle());

        address eulerRouterGovernor = EulerRouter(eulerRouter).governor();

        vm.startPrank(eulerRouterGovernor);
        EulerRouter(eulerRouter).govSetConfig(USDC, USD, address(mockOracle));
        EulerRouter(eulerRouter).govSetConfig(eulerWETH, USD, address(mockOracle));
        vm.stopPrank();
        vm.startPrank(admin);
        // set eulerWETH price in USD
        mockOracle.setPrice(eulerWETH, USD, WETH_USD_PRICE_INITIAL);
        mockOracle.setPrice(USDC, USD, USDC_USD_PRICE_INITIAL);
        vm.stopPrank();

        // Fund protocol-specific tokens
        deal(address(WETH), alice, INITIAL_DEALT_ERC20);
        deal(address(WETH), bob, INITIAL_DEALT_ERC20);
        deal(address(WETH), eve, INITIAL_DEALT_ERC20);
        deal(address(WETH), laura, INITIAL_DEALT_ERC20);
        deal(address(WETH), liquidator, INITIAL_DEALT_ERC20);
        deal(address(WETH), teleporter, INITIAL_DEALT_ERC20);

        string memory foundryProfile = vm.envString("FOUNDRY_PROFILE");
        if (keccak256(abi.encodePacked((foundryProfile))) == keccak256(abi.encodePacked(("base"))) ||
        keccak256(abi.encodePacked((foundryProfile))) == keccak256(abi.encodePacked(("mainnet")))) {
            dealEToken(eulerWETH, alice, INITIAL_DEALT_ETOKEN);
            dealEToken(eulerWETH, bob, INITIAL_DEALT_ETOKEN);
            dealEToken(eulerWETH, eve, INITIAL_DEALT_ETOKEN);
            dealEToken(eulerWETH, laura, INITIAL_DEALT_ETOKEN);
            dealEToken(eulerWETH, liquidator, INITIAL_DEALT_ETOKEN);
            dealEToken(eulerWETH, teleporter, 10 ether);
            badEVKDebtAmount = 9286146475215740780;
        } else if (keccak256(abi.encodePacked((foundryProfile))) == keccak256(abi.encodePacked(("sonic")))) {
            // deposit less due to Sonic supply cap
            uint fraction = 20;
            INITIAL_DEALT_ETOKEN /= fraction;
            CREDIT_LP_AMOUNT /= fraction;
            COLLATERAL_AMOUNT /= fraction;
            BORROW_USD_AMOUNT /= fraction;
            dealEToken(eulerWETH, alice, INITIAL_DEALT_ETOKEN);
            dealEToken(eulerWETH, bob, INITIAL_DEALT_ETOKEN);
            dealEToken(eulerWETH, eve, INITIAL_DEALT_ETOKEN);
            dealEToken(eulerWETH, laura, INITIAL_DEALT_ETOKEN);
            dealEToken(eulerWETH, liquidator, INITIAL_DEALT_ETOKEN);
            dealEToken(eulerWETH, teleporter, 10 ether);
            badEVKDebtAmount = 806342791296464132;
        }
        deal(address(USDC), alice, INITIAL_DEALT_ERC20);
        deal(address(USDC), bob, INITIAL_DEALT_ERC20);
        deal(address(USDC), eve, INITIAL_DEALT_ERC20);
        deal(address(USDC), laura, INITIAL_DEALT_ERC20);
        deal(address(USDC), liquidator, INITIAL_DEALT_ERC20);
        deal(address(USDC), teleporter, INITIAL_DEALT_ERC20);
    }
}
