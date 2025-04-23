// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/Vm.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {MockBalanceTracker} from "euler-vault-kit/../test/mocks/MockBalanceTracker.sol";
import {IRMLinearKink} from "euler-vault-kit/InterestRateModels/IRMLinearKink.sol";
import {EVault} from "euler-vault-kit/EVault/EVault.sol";
import {SequenceRegistry} from "euler-vault-kit/SequenceRegistry/SequenceRegistry.sol";
import {GenericFactory} from "euler-vault-kit/GenericFactory/GenericFactory.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
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
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {BridgeHookTarget} from "src/TwyneFactory/BridgeHookTarget.sol";
import {OP_BORROW, OP_LIQUIDATE, OP_FLASHLOAN, OP_SKIM, CFG_DONT_SOCIALIZE_DEBT} from "euler-vault-kit/EVault/shared/Constants.sol";
import {EulerCollateralVault} from "src/twyne/EulerCollateralVault.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";
import {HealthStatViewer} from "src/twyne/HealthStatViewer.sol";

interface EulerRouterFactory {
    function deploy(address) external returns (address);
}

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

    address deployer;
    address admin;
    address feeReceiver;
    uint256 deployerKey;


    uint constant twyneLiqLTV = 0.98e4;

    error UnknownProfile();

    struct TwyneAddresses {
        address collateralVaultFactory;
        address vaultManager;
        address oracleRouter;
        address genericFactory;
        address intermediateVault;
        address deployerExampleCollateralVault;
        address healthStatViewer;
    }

    function run() public {
        string memory foundryProfile = vm.envString("FOUNDRY_PROFILE");
        if (keccak256(abi.encodePacked((foundryProfile))) == keccak256(abi.encodePacked(("baseProd"))) ||
        keccak256(abi.encodePacked((foundryProfile))) == keccak256(abi.encodePacked(("base")))) {
            eulerOnchainRouter = 0x6E183458600e66047A0f4D356d9DAa480DA1CA59;
            eulerUSDC = 0x0A1a3b5f2041F33522C4efc754a7D096f880eE16;
            eulerWETH = 0x859160DB5841E5cfB8D3f144C6b3381A85A4b410;
            eulerWSTETH = 0x7b181d6509DEabfbd1A23aF1E65fD46E89572609;
        } else if (keccak256(abi.encodePacked((foundryProfile))) == keccak256(abi.encodePacked(("sonicProd"))) ||
        keccak256(abi.encodePacked((foundryProfile))) == keccak256(abi.encodePacked(("sonic")))) {
            eulerOnchainRouter = 0x231811a9574dDE19e49f72F7c1cAC3085De6971a;
            eulerUSDC = 0x196F3C7443E940911EE2Bb88e019Fd71400349D9;
            eulerWETH = 0xa5cd24d9792F4F131f5976Af935A505D19c8Db2b;
            eulerWSTETH = 0x05d57366B862022F76Fe93316e81E9f24218bBfC;
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

        if (keccak256(abi.encodePacked((foundryProfile))) == keccak256(abi.encodePacked(("baseProd"))) ||
        keccak256(abi.encodePacked((foundryProfile))) == keccak256(abi.encodePacked(("sonicProd")))) {
            productionSetup(); // comment this out for testing
            twyneStuff();
        } else if (keccak256(abi.encodePacked((foundryProfile))) == keccak256(abi.encodePacked(("base"))) ||
        keccak256(abi.encodePacked((foundryProfile))) == keccak256(abi.encodePacked(("sonic")))) {
            evkStuff(); // comment this out for production
            twyneStuff();
            setAdminOwnership(); // comment this out for production
        } else {

        }
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
    }

    function newIntermediateVault(address _asset, address _oracle, address _unitOfAccount) internal returns (IEVault) {
        IEVault new_vault = IEVault(factory.createProxy(address(0), true, abi.encodePacked(_asset, _oracle, _unitOfAccount)));

        log("New intermediate vault", address(new_vault));
        // set test values, these are placeholders for testing
        // set hook so all borrows and flashloans to use the bridge
        new_vault.setHookConfig(address(new BridgeHookTarget(address(collateralVaultFactory))), OP_BORROW | OP_LIQUIDATE | OP_FLASHLOAN | OP_SKIM);
        // Base=0.00% APY,  Kink(80.00%)=20.00% APY  Max=120.00% APY
        new_vault.setInterestRateModel(address(new IRMLinearKink(0, 1681485479, 22360681293, 3435973836)));
        new_vault.setMaxLiquidationDiscount(0.2e4);
        new_vault.setLiquidationCoolOffTime(1);
        new_vault.setFeeReceiver(feeReceiver);
        new_vault.setInterestFee(0); // set zero governance fee
        new_vault.setCaps(32018, 32018); // 5 WETH supply and borrow cap

        vaultManager.setOracleResolvedVault(address(new_vault), true);
        vaultManager.setOracleResolvedVault(_asset, true); // need to set this for recursive resolveOracle() lookup
        address eulerExternalOracle = EulerRouter(IEVault(_asset).oracle()).getConfiguredOracle(IEVault(_asset).asset(), USD);
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
        address oracleRouterFactory = 0xF28c7B9cfae33De0dADdD168F1c3a0Ecd047c423;
        evc = EthereumVaultConnector(payable(0x05CD7a2eB03C361F0Fe18374dC381E5918Ff9D74));

        vm.startBroadcast(deployerKey);
        oracleRouter = EulerRouter(EulerRouterFactory(oracleRouterFactory).deploy(deployer));
        vm.stopBroadcast();
        factory = GenericFactory(0xa76C7B314c310ABb3Fb7c68778C0C3369cAf24Fc);
    }

    function twyneStuff() public {
        vm.startBroadcast(deployerKey);

        // Deploy general Twyne contracts
        collateralVaultFactory = new CollateralVaultFactory(deployer, address(evc));
        vm.label(address(collateralVaultFactory), "collateralVaultFactory");
        vaultManager = new VaultManager(deployer, address(collateralVaultFactory));
        vm.label(address(vaultManager), "vaultManager");

        eulerCollateralVaultImpl = address(new EulerCollateralVault(address(evc), eulerUSDC));

        healthViewer = new HealthStatViewer();

        // Change ownership of EVK deploy contracts
        oracleRouter.transferGovernance(address(vaultManager));

        collateralVaultFactory.setBeacon(eulerUSDC, address(new UpgradeableBeacon(eulerCollateralVaultImpl, deployer)));
        collateralVaultFactory.setVaultManager(address(vaultManager));

        vaultManager.setOracleRouter(address(oracleRouter));
        vaultManager.setMaxLiquidationLTV(eulerWETH, 0.98e4);

        // First: deploy intermediate vault, then users can deploy corresponding collateral vaults
        eeWETH_intermediate_vault = newIntermediateVault(eulerWETH, address(oracleRouter), USD);

        vaultManager.setExternalLiqBuffer(eulerWETH, 0.95e4);
        vaultManager.setAllowedTargetVault(address(eeWETH_intermediate_vault), eulerUSDC);

        // Next: Deploy collateral vault
        deployer_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createCollateralVault({
                _asset: eulerWETH,
                _targetVault: eulerUSDC,
                _liqLTV: twyneLiqLTV
            })
        );
        vm.stopBroadcast();

        // Log to console the 7 variables to be saved in TwyneAddresses output file
        log("collateralVaultFactory", address(collateralVaultFactory));
        log("vaultManager", address(vaultManager));
        log("Twyne EulerRouter_oracle", address(oracleRouter));
        log("genericFactory", address(factory));
        log("eeWETH_intermediate_vault", address(eeWETH_intermediate_vault));
        log("deployer_collateral_vault", address(deployer_collateral_vault));
        log("healthViewer", address(healthViewer));

        // Store the 7 variables to be saved in TwyneAddresses output file
        TwyneAddresses memory twyneAddresses;
        twyneAddresses.collateralVaultFactory = address(collateralVaultFactory);
        twyneAddresses.vaultManager = address(vaultManager);
        twyneAddresses.oracleRouter = address(oracleRouter);
        twyneAddresses.genericFactory = address(factory);
        twyneAddresses.intermediateVault = address(eeWETH_intermediate_vault);
        twyneAddresses.deployerExampleCollateralVault = address(deployer_collateral_vault);
        twyneAddresses.healthStatViewer = address(healthViewer);
        string memory serializedTwyneAddresses = serializeTwyneAddresses(twyneAddresses);

        vm.writeJson(serializedTwyneAddresses, "./TwyneAddresses_output.json");
    }

    function setAdminOwnership() public {
        // Set production deployment owner
        vm.startBroadcast(deployerKey);
        factory.setUpgradeAdmin(admin);
        collateralVaultFactory.transferOwnership(admin);
        vaultManager.doCall(address(oracleRouter), 0, abi.encodeCall(oracleRouter.transferGovernance, admin));
        vaultManager.transferOwnership(admin);
        require(factory.upgradeAdmin() == admin, "factory needs to be set to correct admin");
        require(collateralVaultFactory.owner() == admin, "collateralVaultFactory needs to be set to correct admin");
        require(oracleRouter.governor() == admin, "factory needs to be set to correct admin");
        require(vaultManager.owner() == admin, "vaultManager needs to be set to correct admin");
        vm.stopBroadcast();
    }
}