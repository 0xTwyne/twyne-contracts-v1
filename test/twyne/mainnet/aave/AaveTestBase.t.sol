// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {MainnetBase, console2} from "../MainnetBase.t.sol";
import "euler-vault-kit/EVault/shared/types/Types.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {IPool as IAaveV3Pool} from "aave-v3/interfaces/IPool.sol";
import {IAaveOracle} from "aave-v3/interfaces/IAaveOracle.sol";
import {IAToken as IAaveV3AToken} from "aave-v3/interfaces/IAToken.sol";
import {IVariableDebtToken as IAaveV3DebtToken} from "aave-v3/interfaces/IVariableDebtToken.sol";
import {IPoolAddressesProvider as IAaveV3AddressProvider} from "aave-v3/interfaces/IPoolAddressesProvider.sol";
import {IPoolDataProvider as IAaveV3DataProvider} from "aave-v3/interfaces/IPoolDataProvider.sol";
import {IPoolConfigurator} from "aave-v3/interfaces/IPoolConfigurator.sol";
import {AaveV3CollateralVault, CollateralVaultBase} from "src/twyne/AaveV3CollateralVault.sol";
import {IAaveV3ATokenWrapper} from "src/interfaces/IAaveV3ATokenWrapper.sol";
import {AaveV3ATokenWrapperOracle} from "src/twyne/AaveV3ATokenWrapperOracle.sol";
import {VaultType} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {Errors} from "euler-vault-kit/EVault/shared/Errors.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Permit2ECDSASigner} from "euler-vault-kit/../test/mocks/Permit2ECDSASigner.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {ChainlinkOracle} from "euler-price-oracle/src/adapter/chainlink/ChainlinkOracle.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {SafeERC20Lib} from "euler-vault-kit/EVault/shared/lib/SafeERC20Lib.sol";
import {BridgeHookTarget} from "src/TwyneFactory/BridgeHookTarget.sol";
import {IRMTwyneCurve} from "src/twyne/IRMTwyneCurve.sol";
import {AaveV3Wrapper} from "src/Periphery/AaveV3Wrapper.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AaveV3LeverageOperator} from "src/operators/AaveV3LeverageOperator.sol";
import {AaveV3DeleverageOperator} from "src/operators/AaveV3DeleverageOperator.sol";
import {AaveV3TeleportOperator} from "src/operators/AaveV3TeleportOperator.sol";


contract MockRewardsController {
    address token;
    constructor(address _token){
        token = _token;
    }

    function claimAllRewards(
        address[] calldata /*assets*/,
        address to
    ) external returns (address[] memory rewardsList, uint256[] memory claimedAmounts){
        uint rewardAmount = IERC20(token).balanceOf(address(this));
        IERC20(token).transfer(to, rewardAmount);
        return (rewardsList, claimedAmounts);
    }
}


