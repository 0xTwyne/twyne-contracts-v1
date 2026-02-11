// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Vm.sol";
import {BatchScript, console2} from "forge-safe/src/BatchScript.sol";

import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {MockBalanceTracker} from "euler-vault-kit/../test/mocks/MockBalanceTracker.sol";
import {IRMTwyneCurveGamma32} from "src/twyne/IRMTwyneCurveGamma32.sol";
import {EVault} from "euler-vault-kit/EVault/EVault.sol";
import {CollateralVaultFactory, VaultType} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {USD} from "euler-price-oracle/test/utils/EthereumAddresses.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {IEVault, IGovernance} from "euler-vault-kit/EVault/IEVault.sol";
import {BridgeHookTarget} from "src/TwyneFactory/BridgeHookTarget.sol";
import {OP_BORROW, OP_LIQUIDATE, OP_FLASHLOAN, OP_PULL_DEBT, CFG_DONT_SOCIALIZE_DEBT} from "euler-vault-kit/EVault/shared/Constants.sol";
import {EulerCollateralVault} from "src/twyne/EulerCollateralVault.sol";
import {AaveV3CollateralVault} from "src/twyne/AaveV3CollateralVault.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {HealthStatViewer} from "src/twyne/HealthStatViewer.sol";
import {AaveV3LeverageOperator} from "src/operators/AaveV3LeverageOperator.sol";
import {AaveV3Wrapper} from "src/Periphery/AaveV3Wrapper.sol";
import {AaveV3TeleportOperator} from "src/operators/AaveV3TeleportOperator.sol";
import {AaveV3DeleverageOperator} from "src/operators/AaveV3DeleverageOperator.sol";
import {IAaveV3ATokenWrapper} from "src/interfaces/IAaveV3ATokenWrapper.sol";
import {IPool as IAaveV3Pool} from "aave-v3/interfaces/IPool.sol";
import {IAaveOracle} from "aave-v3/interfaces/IAaveOracle.sol";
import {IPoolAddressesProvider as IAaveV3AddressProvider} from "aave-v3/interfaces/IPoolAddressesProvider.sol";
import {AaveV3ATokenWrapperOracle} from "src/twyne/AaveV3ATokenWrapperOracle.sol";
import {GenericFactory} from "euler-vault-kit/GenericFactory/GenericFactory.sol";
import {AggregatorV3Interface} from "euler-price-oracle/src/adapter/chainlink/AggregatorV3Interface.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";
import {AToken} from "aave-v3/protocol/tokenization/AToken.sol";

// set addresses for aave pool and assets to be set
// deploy new collateral vault factory impl
// deploy aave v3 a token wrapper impl and proxy
// upgrade collateral vault factory
// deploy new euler collateral vault and upgrade its impl
// deploy new vault manager and upgrade its impl
// deploy aave collateral vault impl and beacon proxy
// Call setBeacon on collateral vault factory for atoken wrapper and aave collateral vault beacon
// Call setMaxLiquidationLTV for aWrapper
// deploy new wsteth intermediate vault
// Call setExternalLiqBuffer for aWrapper
// Call setAllowedTarget for aWrapper

