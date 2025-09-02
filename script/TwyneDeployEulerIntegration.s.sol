// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "forge-std/Vm.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {MockBalanceTracker} from "euler-vault-kit/../test/mocks/MockBalanceTracker.sol";
import {IRMTwyneCurve} from "src/twyne/IRMTwyneCurve.sol";
import {EVault} from "euler-vault-kit/EVault/EVault.sol";
import {SequenceRegistry} from "euler-vault-kit/SequenceRegistry/SequenceRegistry.sol";
import {GenericFactory} from "euler-vault-kit/GenericFactory/GenericFactory.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initialize} from "euler-vault-kit/EVault/modules/Initialize.sol";
import {Token} from "euler-vault-kit/EVault/modules/Token.sol";
import {Vault} from "euler-vault-kit/EVault/modules/Vault.sol";
import {Borrowing} from "euler-vault-kit/EVault/modules/Borrowing.sol";
import {Liquidation} from "euler-vault-kit/EVault/modules/Liquidation.sol";
import {BalanceForwarder} from "euler-vault-kit/EVault/modules/BalanceForwarder.sol";
import {Governance} from "euler-vault-kit/EVault/modules/Governance.sol";
import {RiskManager} from "euler-vault-kit/EVault/modules/RiskManager.sol";
import {Dispatch} from "euler-vault-kit/EVault/Dispatch.sol";
import {Base} from "euler-vault-kit/EVault/shared/Base.sol";
import {ProtocolConfig} from "euler-vault-kit/ProtocolConfig/ProtocolConfig.sol";
import {USD} from "euler-price-oracle/test/utils/EthereumAddresses.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {CrossAdapter} from "euler-price-oracle/src/adapter/CrossAdapter.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {BridgeHookTarget} from "src/TwyneFactory/BridgeHookTarget.sol";
import {OP_BORROW, OP_LIQUIDATE, OP_FLASHLOAN, CFG_DONT_SOCIALIZE_DEBT} from "euler-vault-kit/EVault/shared/Constants.sol";
import {EulerCollateralVault} from "src/twyne/EulerCollateralVault.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {HealthStatViewer} from "src/twyne/HealthStatViewer.sol";
import {LeverageOperator} from "src/operators/LeverageOperator.sol";

interface EulerRouterFactory {
    function deploy(address) external returns (address);
}