contract AaveTestBase is MainnetBase {

    IAaveV3ATokenWrapper aUSDCWrapper;
    IAaveV3ATokenWrapper aWETHWrapper;
    IAaveV3ATokenWrapper aWSTETHWrapper;
    IEVault aaveEthVault;
    IAaveV3DebtToken aDebtUSDC;
    AaveV3CollateralVault alice_aave_vault;
    AaveV3CollateralVault bob_aave_vault;

    AaveV3Wrapper aaveWrapper;
    IAaveV3DataProvider aaveDataProvider;
    AaveV3ATokenWrapperOracle aTokenWrapperOracle;
    MockRewardsController rewardsController;

    AaveV3LeverageOperator aaveV3LeverageOperator;
    AaveV3DeleverageOperator aaveV3DeleverageOperator;
    AaveV3TeleportOperator aaveV3TeleportOperator;

    function setUp() public virtual override {

        forkBlock = 23600528;
        forkBlockDiff = block.number - forkBlock;

        vm.rollFork(forkBlock);

        super.setUp();

        address[5] memory characters = [alice, bob, eve, liquidator, teleporter];

        deployAaveV3WrapperVault();
        aaveDataProvider = IAaveV3DataProvider(IAaveV3AddressProvider(IAaveV3Pool(aavePool).ADDRESSES_PROVIDER()).getPoolDataProvider());
        (,,address variableDebtToken) = aaveDataProvider.getReserveTokensAddresses(USDC);

        aDebtUSDC = IAaveV3DebtToken(variableDebtToken);

        EulerRouter aaveOracleRouter = new EulerRouter(address(evc), address(twyneVaultManager));
        vm.label(address(aaveOracleRouter), "Aave oracle router");
        aTokenWrapperOracle = new AaveV3ATokenWrapperOracle(8, aavePool);

        vm.startPrank(admin);

        address collateralAsset = address(aWETHWrapper);
        twyneVaultManager.setMaxLiquidationLTV(collateralAsset, maxLTVInitial);
        twyneVaultManager.setExternalLiqBuffer(collateralAsset, externalLiqBufferInitial);
        // First, create the intermediate vault for each collateral asset
        bytes memory oracleSetData = abi.encodeCall(EulerRouter.govSetFallbackOracle, (address(aTokenWrapperOracle)));

        twyneVaultManager.doCall(address(aaveOracleRouter), 0, oracleSetData);

        aaveEthVault = newIntermediateVaultForAave(collateralAsset, address(aaveOracleRouter), USD);
        string memory intermediate_vault_label = string.concat(IEVault(collateralAsset).symbol(), " intermediate vault");
        vm.label(address(aaveEthVault), intermediate_vault_label);

        twyneVaultManager.setAllowedTargetAsset(address(aaveEthVault), aavePool, USDC);

        collateralAsset = address(aWSTETHWrapper);
        twyneVaultManager.setMaxLiquidationLTV(collateralAsset, 9800);
        twyneVaultManager.setExternalLiqBuffer(collateralAsset, externalLiqBufferInitial);
        // First, create the intermediate vault for each collateral asset
        IEVault stEthVault = newIntermediateVaultForAave(collateralAsset, address(aaveOracleRouter), USD);
        intermediate_vault_label = string.concat(IEVault(collateralAsset).symbol(), " intermediate vault");
        vm.label(address(stEthVault), intermediate_vault_label);

        twyneVaultManager.setAllowedTargetAsset(address(stEthVault), aavePool, USDC);
        twyneVaultManager.setAllowedTargetAsset(address(stEthVault), aavePool, WETH);
        collateralVaultFactory.setCategoryId(aavePool, collateralAsset, WETH, 1);
        rewardsController = new MockRewardsController(WETH);
        address aWETHWrapperCollateralVaultImpl = address(new AaveV3CollateralVault(address(evc), aavePool, address(rewardsController)));

        collateralVaultFactory.setBeacon(aavePool, address(new UpgradeableBeacon(aWETHWrapperCollateralVaultImpl, admin)));

        vm.stopPrank();

        fixtureCollateralAssets = [address(aWETHWrapper), address(aWSTETHWrapper)];
        fixtureTargetAssets = [USDC, WETH];

        // Deal all tokens: collateral asset eToken, collateral asset underlying, target asset eToken, target asset underlying
        for (uint charIndex; charIndex<characters.length; charIndex++) {
            // give some ether for gas
            vm.deal(characters[charIndex], 10 ether);
            // deal all the collateral assets and underlying
            for (uint collateralIndex; collateralIndex<fixtureCollateralAssets.length; collateralIndex++) {
                dealWrapperToken(fixtureCollateralAssets[collateralIndex], characters[charIndex], INITIAL_DEALT_ETOKEN);
                deal(IAaveV3ATokenWrapper(fixtureCollateralAssets[collateralIndex]).asset(), characters[charIndex], INITIAL_DEALT_ERC20);
                vm.label(fixtureCollateralAssets[collateralIndex], IAaveV3ATokenWrapper(fixtureCollateralAssets[collateralIndex]).symbol());
            }

            // deal all the target assets and underlying
            for (uint targetIndex; targetIndex<fixtureTargetAssets.length; targetIndex++) {
                deal(fixtureTargetAssets[targetIndex], characters[charIndex], INITIAL_DEALT_ERC20);
                vm.label(fixtureTargetAssets[targetIndex], IERC20(fixtureTargetAssets[targetIndex]).symbol());
            }
        }

        WETH_USD_PRICE_INITIAL = eulerOnChain.getQuote(1e18, WETH, USD);
        uint borrowLTV = getBorrowLTV(address(aWETHWrapper));
        BORROW_USD_AMOUNT = (COLLATERAL_AMOUNT) * WETH_USD_PRICE_INITIAL * (borrowLTV) / (1e4 * 1e18 * 1e12);

        aaveWrapper = new AaveV3Wrapper(address(evc), WETH);

        // Deploy operators using the existing morpho from base test
        aaveV3LeverageOperator = new AaveV3LeverageOperator(
            address(evc),
            eulerSwapper, // Use the same swapper setup as Euler tests
            morpho, // Use the morpho from base test
            address(collateralVaultFactory),
            permit2,
            aavePool
        );

        aaveV3DeleverageOperator = new AaveV3DeleverageOperator(
            address(evc),
            eulerSwapper,
            morpho,
            address(collateralVaultFactory),
            permit2,
            aavePool
        );

        aaveV3TeleportOperator = new AaveV3TeleportOperator(
            address(evc),
            morpho,
            address(collateralVaultFactory),
            permit2,
            aavePool
        );

        vm.label(address(aaveV3LeverageOperator), "AaveV3LeverageOperator");
        vm.label(address(aaveV3DeleverageOperator), "AaveV3DeleverageOperator");
        vm.label(address(aaveV3TeleportOperator), "AaveV3TeleportOperator");
    }

    // helper function to mimic frontend functionality in determining how much asset to reserve from the intermediate vault
    function getReservedAssetsForAave(uint256 depositAmountWETH, AaveV3CollateralVault collateralVault) internal view returns (uint reservedAssets) {
        address collateralAsset = collateralVault.asset();
        uint externalLiqBuffer =  uint(collateralVault.twyneVaultManager().externalLiqBuffers(collateralAsset));
        uint liqLTV_twyne = collateralVault.twyneLiqLTV();

        uint liqLTV_external = getLiqLTV(collateralAsset) * externalLiqBuffer; // 1e8

        uint LTVdiff = (MAXFACTOR * liqLTV_twyne) - liqLTV_external;

        // Compute C_LP = C * (liqLTV_t - liqLTV_e) / liqLTV_e + epsilon
        reservedAssets = Math.ceilDiv(depositAmountWETH * LTVdiff, liqLTV_external);
    }

    function dealWrapperToken(address wrapper, address receiver, uint amount) internal {
        address underlyingAsset = IAaveV3ATokenWrapper(wrapper).asset();

        // deal the underlying asset to the user, then let them approve and deposit to the EVault
        deal(underlyingAsset, receiver, amount);
        vm.startPrank(receiver);
        IERC20(underlyingAsset).approve(wrapper, type(uint256).max);

        // cache balanceBefore to measure number of eTokens received
        IAaveV3ATokenWrapper(wrapper).deposit(amount, receiver);

        vm.stopPrank();
    }


    function newIntermediateVaultForAave(address _asset, address _oracle, address _unitOfAccount) internal returns (IEVault) {
        IEVault new_vault = IEVault(factory.createProxy(address(0), true, abi.encodePacked(_asset, _oracle, _unitOfAccount)));
        // set test values, these are placeholders for testing
        // set hook so all borrows and flashloans to use the bridge
        new_vault.setHookConfig(address(new BridgeHookTarget(address(collateralVaultFactory))), OP_BORROW | OP_LIQUIDATE | OP_FLASHLOAN | OP_PULL_DEBT);
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
        twyneVaultManager.setOracleResolvedVaultForOracleRouter(_oracle, address(new_vault), true);
        twyneVaultManager.setOracleResolvedVaultForOracleRouter(_oracle, _asset, true); // need to set this for recursive resolveOracle() lookup

        address underlyingCollateralAsset = IAaveV3ATokenWrapper(_asset).asset();
        address aaveExternalOracle = getAaveOracleFeed(underlyingCollateralAsset);
        require(aaveExternalOracle != address(0), "aave doesn't support this asset oracle");

        twyneVaultManager.doCall(_oracle, 0, abi.encodeCall(EulerRouter.govSetConfig, (_asset, USD, address(aTokenWrapperOracle))));
        twyneVaultManager.setIntermediateVault(new_vault);
        new_vault.setGovernorAdmin(address(twyneVaultManager));

        assertEq(new_vault.configFlags() & CFG_DONT_SOCIALIZE_DEBT, 0, "debt isn't socialized");
        return new_vault;
    }


    function deployAaveV3WrapperVault() internal {
        // Read the artifact JSON file and parse the bytecode
        string memory artifactJson = vm.readFile("artifacts/AaveV3ATokenWrapper.json");
        bytes memory aTokenWrapperCreationCode = vm.parseJsonBytes(artifactJson, ".bytecode.object");
        bytes memory constructorArgs = abi.encode(address(evc), address(collateralVaultFactory), aavePool, 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb);
        bytes memory aTokenWrapperInitCode = abi.encodePacked(aTokenWrapperCreationCode, constructorArgs);

        address aTokenWrapperImpl;
        assembly {
            aTokenWrapperImpl := create(0, add(aTokenWrapperInitCode, 0x20), mload(aTokenWrapperInitCode))
            if iszero(aTokenWrapperImpl) {
                revert(0, 0)
            }
        }

        assertGt(aTokenWrapperImpl.code.length, 0, "AToken wrapper address has no code");

        address aUSDC = IAaveV3Pool(aavePool).getReserveAToken(USDC);
        bytes memory proxyInitData = abi.encodeCall(
            IAaveV3ATokenWrapper.initialize,
            (
                IAaveV3Pool(aavePool).getReserveAToken(USDC),
                address(twyneVaultManager),
                "A-Stat-USDC",
                "ASUSDC"
            )
        );

        aUSDCWrapper = IAaveV3ATokenWrapper(address(new ERC1967Proxy(aTokenWrapperImpl, proxyInitData)));
        assertEq(aUSDCWrapper.owner(), address(twyneVaultManager), "aUSDC wrapper has wrong owner");
        assertEq(aUSDCWrapper.aToken(), aUSDC, "aUSDC wrapper has wrong aToken");

        address aWETH = IAaveV3Pool(aavePool).getReserveAToken(WETH);
        proxyInitData = abi.encodeCall(
            IAaveV3ATokenWrapper.initialize,
            (
                IAaveV3Pool(aavePool).getReserveAToken(WETH),
                address(twyneVaultManager),
                "A-Stat-WETH",
                "ASWETH"
            )
        );

        aWETHWrapper = IAaveV3ATokenWrapper(address(new ERC1967Proxy(aTokenWrapperImpl, proxyInitData)));
        assertEq(aWETHWrapper.owner(), address(twyneVaultManager),  "aWETH wrapper has wrong owner");
        assertEq(aWETHWrapper.aToken(), aWETH, "aWETH wrapper has wrong aToken");

        address aWSTETH = IAaveV3Pool(aavePool).getReserveAToken(WSTETH);
        proxyInitData = abi.encodeCall(
            IAaveV3ATokenWrapper.initialize,
            (
                aWSTETH,
                address(twyneVaultManager),
                "A-Stat-WSTETH",
                "WSTETH"
            )
        );

        aWSTETHWrapper = IAaveV3ATokenWrapper(address(new ERC1967Proxy(aTokenWrapperImpl, proxyInitData)));
        assertEq(aWSTETHWrapper.owner(), address(twyneVaultManager), "aWSTETH wrapper has wrong owner");
        assertEq(aWSTETHWrapper.aToken(), aWSTETH, "aWSTETH wrapper has wrong aToken");
    }



    function aave_bob_createCollateralVault(address collateralAssets, uint16 liqLTV) public noGasMetering {
        // copy logic from checkLiqLTV


        // Alice creates aWETH collateral vault with USDC target asset
        vm.startPrank(bob);
        bob_aave_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _asset: collateralAssets,
                _targetVault: aavePool,
                _liqLTV: liqLTV,
                _targetAsset: USDC
            })
        );
        vm.stopPrank();

        vm.label(address(bob_aave_vault), "bob_aave_vault");
    }



    function aave_single_flow() public {
        aave_createCollateralVault(address(aWETHWrapper), 9100);

        vm.startPrank(bob);
        IERC20(WETH).approve(address(aWETHWrapper), 100000e18);
        aWETHWrapper.deposit(100e18, bob);
        aWETHWrapper.approve(address(aaveEthVault), 1000e18);
        aaveEthVault.deposit(100e18, bob);
        vm.stopPrank();

        address user1 = makeAddr('user1');
        vm.startPrank(user1);
        deal(WETH, user1, 50e18);
        IERC20(WETH).approve(address(aWETHWrapper), 100000e18);
        uint shares = aWETHWrapper.deposit(50e18, user1);
        aWETHWrapper.approve(address(aaveEthVault), 1000e18);
        aaveEthVault.deposit(shares, user1);
        vm.stopPrank();

        console2.log("Balance of wrapper in collateral vault pre deposit: ", aWETHWrapper.balanceOf(address(alice_aave_vault)));
        vm.startPrank(alice);
        IERC20(WETH).approve(address(alice_aave_vault), 100000e18);
        alice_aave_vault.depositUnderlying(100e18);
        console2.log("Balance of wrapper in collateral vault pre borrow: ", aWETHWrapper.balanceOf(address(alice_aave_vault)));
        alice_aave_vault.borrow(100e6, address(0x1337));
        console2.log("Balance of wrapper in collateral vault pre repay: ", aWETHWrapper.balanceOf(address(alice_aave_vault)));
        uint initAmountToWithdraw = alice_aave_vault.balanceOf(address(alice_aave_vault));
        vm.warp(block.timestamp + 100);

        IERC20(USDC).approve(address(alice_aave_vault), 1000e12);
        alice_aave_vault.repay(type(uint).max);
        uint256 amountToWithdraw = alice_aave_vault.balanceOf(address(alice_aave_vault));
        console2.log("Balance of wrapper in collateral vault pre withdraw: ", aWETHWrapper.balanceOf(address(alice_aave_vault)));
        console2.log("Amount to withdraw: ", amountToWithdraw);
        vm.expectRevert();
        alice_aave_vault.withdraw(amountToWithdraw + 1, alice);

        alice_aave_vault.withdraw(amountToWithdraw, alice);
        // due to added interest
        assertLe(amountToWithdraw, initAmountToWithdraw);

        uint assets = aWETHWrapper.redeem(amountToWithdraw, alice, alice);

        assertGe(assets, 100e18);

        console2.log("Net assets received: ", assets);
        vm.stopPrank();
        console2.log("Balance of wrapper in collateral vault: ", aWETHWrapper.balanceOf(address(alice_aave_vault)));
        console2.log("Balance of intermediate vault: ", aWETHWrapper.balanceOf(address(aaveEthVault)));


        vm.startPrank(bob);

        uint256 wrapperAmountBob = aaveEthVault.redeem(aaveEthVault.balanceOf(bob), bob, bob);
        aWETHWrapper.redeem(wrapperAmountBob, bob, bob);

        vm.stopPrank();


        vm.startPrank(user1);

        uint256 wrapperAmountUser1 = aaveEthVault.redeem(aaveEthVault.balanceOf(user1), user1, user1);
        aWETHWrapper.redeem(wrapperAmountUser1, user1, user1);

        vm.stopPrank();


    }


    function aave_flow_multiple() public {

        aave_createCollateralVault(address(aWETHWrapper), 9100);
        console2.log("Balance of wrapper in collateral vault pre deposit: ", aWETHWrapper.balanceOf(address(alice_aave_vault)));
        vm.startPrank(alice);
        IERC20(WETH).approve(address(alice_aave_vault), 100000e18);
        alice_aave_vault.depositUnderlying(10e18);
        console2.log("Balance of wrapper in collateral vault pre borrow: ", aWETHWrapper.balanceOf(address(alice_aave_vault)));
        alice_aave_vault.borrow(100e6, address(0x1337));
        console2.log("Balance of wrapper in collateral vault pre repay: ", aWETHWrapper.balanceOf(address(alice_aave_vault)));

        vm.stopPrank();
        console2.log("Balance of wrapper in collateral vault: ", aWETHWrapper.balanceOf(address(alice_aave_vault)));
        console2.log("Balance of intermediate vault: ", aWETHWrapper.balanceOf(address(aaveEthVault)));
        vm.warp(block.timestamp + 1000);
        aave_bob_createCollateralVault(address(aWETHWrapper), 9100);
        console2.log("Balance of wrapper in collateral vault pre deposit: ", aWETHWrapper.balanceOf(address(bob_aave_vault)));
        vm.startPrank(bob);
        IERC20(WETH).approve(address(bob_aave_vault), 100000e18);
        bob_aave_vault.depositUnderlying(10e18);
        console2.log("Balance of wrapper in collateral vault pre borrow: ", aWETHWrapper.balanceOf(address(bob_aave_vault)));
        bob_aave_vault.borrow(100e6, address(0x1337));
        console2.log("Balance of wrapper in collateral vault pre repay: ", aWETHWrapper.balanceOf(address(bob_aave_vault)));

        vm.stopPrank();
        console2.log("Balance of wrapper in collateral vault: ", aWETHWrapper.balanceOf(address(bob_aave_vault)));
        console2.log("Balance of intermediate vault: ", aWETHWrapper.balanceOf(address(aaveEthVault)));

    }


    function aave_creditDeposit(address collateralAssets) public noGasMetering {
        // This function assumes collateralAssets is address(aWETHWrapper)
        vm.assume(isValidCollateralAsset(collateralAssets));
        IEVault intermediate_vault = IEVault(twyneVaultManager.getIntermediateVault(collateralAssets));

        // Bob deposits WETH into aWETHWrapper, then aWETHWrapper tokens into the intermediate_vault
        vm.startPrank(bob);
        // Step 2: Deposit wrapped tokens into the intermediate vault
        IERC20(collateralAssets).approve(address(intermediate_vault), type(uint256).max);
        intermediate_vault.deposit(CREDIT_LP_AMOUNT, bob); // Deposit wrapped tokens
        vm.stopPrank();

        // Check total assets in the intermediate vault
        assertEq(intermediate_vault.totalAssets(), CREDIT_LP_AMOUNT, "Incorrect CREDIT_LP_AMOUNT deposited");
    }

    function aave_collateralDeposit(uint256 amount) internal {
        vm.startPrank(alice);
        IERC20(WETH).approve(address(alice_aave_vault), type(uint).max);
        alice_aave_vault.depositUnderlying(amount);
        vm.stopPrank();
    }


    function aave_createCollateralVault(address collateralAssets, uint16 liqLTV) public noGasMetering {
        aave_createCollateralVault(collateralAssets, liqLTV, USDC);
    }

    function aave_createCollateralVault(address collateralAssets, uint16 liqLTV, address debtAsset) public noGasMetering {
        vm.assume(isValidCollateralAsset(collateralAssets));
        uint16 minLTV = uint16(getLiqLTV(collateralAssets, debtAsset));
        uint16 extLiqBuffer = twyneVaultManager.externalLiqBuffers(collateralAssets);
        vm.assume(uint(minLTV) * uint(extLiqBuffer) <= uint256(liqLTV) * MAXFACTOR);
        vm.assume(liqLTV <= twyneVaultManager.maxTwyneLTVs(collateralAssets));

        aave_creditDeposit(collateralAssets);

        // Alice creates eWETH collateral vault with USDC target asset
        vm.startPrank(alice);
        alice_aave_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _asset: collateralAssets,
                _targetVault: aavePool,
                _liqLTV: liqLTV,
                _targetAsset: debtAsset
            })
        );
        vm.stopPrank();

        vm.label(address(alice_aave_vault), "alice_aave_vault");
    }

    function aave_totalAssetsIntermediateVault(address collateralAssets, uint16 liqLTV) public {
        // Sets up credit deposit and creates the vault
        aave_createCollateralVault(collateralAssets, liqLTV);

        IEVault intermediate_vault = IEVault(twyneVaultManager.getIntermediateVault(collateralAssets));

        uint256 wrappedBalance = IAaveV3ATokenWrapper(collateralAssets).balanceOf(address(intermediate_vault));
        // eve donates aWETHWrapper tokens to the intermediate vault, ensure this doesn't increase its totalAssets
        vm.startPrank(eve);

        // aWETHWrapper's balance in intermediate vault before transfer should equal intermediate vault's total assets
        assertEq(wrappedBalance, intermediate_vault.totalAssets(), "totalAssets value mismatch before airdrop");
        assertEq(wrappedBalance, CREDIT_LP_AMOUNT);

        // Eve transfers wrapped tokens (aWETHWrapper) to the intermediate vault address
        IERC20(collateralAssets).transfer(address(intermediate_vault), CREDIT_LP_AMOUNT);

        // totalAssets should remain the same as the deposit logic of the EVault should filter out direct transfers
        assertEq(intermediate_vault.totalAssets(), CREDIT_LP_AMOUNT, "totalAssets value mismatch after airdrop 1");
        // But the raw token balance in the intermediate vault should increase
        assertEq(IERC20(collateralAssets).balanceOf(address(intermediate_vault)), 2 * CREDIT_LP_AMOUNT);

        // Skim the airdropped amount
        intermediate_vault.skim(CREDIT_LP_AMOUNT, eve);
        vm.stopPrank();

        // totalAssets should now reflect the skimmed amount being converted to shares
        // Since `totalAssets()` is `totalSupply * sharePrice`, and skim uses `deposit` logic,
        // it effectively converts the skimmed amount into shares for the skim recipient (Eve).
        // Since `totalAssets()` is generally `assetBalance + borrowedAssets - liability`, for EVault it's
        // typically `totalSupply * pricePerShare`. A direct skim is usually treated as a deposit,
        // which increases the total assets and total supply proportionally.
        // Assuming the skim logic essentially creates shares for the skim recipient:
        assertEq(intermediate_vault.totalAssets(), 2 * CREDIT_LP_AMOUNT, "skim failed after airdrop 1");
        assertEq(intermediate_vault.balanceOf(eve), CREDIT_LP_AMOUNT, "skim failed after airdrop 1");
    }



    function aave_totalAssetsCollateralVault(address collateralAssets, uint16 liqLTV) public {
        // Set up the system and create the vault
        aave_createCollateralVault(collateralAssets, liqLTV);

        vm.startPrank(eve);

        IERC20(collateralAssets).transfer(address(alice_aave_vault), COLLATERAL_AMOUNT);
        vm.stopPrank();

        assertEq(alice_aave_vault.totalAssetsDepositedOrReserved(), 0);
        assertEq(alice_aave_vault.balanceOf(address(alice_aave_vault)), 0);
        assertEq(
            IERC20(collateralAssets).balanceOf(address(alice_aave_vault)),
            COLLATERAL_AMOUNT,
            "Collateral vault not holding correct eulerWETH balance"
        );
    }


    function aave_collateralDepositWithoutBorrow(address collateralAssets, uint16 liqLTV) public {
        // Set up the system and create the vault
        aave_createCollateralVault(collateralAssets, liqLTV);

        // Alice deposits collateral (WETH) into the vault, which wraps and deposits it
        vm.startPrank(alice);
        assertEq(alice_aave_vault.borrower(), alice);

        IERC20(collateralAssets).approve(address(alice_aave_vault), type(uint).max);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        // reserve assets from intermediate vault
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.deposit, (COLLATERAL_AMOUNT))
        });

        evc.batch(items);

        vm.stopPrank();



        // Check the collateral vault's state
        // totalAssetsDepositedOrReserved should be non-zero after a proper deposit
        assertGt(alice_aave_vault.totalAssetsDepositedOrReserved(), 0);
        // alice should have shares in her vault
        assertGt(alice_aave_vault.balanceOf(address(alice_aave_vault)), 0);

        // Bob tries to deposit but reverts because depositUnderlying should be restricted to the borrower (Alice)
        // The original test used a general `deposit` which is usually via EVC and subject to specific vault logic.
        // For AaveV3CollateralVault, the logic is likely: deposit WETH -> get aWETHWrapper -> deposit aWETHWrapper into self.
        // We'll test `depositUnderlying` since that's what's used in `test_aave_single_flow`.
        vm.startPrank(bob);
        IERC20(WETH).approve(address(alice_aave_vault), type(uint).max);
        // It should revert because the AaveV3CollateralVault's `depositUnderlying` may restrict deposits to the borrower.
        // Assuming it will revert with a general error or one specific to the underlying EVault/Twyne logic if not borrower.
        // Since `test_aave_single_flow` uses `depositUnderlying`, and the Aave collateral vault is designed for one user:
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_aave_vault.depositUnderlying(COLLATERAL_AMOUNT);
        vm.stopPrank();
    }


    function aave_collateralDepositWithBorrow(address collateralAssets) public {
        // Set up the system and create the vault with a base LTV
        uint16 liqLTV = 9100;
        aave_createCollateralVault(collateralAssets, liqLTV);
        uint aliceUSDCBalanceBefore = IERC20(USDC).balanceOf(alice);

        // Calculate a safe borrow amount. For Aave, max borrow is related to max LTV and the value of collateral.
        // Since we don't have Euler-like functions here, we'll borrow a fixed, safe amount (e.g., $1000)
        uint256 borrowAmountUSDC = 1000e6; // $1000 in USDC (6 decimals)

        // Borrow USDC
        vm.startPrank(alice);
        IERC20(collateralAssets).approve(address(alice_aave_vault), type(uint).max);

        uint256 oneEther = 10 ** uint256(IERC20(collateralAssets).decimals());

        // Some shared logic with test_e_maxBorrowFromEulerDirect()
        alice_aave_vault.setTwyneLiqLTV(liqLTV * uint(twyneVaultManager.externalLiqBuffers(alice_aave_vault.asset())) / MAXFACTOR);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        // reserve assets from intermediate vault
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.deposit, (oneEther))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.borrow, (borrowAmountUSDC, alice))
        });

        evc.batch(items);

        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(WETH).approve(address(alice_aave_vault), type(uint).max);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_aave_vault.depositUnderlying(1);
        vm.stopPrank();

        uint aliceUSDCBalanceAfter = IERC20(USDC).balanceOf(alice);
        assertEq(aliceUSDCBalanceAfter - aliceUSDCBalanceBefore, borrowAmountUSDC, "Unexpected amount of USDC held by Alice");
    }


    function aave_second_creditDeposit(address collateralAssets) public noGasMetering {
        aave_creditDeposit(collateralAssets);
        IEVault intermediate_vault = IEVault(twyneVaultManager.getIntermediateVault(collateralAssets));
        // Bob deposits more into the intermediate_vault
        vm.startPrank(bob);
        intermediate_vault.deposit(CREDIT_LP_AMOUNT, bob);

        // Confirm complete withdrawal from intermediate vault works
        assertApproxEqRel(intermediate_vault.totalAssets(), 2 * CREDIT_LP_AMOUNT, 1e5);
        intermediate_vault.withdraw(2 * CREDIT_LP_AMOUNT, bob, bob);
        vm.stopPrank();
    }

    function aave_creditWithdrawNoInterest(address collateralAssets) public {
        aave_creditDeposit(collateralAssets);
        IEVault intermediate_vault = IEVault(twyneVaultManager.getIntermediateVault(collateralAssets));

        assertEq(intermediate_vault.totalAssets(), CREDIT_LP_AMOUNT, "totalAssets isn't the expected value");
        assertEq(intermediate_vault.balanceOf(bob), CREDIT_LP_AMOUNT, "bob has wrong balance");

        // Credit LP Bob withdraws all
        vm.startPrank(bob);
        intermediate_vault.withdraw(CREDIT_LP_AMOUNT, bob, bob);
        vm.stopPrank();

        assertEq(intermediate_vault.totalAssets(), 0);
    }


    function aave_supplyCap_creditDeposit(address collateralAssets) public {
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


    function aave_creditWithdrawWithInterestAndNoFees(address collateralAssets, uint warpBlockAmount) public noGasMetering {
        vm.assume(warpBlockAmount < forkBlockDiff);
        aave_collateralDepositWithoutBorrow(collateralAssets, 0.9e4);

        IEVault intermediate_vault = IEVault(twyneVaultManager.getIntermediateVault(collateralAssets));

        // Confirm fees setup
        assertEq(intermediate_vault.interestFee(), 0, "Unexpected intermediate vault interest fee");
        assertEq(intermediate_vault.feeReceiver(), feeReceiver, "fee receiver address is wrong");
        assertEq(intermediate_vault.protocolFeeShare(), 0, "Unexpected intermediate vault interest fee");


        // 2. Warp time to accrue interest
        vm.roll(block.number + warpBlockAmount);
        vm.warp(block.timestamp + 365 days);

        // Confirm vault is rebalanceable
        assertGt(alice_aave_vault.canRebalance(), 0, "Vault is not rebalanceable");

        // 4. Alice withdraws her collateral
        vm.startPrank(alice);
        uint256 aliceShares = alice_aave_vault.balanceOf(address(alice_aave_vault));
        alice_aave_vault.withdraw(aliceShares, alice);
        vm.stopPrank();

        // Alice should have some aWETHWrapper tokens now
        assertGt(aWETHWrapper.balanceOf(alice), 0, "Alice should have aWETHWrapper tokens");
        assertEq(IERC20(collateralAssets).balanceOf(address(alice_aave_vault)), 0, "Incorrect aWETHWrapper balance remaining in vault");
        // 5. Credit LP Bob withdraws all with accrued interest
        vm.startPrank(bob);
        intermediate_vault.redeem(type(uint).max, bob, bob);
        intermediate_vault.convertFees(); // Should do nothing as fees are 0
        vm.stopPrank();

        // Confirm zero accrued fees in intermediate vault
        assertEq(intermediate_vault.accumulatedFees(), 0, "Should have zero accumulated fees");

        assertApproxEqAbs(intermediate_vault.totalSupply(), 0, 10, "Intermediate vault is not empty as expected!");
    }


    function aave_creditWithdrawWithInterestAndFees(address collateralAssets) public noGasMetering {

        aave_collateralDepositWithoutBorrow(collateralAssets, 0.9e4);

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
        assertGt(alice_aave_vault.canRebalance(), 0, "Vault is not rebalanceable even with time passing");

        console2.log("Can be rebalanced now strating withdraw");
        // 5. Alice withdraws her collateral
        vm.startPrank(alice);
        uint256 aliceShares = alice_aave_vault.balanceOf(address(alice_aave_vault));
        alice_aave_vault.withdraw(aliceShares, alice);
        vm.stopPrank();

        assertEq(IERC20(collateralAssets).balanceOf(address(alice_aave_vault)), 0, "Incorrect aWethWrapper balance remaining in vault");

        // 6. Credit LP Bob withdraws all (leaving only fees)
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



    // Deposit WETH instead of eWETH into Twyne
    // This allows users to bypass the Euler Finance frontend entirely
    function aave_collateralDepositUnderlying(address collateralAssets) public noGasMetering {
        // 1. Setup liquidity and create vault
        aave_createCollateralVault(collateralAssets, 9100);

        vm.startPrank(alice);
        assertEq(alice_aave_vault.borrower(), alice);

        // 2. Alice approves underlying asset to the vault
        address underlyingAsset = IAaveV3ATokenWrapper(collateralAssets).asset();
        IERC20(underlyingAsset).approve(address(alice_aave_vault), type(uint).max);

        // 3. Deposit WETH (underlying) directly into the collateral vault
        // AaveV3CollateralVault handles wrapping WETH -> aWETHWrapper and depositing
        alice_aave_vault.depositUnderlying(COLLATERAL_AMOUNT);

        vm.stopPrank();

        // Assertions: The vault should hold wrapped tokens (aWETHWrapper)
        assertGt(alice_aave_vault.balanceOf(address(alice_aave_vault)), 0, "Alice did not receive shares");
        assertApproxEqAbs(IAaveV3ATokenWrapper(collateralAssets).convertToAssets(alice_aave_vault.totalAssetsDepositedOrReserved() - alice_aave_vault.maxRelease()), COLLATERAL_AMOUNT, 1, "Total assets mismatch");
    }


    // Test Permit2 deposit of aWETHWrapper (wrapped collateral)
    function aave_permit2CollateralDeposit(address collateralAssets) public noGasMetering {
        aave_creditDeposit(collateralAssets);

        (address user, uint privKey) = makeAddrAndKey("permit2user");
        address wrappedCollateral = collateralAssets;
        uint256 wrappedAmount = 100e18; // Amount of aWETHWrapper tokens to deposit

        vm.startPrank(user);

        // 1. User creates an Aave vault
        AaveV3CollateralVault user_aave_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _asset: wrappedCollateral,
                _targetVault: aavePool,
                _liqLTV: twyneLiqLTV,
                _targetAsset: USDC
            })
        );

        // 2. Give the user the wrapped collateral asset (aWETHWrapper)
        // Deposit WETH to get aWETHWrapper tokens
        vm.expectRevert();
        aWETHWrapper.deposit(wrappedAmount, user);
        vm.stopPrank();

        vm.label(address(user_aave_vault), "user_collateral_vault");
        dealWrapperToken(wrappedCollateral, user, INITIAL_DEALT_ETOKEN);

        vm.startPrank(user);
        // 3. User approves Permit2 to spend the wrapped collateral
        IERC20(wrappedCollateral).approve(permit2, type(uint).max);

        // 4. Create Permit2 signature for the wrapped collateral
        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: wrappedCollateral,
                amount: uint160(COLLATERAL_AMOUNT), // Using COLLATERAL_AMOUNT from test setup
                expiration: type(uint48).max,
                nonce: 0
            }),
            spender: address(user_aave_vault),
            sigDeadline: type(uint256).max
        });

        Permit2ECDSASigner permit2Signer = new Permit2ECDSASigner(address(permit2));
        uint256 reservedAmount = getReservedAssetsForAave(COLLATERAL_AMOUNT, user_aave_vault);
        // 5. Build a deposit batch with Permit2
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

        // 6. Deposit wrapped collateral (aWETHWrapper) via the vault's deposit function
        items[1].targetContract = address(user_aave_vault);
        items[1].onBehalfOfAccount = user;
        items[1].value = 0;
        items[1].data = abi.encodeCall(user_aave_vault.deposit, (uint160(COLLATERAL_AMOUNT)));

        evc.batch(items);
        vm.stopPrank();

        uint collateralAssetBalance = IERC20(wrappedCollateral).balanceOf(address(user_aave_vault));
        // Aave collateral vault has no reserved assets, so balance = deposit amount
        assertGt(collateralAssetBalance, 0, "Permit2 deposit failed");
        assertEq(collateralAssetBalance, COLLATERAL_AMOUNT + reservedAmount, "Permit2: Unexpected amount of collateralAsset in collateral vault");
    }


    // Test Permit2 deposit of WETH (not eWETH)
    // Test Permit2 deposit of WETH (underlying collateral)
    function aave_permit2_CollateralDepositUnderlying(address collateralAssets) public noGasMetering {
        aave_creditDeposit(collateralAssets);

        (address user, uint privKey) = makeAddrAndKey("permit2user");
        address underlyingAsset = IAaveV3ATokenWrapper(collateralAssets).asset();

        vm.startPrank(user);

        // 1. User creates an Aave vault
        AaveV3CollateralVault user_aave_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _asset: collateralAssets,
                _targetVault: aavePool,
                _liqLTV: twyneLiqLTV,
                _targetAsset: USDC
            })
        );

        vm.expectRevert();
        user_aave_vault.deposit(uint160(COLLATERAL_AMOUNT));


        // 2. Give the user the underlying asset (WETH)
        deal(underlyingAsset, user, INITIAL_DEALT_ERC20);

        // 3. User approves Permit2 to spend the underlying WETH
        IERC20(underlyingAsset).approve(permit2, type(uint).max);

        // 4. Create Permit2 signature for WETH
        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: underlyingAsset,
                amount: uint160(COLLATERAL_AMOUNT),
                expiration: type(uint48).max,
                nonce: 0
            }),
            spender: address(user_aave_vault),
            sigDeadline: type(uint256).max
        });

        Permit2ECDSASigner permit2Signer = new Permit2ECDSASigner(address(permit2));

        // 5. Build a deposit batch with Permit2
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

        // 6. Deposit WETH via the vault's depositUnderlying function
        items[1].targetContract = address(user_aave_vault);
        items[1].onBehalfOfAccount = user;
        items[1].value = 0;
        items[1].data = abi.encodeCall(user_aave_vault.depositUnderlying, (COLLATERAL_AMOUNT));

        evc.batch(items);
        vm.stopPrank();

    }


    // Test the creation of a collateral vault in a batch (the frontend does this)
    // Test the creation of an Aave collateral vault in a batch
    function aave_evcCanCreateCollateralVault(address collateralAssets) public noGasMetering {

        vm.assume(isValidCollateralAsset(collateralAssets));

        vm.startPrank(alice);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(collateralVaultFactory),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(collateralVaultFactory.createCollateralVault, (VaultType.AAVE_V3, collateralAssets, aavePool, twyneLiqLTV, USDC))
        });

        // 1. Simulate the batch to get the expected vault address
        (IEVC.BatchItemResult[] memory batchItemsResult,,) = evc.batchSimulation(items);
        address collateral_vault = address(uint160(uint(bytes32(batchItemsResult[0].result))));

        // Initially, the address has no code
        assertEq(collateral_vault.code.length, 0);

        // 2. Execute the batch to deploy the vault
        evc.batch(items);
        vm.stopPrank();

        // 3. Verify deployment and ownership
        assertGt(collateral_vault.code.length, 0, "Vault contract was not deployed");
        assertEq(CollateralVaultBase(collateral_vault).borrower(), alice, "Vault borrower is incorrect");
    }

    // Test the user withdrawing WETH (underlying) from the collateral vault
    function aave_redeemUnderlying(address collateralAssets) public noGasMetering {
        // Setup: Deposit credit LP, create vault, deposit collateral
        aave_collateralDepositWithoutBorrow(collateralAssets, 9100);

        // Confirm redeemUnderlying cannot be called by anyone other than the borrower
        vm.startPrank(bob);

        // Bob cannot call redeemUnderlying with a zero amount
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_aave_vault.redeemUnderlying(0, bob);
        // Bob cannot call redeemUnderlying with a non-zero amount
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_aave_vault.redeemUnderlying(1, bob);
        // Bob cannot call redeemUnderlying even with alice as receiver
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_aave_vault.redeemUnderlying(1, alice);

        vm.stopPrank();

        // alice can use redeemUnderlying though
        vm.startPrank(alice);

        uint256 snapshot = vm.snapshotState();
        uint maxRedeem = IERC20(alice_aave_vault.asset()).balanceOf(address(alice_aave_vault)) - alice_aave_vault.maxRelease();

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.redeemUnderlying, (maxRedeem, alice))
        });

        evc.batch(items);

        assertEq(alice_aave_vault.totalAssetsDepositedOrReserved(), 0);
        assertEq(alice_aave_vault.maxRelease(), 0);

        vm.revertToState(snapshot);

        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.redeemUnderlying, (type(uint).max, alice))
        });

        evc.batch(items);

        assertEq(alice_aave_vault.totalAssetsDepositedOrReserved(), 0);
        assertEq(alice_aave_vault.maxRelease(), 0);
        vm.stopPrank();
    }


    // Collateral vault borrows from Aave directly (no batch)
    function aave_firstBorrowDirect(address collateralAssets) public noGasMetering {
        // Setup: Deposit credit LP, create vault, deposit collateral
        aave_collateralDepositWithoutBorrow(collateralAssets, 9100);

        uint256 aliceBalanceBefore = IERC20(USDC).balanceOf(alice);

        vm.startPrank(alice);

        // Borrow USDC
        alice_aave_vault.borrow(BORROW_USD_AMOUNT, alice);

        // 1. Borrower got target asset
        assertEq(
            IERC20(USDC).balanceOf(alice) - aliceBalanceBefore,
            BORROW_USD_AMOUNT,
            "Borrower not holding correct target assets"
        );

        // 2. alice_aave_vault holds the Aave debt (aDebtUSDC)
        assertApproxEqAbs(
            alice_aave_vault.maxRepay(),
            BORROW_USD_AMOUNT,
            1,
            "collateral vault holding incorrect Aave debt"
        );
        vm.stopPrank();
    }

    // Collateral vault borrows from Aave via an EVC batch
    function aave_firstBorrowViaCollateral(address collateralAssets) public noGasMetering {
        aave_createCollateralVault(collateralAssets, 9100);

        vm.startPrank(alice);
        // Alice approves WETH to the vault for deposit
        IERC20(collateralAssets).approve(address(alice_aave_vault), type(uint256).max);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // 1. Deposit WETH (underlying)
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.deposit, (COLLATERAL_AMOUNT))
        });

        // 2. Borrow target asset (USDC)
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.borrow, (BORROW_USD_AMOUNT, alice))
        });

        evc.batch(items);
        vm.stopPrank();

    }


    // Separate the checks that are run after the borrow operation
    function aave_postBorrowChecks(address collateralAssets) public {
        aave_firstBorrowViaCollateral(collateralAssets);

        // 1. alice_aave_vault has aWETHWrapper collateral (shares held by the vault itself)
        assertEq(alice_aave_vault.balanceOf(address(alice_aave_vault)), COLLATERAL_AMOUNT);

        // 2. Borrower got target asset
        // Note: INITIAL_DEALT_ERC20 (USDC) is the initial mock balance for the user
        assertEq(
            IERC20(USDC).balanceOf(alice) - INITIAL_DEALT_ERC20,
            BORROW_USD_AMOUNT,
            "Borrower not holding correct target assets"
        );

        // alice_aave_vault holds the Aave debt
        assertApproxEqAbs(
            alice_aave_vault.maxRepay(),
            BORROW_USD_AMOUNT,
            1,
            "collateral vault holding incorrect Aave debt"
        );
    }


    // User wishes to close their collateral vault position by repaying all and withdrawing all
    function aave_repayWithdrawAll(address collateralAssets) public noGasMetering {
        aave_firstBorrowDirect(collateralAssets);

        vm.startPrank(alice);

        // Alice approves USDC for repayment
        IERC20(USDC).approve(address(alice_aave_vault), type(uint256).max);

        uint snapshot = vm.snapshot();

        uint debt = alice_aave_vault.maxRepay();

        alice_aave_vault.repay(debt);

        assertEq(alice_aave_vault.maxRepay(), 0, "Max repay doesn't pay full withdraw");

        vm.revertToState(snapshot);

        // The maxRepay amount is no longer tracked by the vault; use type(uint256).max to repay all debt
        uint256 amountToRepay = type(uint256).max;
        uint256 sharesToWithdraw = alice_aave_vault.balanceOf(address(alice_aave_vault));

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // 1. Repay debt to Aave
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.repay, (amountToRepay))
        });

        // 2. Withdraw all collateral
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.withdraw, (sharesToWithdraw, alice))
        });

        evc.batch(items);
        vm.stopPrank();

        // collateral vault has no debt in Euler USDC
        assertEq(alice_aave_vault.maxRepay(), 0, "maxRepay is not zero");
        // collateral vault has no debt from intermediate vault
        assertEq(alice_aave_vault.maxRelease(), 0, "maxRelease is not zero");

        vm.stopPrank();

        assertEq(IERC20(collateralAssets).balanceOf(address(alice_aave_vault)), 0, "Incorrect aWETHWrapper balance remaining in vault");

    }


    function aave_interestAccrualThenRepay(address collateralAssets) public noGasMetering {
        aave_firstBorrowDirect(collateralAssets);

        // Borrow amount before interest
        uint originalMaxRelease = alice_aave_vault.maxRelease();
        assertApproxEqAbs(alice_aave_vault.maxRepay(), BORROW_USD_AMOUNT, 1, "collateral vault holding incorrect Aave debt");

        // Move forward in time to observe increase in debts
        uint256 blockIncrement = 1000;
        vm.roll(block.number + blockIncrement);
        vm.warp(block.timestamp + 12); // Warp 1 year for significant interest

        // borrower has MORE debt in eUSDC
        assertGt(alice_aave_vault.maxRelease(), originalMaxRelease, "borrow should have more debt than before");
        // collateral vault now has MORE debt in eUSDC
        assertGt(alice_aave_vault.maxRepay(), BORROW_USD_AMOUNT, "2");

        // Now repay - first Aave debt, then withdraw all
        vm.startPrank(alice);

        IERC20(USDC).approve(address(alice_aave_vault), type(uint256).max);
        IERC20(collateralAssets).approve(address(alice_aave_vault), type(uint256).max);
        assertEq(IERC20(USDC).allowance(alice, address(alice_aave_vault)), type(uint256).max);


        // repay debt to Euler
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.repay, (type(uint256).max))
        });
        evc.batch(items);

        // withdraw all assets
        IEVC.BatchItem[] memory newItems = new IEVC.BatchItem[](1);
        newItems[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.withdraw, (type(uint).max, alice))
        });

        deal(USDC, address(alice_aave_vault), INITIAL_DEALT_ERC20); // minting USDC to alice to account for interest accrual
        evc.batch(newItems);
        vm.stopPrank();



        vm.stopPrank();

        // collateral vault has no debt in Aave USDC
        assertEq(alice_aave_vault.maxRepay(), 0);
        // borrower alice has no debt from intermediate vault
        assertEq(alice_aave_vault.maxRelease(), 0);
        assertEq(alice_aave_vault.balanceOf(address(alice_aave_vault)), 0);
        assertEq(IERC20(collateralAssets).balanceOf(address(alice_aave_vault)), 0, "Incorrect aWethWrapper balance remaining in vault");
    }

    // Test case: 2nd user borrows from the same intermediate vault
    function aave_secondBorrow(address collateralAssets) public noGasMetering {
        // 1. Alice performs a full borrow
        aave_firstBorrowDirect(collateralAssets);

        // 2. Bob creates vault
        vm.startPrank(bob);
        bob_aave_vault = AaveV3CollateralVault(
            collateralVaultFactory.createCollateralVault({
                _vaultType: VaultType.AAVE_V3,
                _asset: collateralAssets,
                _targetVault: aavePool,
                _liqLTV: twyneLiqLTV,
                _targetAsset: USDC
            })
        );
        uint256 reservedAmount = getReservedAssetsForAave(COLLATERAL_AMOUNT, bob_aave_vault);
        // 3. Bob deposits WETH collateral (underlying)
        IERC20(collateralAssets).approve(address(bob_aave_vault), type(uint256).max);
        bob_aave_vault.deposit(COLLATERAL_AMOUNT);

        // 4. Bob borrows USDC
        bob_aave_vault.borrow(BORROW_USD_AMOUNT, bob);
        vm.stopPrank();

        // 5. Assertions for Bob's vault
        // borrower has debt from intermediate vault
        assertEq(bob_aave_vault.maxRelease(), reservedAmount, "1");
        // collateral vault has debt in euler USDC
        assertApproxEqAbs(bob_aave_vault.maxRepay(), BORROW_USD_AMOUNT, 1, "2");

        // The intermediate vault should still have assets, and both Alice and Bob's positions should be independent.
    }

    // User sets their custom LTV before borrowing
    function aave_setTwyneLiqLTVNoBorrow(address collateralAssets) public noGasMetering {
        aave_createCollateralVault(collateralAssets, 9100);

        vm.startPrank(alice);
        // Toggle LTV before any borrows exist
        uint16 newLTV = twyneVaultManager.maxTwyneLTVs(alice_aave_vault.asset()) - 100;
        alice_aave_vault.setTwyneLiqLTV(newLTV);

        // Assert the change took place
        assertEq(alice_aave_vault.twyneLiqLTV(), newLTV, "Twyne LTV not set correctly");
        vm.stopPrank();
    }

    // User sets their custom LTV after borrowing
    function aave_setTwyneLiqLTVWithBorrow(address collateralAssets) public noGasMetering {
        aave_firstBorrowViaCollateral(collateralAssets);

        // Toggle LTV now that borrows exist
        vm.startPrank(alice);


        // Twyne's liquidation LTV should be in (0, 1) range
        vm.expectRevert(TwyneErrors.ValueOutOfRange.selector);
        alice_aave_vault.setTwyneLiqLTV(0);
        vm.expectRevert(TwyneErrors.ValueOutOfRange.selector);
        alice_aave_vault.setTwyneLiqLTV(1e4);

        uint16 cachedMaxTwyneLTV = twyneVaultManager.maxTwyneLTVs(alice_aave_vault.asset());
        alice_aave_vault.setTwyneLiqLTV(cachedMaxTwyneLTV - 50);
        alice_aave_vault.setTwyneLiqLTV(cachedMaxTwyneLTV - 100);
        alice_aave_vault.setTwyneLiqLTV(cachedMaxTwyneLTV);
        vm.stopPrank();
    }


    // Test the helper function used to get liquidity into the intermediate vault
    function aave_depositUnderlyingToIntermediateVault(address collateralAssets) public {

        vm.assume(isValidCollateralAsset(collateralAssets));

        // Setup: create intermediate vault with deposits (done in setup)
        IEVault intermediateVault = IEVault(twyneVaultManager.getIntermediateVault(collateralAssets));
        address underlyingAsset = IAaveV3ATokenWrapper(collateralAssets).asset(); // WETH

        uint256 depositAmount = 1e18; // 1 WETH

        // Give alice underlying assets (WETH)
        deal(underlyingAsset, alice, depositAmount);

        // Take snapshot before testing
        uint256 snapshot = vm.snapshotState();

        // TEST 1: Direct call with plain approval
        vm.startPrank(alice);

        // Set up plain ERC20 approval for the Aave Wrapper
        IERC20(underlyingAsset).approve(address(aaveWrapper), depositAmount);

        // Record balances before
        uint256 aliceUnderlyingBefore = IERC20(underlyingAsset).balanceOf(alice);
        uint256 aliceIntermediateSharesBefore = intermediateVault.balanceOf(alice);

        // Call the function directly on the Aave Wrapper
        uint256 sharesReceived = aaveWrapper.depositUnderlyingToIntermediateVault(
            intermediateVault,
            depositAmount
        );

        vm.stopPrank();

        // Verify results for direct call
        assertEq(IERC20(underlyingAsset).balanceOf(alice), aliceUnderlyingBefore - depositAmount, "Alice underlying balance incorrect");
        assertApproxEqAbs(intermediateVault.balanceOf(alice), aliceIntermediateSharesBefore + sharesReceived, 1e2, "Alice intermediate shares incorrect");
        assertApproxEqAbs(IERC20(underlyingAsset).balanceOf(address(aWETHWrapper)), 0, 10, "Wrapper should not hold underlying");
        assertApproxEqAbs(IERC20(collateralAssets).balanceOf(address(aWETHWrapper)), 0, 10, "Wrapper should not hold aTokens");
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
            spender: address(aaveWrapper),
            sigDeadline: type(uint256).max
        });

        // Record balances before batch
        uint256 aliceUnderlyingBeforeBatch = IERC20(underlyingAsset).balanceOf(alice);
        uint256 aliceIntermediateSharesBeforeBatch = intermediateVault.balanceOf(alice);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // 1. Permit2 call
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

        // 2. depositUnderlyingToIntermediateVault call
        items[1] = IEVC.BatchItem({
            targetContract: address(aaveWrapper),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(aaveWrapper.depositUnderlyingToIntermediateVault, (intermediateVault, depositAmount))
        });

        // Execute batch
        evc.batch(items);

        // Calculate sharesReceived by checking balance difference
        uint256 aliceIntermediateSharesAfterBatch = intermediateVault.balanceOf(alice);
        uint256 sharesReceivedBatch = aliceIntermediateSharesAfterBatch - aliceIntermediateSharesBeforeBatch;

        vm.stopPrank();

        // Verify results for batch call
        assertEq(IERC20(underlyingAsset).balanceOf(alice), aliceUnderlyingBeforeBatch - depositAmount, "Alice underlying balance incorrect in batch");
        assertEq(intermediateVault.balanceOf(alice), aliceIntermediateSharesBeforeBatch + sharesReceivedBatch, "Alice intermediate shares incorrect in batch");
        assertEq(IERC20(underlyingAsset).balanceOf(address(aaveWrapper)), 0, "Wrapper should not hold underlying in batch");
        assertEq(IEVault(collateralAssets).balanceOf(address(aaveWrapper)), 0, "Wrapper should not hold euler shares in batch");
        assertGt(sharesReceivedBatch, 0, "Should receive some shares in batch");

        // Both tests should yield the same amount of shares
        assertEq(sharesReceived, sharesReceivedBatch, "Direct and batch calls should yield same shares");
    }

    // Test that if time passes, user can withdraw all their share of the collateral
    function aave_withdrawCollateralAfterWarp(address collateralAssets,uint warpBlockAmount) public noGasMetering {
        vm.assume(warpBlockAmount < forkBlockDiff);
        aave_createCollateralVault(collateralAssets, 9100);

        vm.startPrank(alice);

        IERC20(collateralAssets).approve(address(alice_aave_vault), type(uint256).max);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        // reserve assets from intermediate vault
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.deposit, (COLLATERAL_AMOUNT))
        });

        evc.batch(items);

        uint256 reservedAmount = getReservedAssetsForAave(COLLATERAL_AMOUNT, alice_aave_vault);
        // Perform balance checks before warp
        uint256 vaultSharesBeforeWarp = alice_aave_vault.balanceOf(address(alice_aave_vault));
        assertGt(vaultSharesBeforeWarp, 0, "Wrong shares balance before warp");
        assertEq(
            IERC20(collateralAssets).balanceOf(address(alice_aave_vault)) - reservedAmount,
            COLLATERAL_AMOUNT,
            "Wrong collateral balance before warp"
        );

        // warp forward, allows Aave balances to increase
        vm.roll(block.number + warpBlockAmount);
        vm.warp(block.timestamp + 600);
        assertGt(alice_aave_vault.maxRelease(), 0, "Wrong release value after warp");
        assertEq(alice_aave_vault.totalAssetsDepositedOrReserved(), COLLATERAL_AMOUNT + reservedAmount, "Wrong totalAssetsDepositedOrReserved before warp");
        assertEq(
            IERC20(collateralAssets).balanceOf(address(alice_aave_vault)), COLLATERAL_AMOUNT + reservedAmount, "Wrong collateral balance before warp");

        // Ensure no one else can withdraw from alice's collateral vault
        uint collateralVaultBalance = alice_aave_vault.balanceOf(address(alice_aave_vault));
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_aave_vault.withdraw(collateralVaultBalance, alice);
        vm.stopPrank();

        vm.startPrank(alice);

        // Withdraw all available collateral
        alice_aave_vault.withdraw(type(uint256).max, alice);
        vm.stopPrank();

        // Check final vault balances
        assertEq(IERC20(collateralAssets).balanceOf(address(alice_aave_vault)), 0, "Collateral balance not zero after withdraw");
    }


    // Try max borrowing from the external protocol (Aave).
    function aave_maxBorrowDirect(address collateralAssets, uint16 collateralMultiplier) public noGasMetering {
        vm.assume(collateralMultiplier <= MAXFACTOR);
        vm.assume(collateralMultiplier > 0);

        // 1. Setup vault and deposit collateral
        aave_createCollateralVault(collateralAssets, 9100);

        uint usdcPrice = getAavePrice(USDC);

        // Adjust COLLATERAL_AMOUNT
        COLLATERAL_AMOUNT = (COLLATERAL_AMOUNT * collateralMultiplier) / MAXFACTOR;


        vm.startPrank(admin);
        // Set an External Liq Buffer (Twyne's safety margin)
        twyneVaultManager.setExternalLiqBuffer(collateralAssets, 0.95e4); // 96%
        vm.stopPrank();
        uint snapshot = vm.snapshotState();

        vm.startPrank(alice);

        IERC20(collateralAssets).approve(address(alice_aave_vault), type(uint256).max);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        // reserve assets from intermediate vault
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.deposit, COLLATERAL_AMOUNT)
        });
        evc.batch(items);



        // --- MAX BORROW CALCULATION for Twyne's Liq Buffer (first condition) ---

        // Get max borrowable amount based on Aave's Health Factor / Liquidation Threshold
        (uint totalCollateralBase,,uint availableBorrowsBase,,,) = IAaveV3Pool(aavePool).getUserAccountData(address(alice_aave_vault));

        // Note: availableBorrowsBase is in terms of the underlying asset (e.g., USD/ETH).
        // We'll use this for the max borrow logic, as it's the Aave system's limit.
        uint borrowAmountUSDC = ((totalCollateralBase/1e2)*getLiqLTV(collateralAssets)*9500)/MAXFACTOR/MAXFACTOR; // Borrow just under the Aave limit (1e6 is $1 USDC)
        uint borrow2 = ((availableBorrowsBase/1e2) * 9500 / MAXFACTOR)*getLiqLTV(collateralAssets)/getBorrowLTV(collateralAssets);
        borrowAmountUSDC = borrowAmountUSDC < borrow2 ? borrowAmountUSDC : borrow2;
        borrowAmountUSDC = (borrowAmountUSDC * 1e8 / usdcPrice);

        // Borrow up to the calculated max
        alice_aave_vault.borrow(borrowAmountUSDC - 10, alice);
        // uint diff = ((availableBorrowsBase/1e2)*9500*getLiqLTV(collateralAssets)/(getBorrowLTV(collateralAssets)*MAXFACTOR)*1e8/usdcPrice) - borrowAmountUSDC;
        // The next borrow should be limited by the *Twyne* buffer/Health Factor threshold
        vm.expectRevert(TwyneErrors.VaultStatusLiquidatable.selector);
        alice_aave_vault.borrow((((availableBorrowsBase/1e2)*1e8/usdcPrice) - borrowAmountUSDC)/2, alice); // Try to borrow 1 USDC more
        vm.stopPrank();

        // --- MAX BORROW CALCULATION for Aave's Raw Health Factor (second condition) ---
        vm.revertToState(snapshot);

        vm.startPrank(admin);
        // Reset External Liq Buffer (to ensure the *Aave Health Factor* check triggers next)
        twyneVaultManager.setExternalLiqBuffer(collateralAssets, uint16(MAXFACTOR)); // 100% buffer
        vm.stopPrank();

        vm.startPrank(alice);

        IERC20(collateralAssets).approve(address(alice_aave_vault), type(uint256).max);

        items = new IEVC.BatchItem[](1);
        // reserve assets from intermediate vault
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.deposit, COLLATERAL_AMOUNT)
        });
        evc.batch(items);


        // Get max borrowable amount from Aave (will be higher now due to 100% buffer)
        (totalCollateralBase,,availableBorrowsBase,,,) = IAaveV3Pool(aavePool).getUserAccountData(address(alice_aave_vault));
        // divide by 2 as on aave base is 1 usd and 1 usd is represented as 1e8
        borrowAmountUSDC = (totalCollateralBase/1e2) * getBorrowLTV(collateralAssets) / MAXFACTOR; // Borrow just under the Aave limit
        // Borrow up to the calculated max
        borrowAmountUSDC = borrowAmountUSDC * 1e8 / usdcPrice;
        alice_aave_vault.borrow(borrowAmountUSDC - 10, alice);
        (,,availableBorrowsBase,,,) = IAaveV3Pool(aavePool).getUserAccountData(address(alice_aave_vault));
        // The next borrow should hit the raw Aave Health Factor limit
        vm.expectRevert(); // Aave's error for hitting H.F. limit
        alice_aave_vault.borrow(1e6, alice); // Try to borrow 1 USDC more
        vm.stopPrank();
    }


    // User Permit2 to repay all
    function aave_permit2FirstRepay(address collateralAssets) public noGasMetering {
        // Setup: Borrow USDC (creates debt)
        aave_firstBorrowDirect(collateralAssets);

        uint256 debtAmount = IERC20(address(aDebtUSDC)).balanceOf(address(alice_aave_vault));
        uint256 sharesToWithdraw = alice_aave_vault.balanceOf(address(alice_aave_vault));
        deal(USDC, alice, debtAmount);
        vm.startPrank(alice);

        // Alice approves Permit2 to spend her USDC (target asset)
        IERC20(USDC).approve(permit2, type(uint).max);

        // Create PermitSingle for USDC
        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: USDC,
                amount: uint160(debtAmount), // Approve *at least* the debt amount
                expiration: type(uint48).max,
                nonce: 0
            }),
            spender: address(alice_aave_vault),
            sigDeadline: type(uint256).max
        });
        Permit2ECDSASigner permit2Signer = new Permit2ECDSASigner(address(permit2));

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);

        // 1. Permit2 signature (transfer USDC allowance to the vault)
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

        // 2. Repay debt to Aave (will use Permit2 allowance)
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.repay, (alice_aave_vault.maxRepay())) // Repay all
        });

        // 3. Withdraw all collateral
        items[2] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.withdraw, (sharesToWithdraw, alice))
        });

        evc.batch(items);
        vm.stopPrank();


        // collateral vault has no debt in Euler USDC
        assertEq(alice_aave_vault.maxRepay(), 0);
        // collateral vault has no debt from intermediate vault
        assertEq(alice_aave_vault.maxRelease(), 0);


        // 1 wei of value is stuck in collateral vault
        assertEq(alice_aave_vault.balanceOf(address(alice_aave_vault)), 0, "incorrect alice balance");
        assertEq(IERC20(collateralAssets).balanceOf(address(alice_aave_vault)), 0, "Incorrect aWethWrapper balance remaining in vault");
        // alice WSTETH balance is restored to the dealt amount
        assertApproxEqRel(IERC20(collateralAssets).balanceOf(alice), IEVault(collateralAssets).convertToShares(INITIAL_DEALT_ETOKEN), 1, "wstETH balance is not the original amount");
    }


    function aave_depositETHToIntermediateVault(address collateralAssets) public {
        vm.assume(isValidCollateralAsset(collateralAssets));
        // Only test with WETH-based assets since ETH deposits only work with WETH
        address underlyingAsset = IEVault(collateralAssets).asset();

        uint256 ethDepositAmount = 1 ether;
        vm.deal(alice, ethDepositAmount);

        IEVault intermediateVault = IEVault(twyneVaultManager.getIntermediateVault(collateralAssets));


        if (underlyingAsset != WETH) {
            // Test that depositETHToIntermediateVault reverts when used with non-WETH underlying
            vm.expectRevert(TwyneErrors.OnlyWETH.selector);
            aaveWrapper.depositETHToIntermediateVault{value: 1e18}(intermediateVault);
            vm.stopPrank();
            return;
        }


        uint256 snapshot = vm.snapshotState();

        // TEST 1: Direct call
        vm.startPrank(alice);

        uint256 aliceETHBefore = alice.balance;
        uint256 aliceIntermediateSharesBefore = intermediateVault.balanceOf(alice);

        // Call the function on the Aave Wrapper, sending ETH
        uint256 sharesReceived = aaveWrapper.depositETHToIntermediateVault{value: ethDepositAmount}(
            intermediateVault
        );

        vm.stopPrank();

        // Verification
        assertEq(alice.balance, aliceETHBefore - ethDepositAmount, "Alice ETH balance incorrect");
        assertEq(intermediateVault.balanceOf(alice), aliceIntermediateSharesBefore + sharesReceived, "Alice intermediate shares incorrect");
        assertEq(IERC20(WETH).balanceOf(address(aaveWrapper)), 0, "Wrapper should not hold WETH");
        assertEq(address(aaveWrapper).balance, 0, "Wrapper should not hold ETH");
        assertEq(IEVault(collateralAssets).balanceOf(address(aaveWrapper)), 0, "Wrapper should not hold wrapper shares");
        assertGt(sharesReceived, 0, "Should receive some shares");

        vm.revertToState(snapshot);

        // TEST 2: Batch call through EVC
        vm.startPrank(alice);

        uint256 aliceETHBeforeBatch = alice.balance;
        uint256 aliceIntermediateSharesBeforeBatch = intermediateVault.balanceOf(alice);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);

        // ETH deposit function on AaveWrapper
        items[0] = IEVC.BatchItem({
            targetContract: address(aaveWrapper),
            onBehalfOfAccount: alice,
            value: ethDepositAmount,
            data: abi.encodeCall(aaveWrapper.depositETHToIntermediateVault, (intermediateVault))
        });

        // The ETH value must be sent with the EVC batch call
        evc.batch{value: ethDepositAmount}(items);

        uint256 aliceIntermediateSharesAfterBatch = intermediateVault.balanceOf(alice);
        uint256 sharesReceivedBatch = aliceIntermediateSharesAfterBatch - aliceIntermediateSharesBeforeBatch;

        vm.stopPrank();

        // Verification for batch call
        assertEq(alice.balance, aliceETHBeforeBatch - ethDepositAmount, "Alice ETH balance incorrect in batch");
        assertEq(intermediateVault.balanceOf(alice), aliceIntermediateSharesBeforeBatch + sharesReceivedBatch, "Alice intermediate shares incorrect in batch");
        assertEq(address(aaveWrapper).balance, 0, "Wrapper should not hold ETH in batch");
        assertGt(sharesReceivedBatch, 0, "Should receive some shares in batch");

        // Both tests should yield approximately the same amount of shares
        assertEq(sharesReceived, sharesReceivedBatch, "Direct and batch calls should yield approximately same shares");
    }


    // TODO Test the scenario where one user is a credit LP and a borrower at the same time

    // TODO Test the scenario where a fake intermediate vault is created
    // and the borrow from it causes near-instant liquidation for the user


    function aave_skim(address collateralAssets) public noGasMetering {
        // Setup: Alice creates a collateral vault and deposits
        aave_collateralDepositWithBorrow(collateralAssets);

        vm.startPrank(alice);

        // Initial state
        uint256 initialTotalAssets = alice_aave_vault.totalAssetsDepositedOrReserved();
        uint256 initialVaultBalance = IERC20(collateralAssets).balanceOf(address(alice_aave_vault));
        uint initialBorrow = alice_aave_vault.maxRepay();
        uint256 aliceBalanceBefore = initialTotalAssets - alice_aave_vault.maxRelease();


        // skim with no excess should be a noop
        assertEq(initialTotalAssets, initialVaultBalance, "Should start with shares matching deposit amount (approx)");

        // Calling skim when there's no excess should not change anything
        alice_aave_vault.skim();
        assertEq(alice_aave_vault.totalAssetsDepositedOrReserved(), initialTotalAssets, "Skim with no excess should not change Alice's shares");
        vm.stopPrank();

        // --- Simulate accidental transfer (airdrop) ---
        address airdropper = makeAddr("airdropper");
        uint256 airdropAmount = 2 ether;
        vm.startPrank(airdropper);
        address underlying = IAaveV3ATokenWrapper(collateralAssets).asset();
        // Mint aWETHWrapper tokens to airdropper
        deal(underlying, airdropper, airdropAmount + 1);
        // + 1 is to ensure we get same collateral assets
        IERC20(underlying).approve(collateralAssets, airdropAmount);
        uint shares = IAaveV3ATokenWrapper(collateralAssets).deposit(airdropAmount, airdropper);

        // Airdropper transfers aWETHWrapper tokens directly to the vault (simulating accidental transfer)
        vm.startPrank(airdropper);
        IERC20(collateralAssets).transfer(address(alice_aave_vault), shares);
        vm.stopPrank();

        // Verify the vault now has extra tokens
        uint256 vaultBalanceAfterTransfer = IERC20(collateralAssets).balanceOf(address(alice_aave_vault));
        assertEq(vaultBalanceAfterTransfer, initialVaultBalance + shares, "Vault should have extra tokens");
        assertEq(alice_aave_vault.totalAssetsDepositedOrReserved(), initialTotalAssets, "totalAssets should not change yet");

        // Test: Only borrower can call skim
        vm.startPrank(airdropper);
        vm.expectRevert(TwyneErrors.ReceiverNotBorrower.selector);
        alice_aave_vault.skim();
        vm.stopPrank();

        // Test: Borrower calls skim
        vm.startPrank(alice);

        // Skim transfers the excess collateral from the vault's balance to the borrower's share balance
        alice_aave_vault.skim();

        uint256 finalTotalAssets = alice_aave_vault.totalAssetsDepositedOrReserved();
        uint256 finalVaultBalance = IERC20(collateralAssets).balanceOf(address(alice_aave_vault));
        uint256 aliceBalanceAfter = finalTotalAssets - alice_aave_vault.maxRelease();

        assertEq(finalTotalAssets, finalVaultBalance, "After skim: totalAssets should match vault balance");
        assertEq(alice_aave_vault.maxRepay(), initialBorrow, "After skim: borrow amount shouldn't change");
        assertEq(aliceBalanceAfter - aliceBalanceBefore, shares, "After skim: borrower's collateral should increase by airdrop amout");

        vm.stopPrank();
    }


    // test wsteth and weth borrow to check emode

    function aave_borrowEmode() public {
        uint16 liqLTV = 9800;
        address collateralAssets = address(aWSTETHWrapper);
        aave_createCollateralVault(collateralAssets, liqLTV, WETH);
        uint wethBalanceBefore = IERC20(WETH).balanceOf(alice);
        uint256 reservedAmount = getReservedAssetsForAave(COLLATERAL_AMOUNT, alice_aave_vault);
        uint borrowAmount = (COLLATERAL_AMOUNT + reservedAmount)*9/10;
        vm.startPrank(alice);
        // Alice approves WETH to the vault for deposit
        IERC20(collateralAssets).approve(address(alice_aave_vault), type(uint256).max);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

        // 1. Deposit WSTETH (underlying)
        items[0] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.deposit, (COLLATERAL_AMOUNT))
        });

        // 2. Borrow target asset (WETH)
        items[1] = IEVC.BatchItem({
            targetContract: address(alice_aave_vault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(alice_aave_vault.borrow, (borrowAmount, alice))
        });

        evc.batch(items);
        vm.stopPrank();

        assertEq(IERC20(WETH).balanceOf(alice), wethBalanceBefore + borrowAmount);
        assertApproxEqAbs(alice_aave_vault.maxRepay(), borrowAmount, 1);
    }



    function getLiqLTV(address collateralAsset, address debtAsset) internal view returns(uint256) {
        uint8 categoryId = collateralVaultFactory.categoryId(aavePool, collateralAsset, debtAsset);
        if (categoryId == 0){
            address underlyingAsset = IAaveV3ATokenWrapper(collateralAsset).asset();

            (,,uint liqLTV, ,,,,,,) = aaveDataProvider.getReserveConfigurationData(
                underlyingAsset
            );
            return liqLTV;
        }else{
            return IAaveV3Pool(aavePool).getEModeCategoryCollateralConfig(categoryId).liquidationThreshold;
        }
    }

    function getLiqLTV(address collateralAsset) internal view returns (uint256) {
        return getLiqLTV(collateralAsset, USDC);
    }

    function getBorrowLTV(address collateralAsset) internal view returns (uint) {

        address underlyingAsset = IAaveV3ATokenWrapper(collateralAsset).asset();

        (,uint borrowLTV,, ,,,,,,) = aaveDataProvider.getReserveConfigurationData(
            underlyingAsset
        );
        return borrowLTV;


    }

    function getAaveOracleFeed(address collateralAsset) internal view returns (address) {
        IAaveV3AddressProvider addressProvider = IAaveV3Pool(aavePool).ADDRESSES_PROVIDER();
        address oracle = addressProvider.getPriceOracle();

        address feed = IAaveOracle(oracle).getSourceOfAsset(collateralAsset);

        return feed;
    }

    function getAavePrice(address collateralAsset) internal view returns (uint) {
        IAaveV3AddressProvider addressProvider = IAaveV3Pool(aavePool).ADDRESSES_PROVIDER();
        address oracle = addressProvider.getPriceOracle();

        return IAaveOracle(oracle).getAssetPrice(collateralAsset);
    }

    function getAaveOracle() internal view returns (address) {
        IAaveV3AddressProvider addressProvider = IAaveV3Pool(aavePool).ADDRESSES_PROVIDER();
        return addressProvider.getPriceOracle();
    }

    function setAaveLTV(address collateralAsset, uint16 newLTV) internal {
        address underlyingAsset = IAaveV3ATokenWrapper(collateralAsset).asset();

        (
            ,
            uint256 currentLtv,
            ,
            uint256 currentLiquidationBonus,
            ,
            ,
            ,
            ,
            ,
        ) = aaveDataProvider.getReserveConfigurationData(underlyingAsset);

        IAaveV3AddressProvider addressProvider = IAaveV3AddressProvider(IAaveV3Pool(aavePool).ADDRESSES_PROVIDER());
        address configurator = addressProvider.getPoolConfigurator();

        address aclAdmin = addressProvider.getACLAdmin();

        vm.startPrank(aclAdmin);
        currentLtv = uint(newLTV - 250);


        IPoolConfigurator(configurator).configureReserveAsCollateral(
            underlyingAsset,
            currentLtv,
            uint(newLTV),
            currentLiquidationBonus
        );
        vm.stopPrank();
    }

}