contract TwyneDeployAaveV3Integration is BatchScript {
    // set asset addresses

    uint PHASE = 10;

    address deployer;
    address SAFE;

    address eulerUSDC;
    address WETH;
    address WSTETH;
    address permit2;
    address eulerSwapper;
    address eulerSwapVerifier;
    address morpho;

    address upgradeableBeacon;

    address aavePool;
    address aTokenWrapperImpl;
    IAaveV3ATokenWrapper aWSTETHWrapper;
    address aaveCollateralVaultImpl;
    address evc;
    address rewardController;

    address eulerCollateralVaultImpl;

    CollateralVaultFactory collateralVaultFactory;
    VaultManager vaultManager;
    EulerRouter oracleRouter;
    EulerRouter aaveOracleRouter;
    GenericFactory factory;
    IEVault eaWSTETH_intermediate_vault;
    AaveV3CollateralVault deployer_collateral_vault;
    HealthStatViewer healthViewer;

    AaveV3ATokenWrapperOracle aTokenWrapperOracle;

    address bridgeHook;

    address feeReceiver;

    uint constant twyneLiqLTV = 0.96e4;
    uint8 categoryId;

    error UnknownProfile();
    error InvalidCollateral();

    function run() public {
        if (block.chainid == 1) {
            // Morpho addresses are documented at: https://docs.morpho.org/get-started/resources/addresses#morpho-contracts
            morpho = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
            permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
            // Euler addresses are documented at: https://docs.euler.finance/developers/contract-addresses
            eulerSwapper = 0x2Bba09866b6F1025258542478C39720A09B728bF;

            WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
            WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
            aavePool = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
            categoryId = 1;
        } else if (block.chainid == 8453) {
            morpho = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
            permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
            // Euler addresses are documented at: https://docs.euler.finance/developers/contract-addresses
            eulerSwapper = 0x0D3d0F97eD816Ca3350D627AD8e57B6AD41774df;

            WETH = 0x4200000000000000000000000000000000000006;
            WSTETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
            aavePool = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
            categoryId = 1;
        } else {
            revert UnknownProfile();
        }


        IAaveV3Pool aavePoolContract = IAaveV3Pool(aavePool);
        address wstethAToken = aavePoolContract.getReserveData(WSTETH).aTokenAddress;

        // Validate that the aToken has the correct underlying asset
        require(IAToken(wstethAToken).UNDERLYING_ASSET_ADDRESS() == WSTETH, "underlying asset not correct");

        rewardController = address(AToken(wstethAToken).REWARDS_CONTROLLER());
        loadTwyneAddresses();
        deployer = vm.envAddress("DEPLOYER_ADDRESS"); // set deployer EOA address
        SAFE = vaultManager.owner();
        feeReceiver = SAFE;

        if (PHASE == 0) {
            phase0();
        } else if (PHASE == 1) {
            phase1();
        } else {
            revert("PHASE not set correctly");
        }
    }

    function loadTwyneAddresses() internal {
        string memory twyneAddressesJson = vm.readFile("./TwyneAddresses_output.json");
        collateralVaultFactory = CollateralVaultFactory(vm.parseJsonAddress(twyneAddressesJson, ".collateralVaultFactory"));
        evc = payable(collateralVaultFactory.EVC());
        vaultManager = VaultManager(payable(vm.parseJsonAddress(twyneAddressesJson, ".vaultManager")));
        oracleRouter = EulerRouter(vm.parseJsonAddress(twyneAddressesJson, ".oracleRouter"));
        factory = GenericFactory(vm.parseJsonAddress(twyneAddressesJson, ".GenericFactory"));
        IEVault intermediateVault = IEVault(vm.parseJsonAddress(twyneAddressesJson, ".intermediateVault"));
        (bridgeHook,) = intermediateVault.hookConfig();
        string memory wrapperAddressesJson = vm.readFile("./aTokenWrappers.json");
        aWSTETHWrapper = IAaveV3ATokenWrapper(vm.parseJsonAddress(wrapperAddressesJson, ".awstETH_wrapper"));
    }

    function phase0() internal {
        // Deploy wrapper token impl - atoken wrapper repo
        // create proxy for wsteth - atoken wrapper repo
        // set wrapper token impl for proxy
        // transferOwnership to SAFE

        // Accumulate JSON of findings and deployments
        string memory deploymentJson = "deployment";
        string memory finalJson;

        vm.startBroadcast(deployer);

        aaveOracleRouter = new EulerRouter(evc, address(vaultManager));
        vm.label(address(aaveOracleRouter), "Aave oracle router");
        finalJson = vm.serializeAddress(
            deploymentJson,
            "aaveOracleRouter",
            address(aaveOracleRouter)
        );
        log("Aave oracle router", address(aaveOracleRouter));

        aTokenWrapperOracle = new AaveV3ATokenWrapperOracle(8, aavePool);
        vm.label(address(aTokenWrapperOracle), "wrapped a token oracle");

        finalJson = vm.serializeAddress(
            deploymentJson,
            "aTokenWrapperOracle",
            address(aTokenWrapperOracle)
        );
        log("Wrapper a token oracle", address(aTokenWrapperOracle));

        address aWETHWrapperCollateralVaultImpl = address(new AaveV3CollateralVault(evc, aavePool, rewardController));
        upgradeableBeacon = address(new UpgradeableBeacon(aWETHWrapperCollateralVaultImpl, SAFE));

        require(UpgradeableBeacon(upgradeableBeacon).owner() == SAFE, "Owner not set");

        finalJson = vm.serializeAddress(
            deploymentJson,
            "upgrBeacon",
            upgradeableBeacon
        );
        log("Upgradeable beacon", upgradeableBeacon);

        // First: deploy intermediate vault, then users can deploy corresponding collateral vaults
        eaWSTETH_intermediate_vault = newIntermediateVault(address(aWSTETHWrapper), address(aaveOracleRouter), USD);

        require(eaWSTETH_intermediate_vault.governorAdmin() == address(vaultManager), "intermediate vault not transferred to safe");

        finalJson = vm.serializeAddress(
            deploymentJson,
            "intermediateVault",
            address(eaWSTETH_intermediate_vault)
        );

        // Deploy AaveV3Wrapper for depositing underlying tokens to intermediate vault
        AaveV3Wrapper aaveV3Wrapper = new AaveV3Wrapper(evc, WETH);
        vm.label(address(aaveV3Wrapper), "AaveV3Wrapper");
        finalJson = vm.serializeAddress(
            deploymentJson,
            "aaveV3Wrapper",
            address(aaveV3Wrapper)
        );
        log("AaveV3Wrapper", address(aaveV3Wrapper));

        // Deploy AaveV3 Operators
        AaveV3LeverageOperator aaveV3LeverageOperator = new AaveV3LeverageOperator(
            evc,
            eulerSwapper,
            morpho,
            address(collateralVaultFactory),
            permit2,
            aavePool
        );
        vm.label(address(aaveV3LeverageOperator), "AaveV3LeverageOperator");
        finalJson = vm.serializeAddress(
            deploymentJson,
            "aaveV3LeverageOperator",
            address(aaveV3LeverageOperator)
        );
        log("AaveV3LeverageOperator", address(aaveV3LeverageOperator));

        AaveV3DeleverageOperator aaveV3DeleverageOperator = new AaveV3DeleverageOperator(
            evc,
            eulerSwapper,
            morpho,
            address(collateralVaultFactory),
            permit2,
            aavePool
        );
        vm.label(address(aaveV3DeleverageOperator), "AaveV3DeleverageOperator");
        finalJson = vm.serializeAddress(
            deploymentJson,
            "aaveV3DeleverageOperator",
            address(aaveV3DeleverageOperator)
        );
        log("AaveV3DeleverageOperator", address(aaveV3DeleverageOperator));

        AaveV3TeleportOperator aaveV3TeleportOperator = new AaveV3TeleportOperator(
            evc,
            morpho,
            address(collateralVaultFactory),
            permit2,
            aavePool
        );
        vm.label(address(aaveV3TeleportOperator), "AaveV3TeleportOperator");
        finalJson = vm.serializeAddress(
            deploymentJson,
            "aaveV3TeleportOperator",
            address(aaveV3TeleportOperator)
        );
        log("AaveV3TeleportOperator", address(aaveV3TeleportOperator));

        // Deploy HealthStatViewer
        healthViewer = new HealthStatViewer(aavePool);
        vm.label(address(healthViewer), "HealthStatViewer");
        finalJson = vm.serializeAddress(
            deploymentJson,
            "healthStatViewer",
            address(healthViewer)
        );
        log("HealthStatViewer", address(healthViewer));

        // deploy aave oracle router :check
        // Deploy aave wrapper oracle :check
        // Deploy aave collateral vault impl :check
        // Deploy aave collateral vault beacon :check
        // transferOwnership to SAFE :check
        // deploy intermediate vault :check
        // set governor as vault manager :check
        // deploy AaveV3Wrapper :check
        // deploy AaveV3 operators :check
        vm.stopBroadcast();

        string memory fileName = string.concat("DeployAaveV3IntegrationPhase0_", vm.toString(block.chainid), ".json");
        vm.writeJson(finalJson, fileName);
        console2.log("Deployment data serialized to:", fileName);
    }


    function phase1() internal isBatch(SAFE) {

        string memory fileName = string.concat("DeployAaveV3IntegrationPhase0_", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(fileName);
        address aaveOracleRouterAddress = vm.parseJsonAddress(json, ".aaveOracleRouter");
        require(aaveOracleRouterAddress != address(0), "Missing aaveOracleAddress in phase0 json");
        aaveOracleRouter = EulerRouter(aaveOracleRouterAddress);

        address aTokenWrapperOracleAddress = vm.parseJsonAddress(json, ".aTokenWrapperOracle");
        require(aTokenWrapperOracleAddress != address(0), "Missing aTokenWrapperOracle in phase0 json");
        aTokenWrapperOracle = AaveV3ATokenWrapperOracle(aTokenWrapperOracleAddress);

        upgradeableBeacon = vm.parseJsonAddress(json, ".upgrBeacon");
        require(upgradeableBeacon != address(0), "Missing upgradeableBeacon in phase0 json");

        address new_vaultAddress = vm.parseJsonAddress(json, ".intermediateVault");
        require(new_vaultAddress != address(0), "Missing intermediateVault in phase0 json");
        eaWSTETH_intermediate_vault = IEVault(new_vaultAddress);

        // setBeacon on collateral factory
        bytes memory collateralFactoryCall = abi.encodeCall(collateralVaultFactory.setBeacon, (aavePool, upgradeableBeacon));
        addToBatch(address(collateralVaultFactory), collateralFactoryCall);


        // Set aave wrapper token oracle as fallback oracle on oracle router
        bytes memory oracleSetData = abi.encodeCall(EulerRouter.govSetFallbackOracle, (address(aTokenWrapperOracle)));
        bytes memory vaultManagerCall = abi.encodeCall(vaultManager.doCall, (address(aaveOracleRouter), 0, oracleSetData));
        addToBatch(address(vaultManager), vaultManagerCall);

        // Set aave wrapper token oracle as oracle for asset
        vaultManagerCall = abi.encodeCall(vaultManager.doCall, (address(aaveOracleRouter), 0, abi.encodeCall(EulerRouter.govSetConfig, (address(aWSTETHWrapper), USD, address(aTokenWrapperOracle)))));
        addToBatch(address(vaultManager), vaultManagerCall);

        // Set intermediate vault the new intermediate vault deployed
        vaultManagerCall = abi.encodeCall(vaultManager.setIntermediateVault, (eaWSTETH_intermediate_vault));
        addToBatch(address(vaultManager), vaultManagerCall);

        // Set oracle resolved true for new vault
        vaultManagerCall = abi.encodeCall(vaultManager.setOracleResolvedVaultForOracleRouter, (address(aaveOracleRouter), address(eaWSTETH_intermediate_vault), true));
        addToBatch(address(vaultManager), vaultManagerCall);

        // Set external liq buffer
        vaultManagerCall = abi.encodeCall(vaultManager.setExternalLiqBuffer, (address(aWSTETHWrapper), 1e4));
        addToBatch(address(vaultManager), vaultManagerCall);

        // Set max liq ltv
        vaultManagerCall = abi.encodeCall(vaultManager.setMaxLiquidationLTV, (address(aWSTETHWrapper), 0.98e4));
        addToBatch(address(vaultManager), vaultManagerCall);

        // Check decimals for target and collateral asset
        getAaveOracleFeed(WETH);
        getAaveOracleFeed(WSTETH);
        // Set allowed target
        vaultManagerCall = abi.encodeCall(vaultManager.setAllowedTargetAsset, (address(eaWSTETH_intermediate_vault), aavePool, WETH));
        addToBatch(address(vaultManager), vaultManagerCall);

        // set category Id (Aave emode)
        if (categoryId != 0) {
            collateralFactoryCall = abi.encodeCall(collateralVaultFactory.setCategoryId, (aavePool, address(aWSTETHWrapper), WETH, categoryId));
            addToBatch(address(collateralVaultFactory), collateralFactoryCall);
        }

        executeBatch(true);
    }

    function toAsciiString(address x) internal pure returns (string memory) {
        bytes memory s = new bytes(40);
        for (uint256 i = 0; i < 20; i++) {
            bytes1 b = bytes1(uint8(uint256(uint160(x)) / (2 ** (8 * (19 - i)))));
            bytes1 hi = bytes1(uint8(b) / 16);
            bytes1 lo = bytes1(uint8(b) - 16 * uint8(hi));
            s[2 * i] = char(hi);
            s[2 * i + 1] = char(lo);
        }
        return string(s);
    }

    function char(bytes1 b) internal pure returns (bytes1 c) {
        if (uint8(b) < 10) return bytes1(uint8(b) + 0x30);
        else return bytes1(uint8(b) + 0x57);
    }

    function log(string memory label, address addr) internal {
        console2.log(string.concat("export const ", label, ": string = '0x", toAsciiString(addr), "'"));
        vm.label(addr, label);
    }


    function newIntermediateVault(address _asset, address _oracle, address _unitOfAccount) internal returns (IEVault) {
        IEVault new_vault = IEVault(factory.createProxy(address(0), true, abi.encodePacked(_asset, _oracle, _unitOfAccount)));

        log("New intermediate vault", address(new_vault));
        // set test values, these are placeholders for testing
        // set hook so all borrows and flashloans to use the bridge
        new_vault.setHookConfig(bridgeHook, OP_BORROW | OP_LIQUIDATE | OP_FLASHLOAN | OP_PULL_DEBT);
        // Base=0.00% APY,  Kink(900.00% utilization)=0.50% APY  Max=2.00% APY
        new_vault.setInterestRateModel(address(new IRMTwyneCurveGamma32({
            idealKinkInterestRate_: 5e1, // 0.5%
            linearKinkUtilizationRate_: 9e3, //900%
            maxInterestRate_: 2e2, // 2%
            nonlinearPoint_: 5e17 // 50%
        })));
        new_vault.setMaxLiquidationDiscount(0.2e4);
        new_vault.setLiquidationCoolOffTime(1);
        new_vault.setFeeReceiver(feeReceiver);
        new_vault.setInterestFee(0); // set zero governance fee
        new_vault.setCaps(6420, 6420); // 1000 WstETH supply and borrow cap


        address underlyingCollateralAsset = IAaveV3ATokenWrapper(_asset).asset();

        address aaveExternalOracle = getAaveOracleFeed(underlyingCollateralAsset);
        require(aaveExternalOracle != address(0), "aave doesn't support this asset oracle");

        new_vault.setGovernorAdmin(address(vaultManager));

        require(new_vault.configFlags() & CFG_DONT_SOCIALIZE_DEBT == 0, "debt will not be socialized");
        return new_vault;
    }

    function getAaveOracleFeed(address collateralAsset) internal view returns (address) {
        IAaveV3AddressProvider addressProvider = IAaveV3Pool(aavePool).ADDRESSES_PROVIDER();
        address oracle = addressProvider.getPriceOracle();

        address feed = IAaveOracle(oracle).getSourceOfAsset(collateralAsset);
        require(AggregatorV3Interface(feed).decimals() == 8, "Invalid decimals");

        return feed;
    }

}