/// @title TwyneDeployEulerIntegration
/// @notice To contact the team regarding security matters, visit https://twyne.xyz/security
contract TwyneDeployEulerIntegration is Script {
    // set asset addresses

    address eulerOnchainRouter;
    address eulerUSDC;
    address eulerWETH;
    address eulerWSTETH;
    address USDC;
    address WETH;
    address WSTETH;
    address permit2;
    address eulerSwapper;
    address eulerSwapVerifier;
    address morpho;

    address eulerCollateralVaultImpl;
    EthereumVaultConnector evc;
    ProtocolConfig protocolConfig;
    address balanceTracker;
    address sequenceRegistry;
    Base.Integrations integrations;
    address initializeModule;
    address tokenModule;
    address vaultModule;
    address borrowingModule;
    address liquidationModule;
    address riskManagerModule;
    address balanceForwarderModule;
    address governanceModule;
    Dispatch.DeployedModules modules;
    address evaultImpl;

    CollateralVaultFactory collateralVaultFactory;
    VaultManager vaultManager;
    EulerRouter oracleRouter;
    GenericFactory factory;
    IEVault eeWETH_intermediate_vault;
    EulerCollateralVault deployer_collateral_vault;
    HealthStatViewer healthViewer;
    LeverageOperator leverageOperator;

    address deployer;
    address admin;
    address feeReceiver;
    uint256 deployerKey;


    uint constant twyneLiqLTV = 0.90e4;

    error UnknownProfile();
    error InvalidCollateral();

    struct TwyneAddresses {
        address collateralVaultFactory;
        address vaultManager;
        address oracleRouter;
        address genericFactory;
        address intermediateVault;
        address deployerExampleCollateralVault;
        address healthStatViewer;
        address leverageOperator;
    }

    function run() public {
        if (block.chainid == 1) { // mainnet
            eulerOnchainRouter = 0x83B3b76873D36A28440cF53371dF404c42497136;
            eulerUSDC = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
            eulerWETH = 0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2;
            eulerWSTETH = 0xbC4B4AC47582c3E38Ce5940B80Da65401F4628f1;
            eulerSwapVerifier = 0xae26485ACDDeFd486Fe9ad7C2b34169d360737c7;
            eulerSwapper = 0x2Bba09866b6F1025258542478C39720A09B728bF;
            morpho = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
        } else if (block.chainid == 8453) { // base
            eulerOnchainRouter = 0x6E183458600e66047A0f4D356d9DAa480DA1CA59;
            eulerUSDC = 0x0A1a3b5f2041F33522C4efc754a7D096f880eE16;
            eulerWETH = 0x859160DB5841E5cfB8D3f144C6b3381A85A4b410;
            eulerWSTETH = 0x7b181d6509DEabfbd1A23aF1E65fD46E89572609;
            eulerSwapVerifier = 0x30660764A7a05B84608812C8AFC0Cb4845439EEe;
            eulerSwapper = 0x0D3d0F97eD816Ca3350D627AD8e57B6AD41774df;
            morpho = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
        // } else if (block.chainid == 146) { // sonic
        //     eulerOnchainRouter = 0x231811a9574dDE19e49f72F7c1cAC3085De6971a;
        //     eulerUSDC = 0x196F3C7443E940911EE2Bb88e019Fd71400349D9;
        //     eulerWETH = 0xa5cd24d9792F4F131f5976Af935A505D19c8Db2b;
        //     eulerWSTETH = 0x05d57366B862022F76Fe93316e81E9f24218bBfC;
        //     eulerSwapper = address(0); // TODO: Add Sonic swapper address
        //     eulerSwapVerifier = address(0); // TODO: Add Sonic swap verifier address
        //     morpho = address(0); // TODO: Add Sonic morpho address
        } else {
            revert UnknownProfile();
        }

        permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        USDC = IEVault(eulerUSDC).asset();
        WETH = IEVault(eulerWETH).asset();
        WSTETH = IEVault(eulerWSTETH).asset();

        vm.label(USDC, "USDC");
        vm.label(eulerWETH, "eulerWETH");
        vm.label(eulerUSDC, "eulerUSDC");
        vm.label(eulerWSTETH, "eulerWSTETH");
        vm.label(permit2, "permit2");
        vm.label(eulerOnchainRouter, "eulerOnchainRouter");
        admin = vm.envAddress("ADMIN_ETH_ADDRESS");
        feeReceiver = vm.envAddress("DEPLOYER_ADDRESS");
        deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        deployer = vm.envAddress("DEPLOYER_ADDRESS");

        // if (vm.envBool("PROD")) { // Run script against on-chain RPC
            productionSetup(); // sets up on-chain EVK deployment addresses from evk-periphery script
            twyneStuff();
        // } else if (!vm.envBool("PROD")) { // run without on-chain dependency
            // evkStuff(); // deploys fresh EVK contracts, simulating the evk-periphery script
            // twyneStuff();
        // }
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

    function serializeTwyneAddresses(TwyneAddresses memory Addresses) internal returns (string memory result) {
        result = vm.serializeAddress("twyneAddresses", "collateralVaultFactory", Addresses.collateralVaultFactory);
        result = vm.serializeAddress("twyneAddresses", "vaultManager", Addresses.vaultManager);
        result = vm.serializeAddress("twyneAddresses", "oracleRouter", Addresses.oracleRouter);
        result = vm.serializeAddress("twyneAddresses", "GenericFactory", Addresses.genericFactory);
        result = vm.serializeAddress("twyneAddresses", "intermediateVault", Addresses.intermediateVault);
        result = vm.serializeAddress("twyneAddresses", "deployerExampleCollateralVault", Addresses.deployerExampleCollateralVault);
        result = vm.serializeAddress("twyneAddresses", "healthStatViewer", Addresses.healthStatViewer);
        result = vm.serializeAddress("twyneAddresses", "leverageOperator", Addresses.leverageOperator);
    }

    function newIntermediateVault(address _asset, address _oracle, address _unitOfAccount) internal returns (IEVault) {
        IEVault new_vault = IEVault(factory.createProxy(address(0), true, abi.encodePacked(_asset, _oracle, _unitOfAccount)));

        log("New intermediate vault", address(new_vault));
        // set test values, these are placeholders for testing
        // set hook so all borrows and flashloans to use the bridge
        new_vault.setHookConfig(address(new BridgeHookTarget(address(collateralVaultFactory))), OP_BORROW | OP_LIQUIDATE | OP_FLASHLOAN);
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
        new_vault.setCaps(24339, 24339); // 38 WETH supply and borrow cap

        vaultManager.setOracleResolvedVault(address(new_vault), true);
        vaultManager.setOracleResolvedVault(_asset, true); // need to set this for recursive resolveOracle() lookup
        address eulerExternalOracle = EulerRouter(IEVault(_asset).oracle()).getConfiguredOracle(IEVault(_asset).asset(), USD);
        assert(keccak256(abi.encodePacked(EulerRouter(eulerExternalOracle).name())) == keccak256(abi.encodePacked("ChainlinkOracle")) || keccak256(abi.encodePacked(EulerRouter(eulerExternalOracle).name())) == keccak256(abi.encodePacked("CrossAdapter")));
        vaultManager.doCall(address(vaultManager.oracleRouter()), 0, abi.encodeCall(EulerRouter.govSetConfig, (IEVault(_asset).asset(), USD, eulerExternalOracle)));
        vaultManager.setIntermediateVault(new_vault);
        new_vault.setGovernorAdmin(address(vaultManager));

        require(new_vault.configFlags() & CFG_DONT_SOCIALIZE_DEBT == 0, "debt will not be socialized");
        return new_vault;
    }

    function evkStuff() public {
        vm.startBroadcast(deployerKey);
        evc = new EthereumVaultConnector();
        vm.label(address(evc), "evc");
        factory = new GenericFactory(deployer);
        vm.label(address(factory), "factory");

        protocolConfig = new ProtocolConfig(deployer, vm.envAddress("PROTOCOL_FEE_RECEIVER_ETH_ADDRESS"));
        protocolConfig.setInterestFeeRange(0, 0); // set fee range to zero
        protocolConfig.setProtocolFeeShare(0); // set protocol fee to zero
        balanceTracker = address(new MockBalanceTracker());
        sequenceRegistry = address(new SequenceRegistry());
        integrations =
            Base.Integrations(address(evc), address(protocolConfig), sequenceRegistry, balanceTracker, permit2);
        initializeModule = address(new Initialize(integrations));
        tokenModule = address(new Token(integrations));
        vaultModule = address(new Vault(integrations));
        borrowingModule = address(new Borrowing(integrations));
        liquidationModule = address(new Liquidation(integrations));
        riskManagerModule = address(new RiskManager(integrations));
        balanceForwarderModule = address(new BalanceForwarder(integrations));
        governanceModule = address(new Governance(integrations));
        modules = Dispatch.DeployedModules({
            initialize: initializeModule,
            token: tokenModule,
            vault: vaultModule,
            borrowing: borrowingModule,
            liquidation: liquidationModule,
            riskManager: riskManagerModule,
            balanceForwarder: balanceForwarderModule,
            governance: governanceModule
        });
        evaultImpl = address(new EVault(integrations, modules));

        // Remove this line for production deployment
        oracleRouter = new EulerRouter(address(evc), address(deployer));

        log("ethereumVaultConnector", address(evc));
        log("eulerOnchainRouter", eulerOnchainRouter);
        log("mockBalanceTracker", balanceTracker);
        log("deployer", deployer);
        console2.log("");
        factory.setImplementation(evaultImpl);

        vm.stopBroadcast();
    }

    function productionSetup() public {
        address oracleRouterFactory;
        if (block.chainid == 8453) {
            oracleRouterFactory = 0x72735e5dd42EDc979c600766532eA704842CfB7b;
            evc = EthereumVaultConnector(payable(0xC36aED7b7816aA21B660a33a637a8f9B9B70ad6c));
            factory = GenericFactory(0xd5e966dB359f1cB2A01280fCCBEB839Ac572CE35);
            protocolConfig = ProtocolConfig(0x3b68711EF6c1988c96CBD32d929b76cB09b579Ea);
        } else if (block.chainid == 1) {
            oracleRouterFactory = 0x72735e5dd42EDc979c600766532eA704842CfB7b;
            evc = EthereumVaultConnector(payable(0xC36aED7b7816aA21B660a33a637a8f9B9B70ad6c));
            factory = GenericFactory(0xd5e966dB359f1cB2A01280fCCBEB839Ac572CE35);
            protocolConfig = ProtocolConfig(0x3b68711EF6c1988c96CBD32d929b76cB09b579Ea);
        } else {
            console2.log("Only supports Base and mainnet right now");
            revert UnknownProfile();
        }

        vm.startBroadcast(deployerKey);
        protocolConfig.setInterestFeeRange(0, 0); // set fee range to zero
        protocolConfig.setProtocolFeeShare(0); // set protocol fee to zero
        oracleRouter = EulerRouter(EulerRouterFactory(oracleRouterFactory).deploy(deployer));
        vm.stopBroadcast();
    }

    function twyneStuff() public {
        vm.startBroadcast(deployerKey);

        // Deploy general Twyne contracts

        // Deploy CollateralVaultFactory implementation
        CollateralVaultFactory factoryImpl = new CollateralVaultFactory(address(evc));

        // Create initialization data for CollateralVaultFactory
        bytes memory factoryInitData = abi.encodeCall(CollateralVaultFactory.initialize, (deployer));

        // Deploy CollateralVaultFactory proxy
        ERC1967Proxy factoryProxy = new ERC1967Proxy(address(factoryImpl), factoryInitData);
        collateralVaultFactory = CollateralVaultFactory(payable(address(factoryProxy)));

        vm.label(address(collateralVaultFactory), "collateralVaultFactory");

        // Deploy VaultManager implementation
        VaultManager vaultManagerImpl = new VaultManager();

        // Create initialization data for VaultManager
        bytes memory vaultManagerInitData = abi.encodeCall(VaultManager.initialize, (deployer, address(collateralVaultFactory)));

        // Deploy VaultManager proxy
        ERC1967Proxy vaultManagerProxy = new ERC1967Proxy(address(vaultManagerImpl), vaultManagerInitData);
        vaultManager = VaultManager(payable(address(vaultManagerProxy)));

        vm.label(address(vaultManager), "vaultManager");

        eulerCollateralVaultImpl = address(new EulerCollateralVault(address(evc), eulerUSDC));

        healthViewer = new HealthStatViewer();

        // Deploy LeverageOperator
        leverageOperator = new LeverageOperator(
            address(evc),
            eulerSwapper,
            eulerSwapVerifier,
            morpho,
            address(collateralVaultFactory)
        );
        vm.label(address(leverageOperator), "leverageOperator");

        // Change ownership of EVK deploy contracts
        oracleRouter.transferGovernance(address(vaultManager));

        collateralVaultFactory.setBeacon(eulerUSDC, address(new UpgradeableBeacon(eulerCollateralVaultImpl, deployer)));
        collateralVaultFactory.setVaultManager(address(vaultManager));

        vaultManager.setOracleRouter(address(oracleRouter));
        vaultManager.setMaxLiquidationLTV(eulerWETH, 0.93e4);

        // First: deploy intermediate vault, then users can deploy corresponding collateral vaults
        eeWETH_intermediate_vault = newIntermediateVault(eulerWETH, address(oracleRouter), USD);

        vaultManager.setExternalLiqBuffer(eulerWETH, 1e4);
        require(IEVault(eulerUSDC).LTVBorrow(eeWETH_intermediate_vault.asset()) != 0, InvalidCollateral());
        vaultManager.setAllowedTargetVault(address(eeWETH_intermediate_vault), eulerUSDC);

        // Set CrossAdapter for handling the external liquidation case
        address baseAsset = USDC;
        address crossAsset = IEVault(eeWETH_intermediate_vault.asset()).unitOfAccount();
        address quoteAsset = IEVault(eeWETH_intermediate_vault.asset()).asset();
        address oracleBaseCross = EulerRouter(IEVault(eulerUSDC).oracle()).getConfiguredOracle(baseAsset, crossAsset);
        address oracleCrossQuote = oracleRouter.getConfiguredOracle(quoteAsset, crossAsset);
        CrossAdapter crossAdapterOracle = new CrossAdapter(baseAsset, crossAsset, quoteAsset, address(oracleBaseCross), address(oracleCrossQuote));
        vaultManager.doCall(address(vaultManager.oracleRouter()), 0, abi.encodeCall(EulerRouter.govSetConfig, (baseAsset, quoteAsset, address(crossAdapterOracle))));
        vaultManager.doCall(address(vaultManager.oracleRouter()), 0, abi.encodeCall(EulerRouter.govSetConfig, (baseAsset, USD, oracleBaseCross)));

        // Add assertions to verify the necessary oracle paths are properly setup
        require(vaultManager.oracleRouter().getQuote(1e16, eulerWETH, USD) != 0, "bad setup for collateral asset oracle"); // eWETH -> USD
        require(vaultManager.oracleRouter().getQuote(1e16, eeWETH_intermediate_vault.asset(), IEVault(eeWETH_intermediate_vault.asset()).unitOfAccount()) != 0, "bad setup for target asset oracle"); // eWETH -> USD
        require(vaultManager.oracleRouter().getQuote(1e16, USDC, WETH) != 0, "bad setup for target asset oracle"); // USDC -> WETH
        require(vaultManager.oracleRouter().getQuote(1e16, baseAsset, quoteAsset) != 0, "bad setup for target asset oracle"); // USDC -> WETH

        // Next: Deploy collateral vault
        deployer_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _asset: eulerWETH,
                _targetVault: eulerUSDC,
                _liqLTV: twyneLiqLTV
            })
        );
        vm.stopBroadcast();

        // Log to console the variables to be saved in TwyneAddresses output file
        log("collateralVaultFactory", address(collateralVaultFactory));
        log("vaultManager", address(vaultManager));
        log("Twyne EulerRouter_oracle", address(oracleRouter));
        log("genericFactory", address(factory));
        log("eeWETH_intermediate_vault", address(eeWETH_intermediate_vault));
        log("deployer_collateral_vault", address(deployer_collateral_vault));
        log("healthViewer", address(healthViewer));
        log("leverageOperator", address(leverageOperator));

        // Store the variables to be saved in TwyneAddresses output file
        TwyneAddresses memory twyneAddresses;
        twyneAddresses.collateralVaultFactory = address(collateralVaultFactory);
        twyneAddresses.vaultManager = address(vaultManager);
        twyneAddresses.oracleRouter = address(oracleRouter);
        twyneAddresses.genericFactory = address(factory);
        twyneAddresses.intermediateVault = address(eeWETH_intermediate_vault);
        twyneAddresses.deployerExampleCollateralVault = address(deployer_collateral_vault);
        twyneAddresses.healthStatViewer = address(healthViewer);
        twyneAddresses.leverageOperator = address(leverageOperator);
        string memory serializedTwyneAddresses = serializeTwyneAddresses(twyneAddresses);

        vm.writeJson(serializedTwyneAddresses, "./TwyneAddresses_output.json");
    }
}