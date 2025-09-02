// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "forge-std/Vm.sol";
import {console2} from "forge-std/Test.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {GenericFactory} from "euler-vault-kit/GenericFactory/GenericFactory.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {ProtocolConfig} from "euler-vault-kit/ProtocolConfig/ProtocolConfig.sol";
import {USD} from "euler-price-oracle/test/utils/EthereumAddresses.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {IEVault, IERC20} from "euler-vault-kit/EVault/IEVault.sol";
import {OP_BORROW, OP_LIQUIDATE, OP_FLASHLOAN, OP_SKIM, CFG_DONT_SOCIALIZE_DEBT} from "euler-vault-kit/EVault/shared/Constants.sol";
import {EulerCollateralVault} from "src/twyne/EulerCollateralVault.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";
import {HealthStatViewer} from "src/twyne/HealthStatViewer.sol";

contract TestBeaconImpl {
    function kjarjnwr() external pure returns (uint) {
        return 724976297862;
    }
}

/// @title PostDeploymentCheck
/// @notice Comprehensive post-deployment verification for Twyne contracts
contract PostDeploymentCheck is Script {
    // set asset addresses
    address eulerOnchainRouter;
    address eulerWETH;
    address eulerUSDC;
    address eulerBTC;
    address eulerwstETH;
    address eulerUSDS;

    address WETH;
    address USDC;
    address USDS;

    EthereumVaultConnector evc;

    CollateralVaultFactory collateralVaultFactory;
    VaultManager vaultManager;
    EulerRouter oracleRouter;
    GenericFactory factory;
    IEVault intermediateVault;
    EulerCollateralVault deployer_collateral_vault;
    HealthStatViewer healthViewer;

    address admin;

    uint constant twyneLiqLTV = 0.90e4;

    error UnknownProfile();

    struct TwyneAddresses {
        address genericFactory;
        address collateralVaultFactory;
        address deployerExampleCollateralVault;
        address healthStatViewer;
        address intermediateVault;
        address oracleRouter;
        address vaultManager;
    }

    function run() public {
        if (block.chainid == 1) { // mainnet
            eulerOnchainRouter = 0x83B3b76873D36A28440cF53371dF404c42497136;
            eulerWETH = 0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2;
            eulerUSDC = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
            eulerBTC = 0x998D761eC1BAdaCeb064624cc3A1d37A46C88bA4;
            eulerwstETH = 0xbC4B4AC47582c3E38Ce5940B80Da65401F4628f1;
            eulerUSDS = 0x07F9A54Dc5135B9878d6745E267625BF0E206840;
        } else if (block.chainid == 8453) { // base
            eulerOnchainRouter = 0x6E183458600e66047A0f4D356d9DAa480DA1CA59;
            eulerWETH = 0x859160DB5841E5cfB8D3f144C6b3381A85A4b410;
            eulerUSDC = 0x0A1a3b5f2041F33522C4efc754a7D096f880eE16;
            eulerBTC = 0x882018411Bc4A020A879CEE183441fC9fa5D7f8B;
            eulerwstETH = 0x7b181d6509DEabfbd1A23aF1E65fD46E89572609;
            eulerUSDS = 0x556d518FDFDCC4027A3A1388699c5E11AC201D8b;
        } else if (block.chainid == 146) { // sonic
            eulerOnchainRouter = 0x231811a9574dDE19e49f72F7c1cAC3085De6971a;
            eulerWETH = 0xa5cd24d9792F4F131f5976Af935A505D19c8Db2b;
            eulerUSDC = 0x196F3C7443E940911EE2Bb88e019Fd71400349D9;
        } else {
            revert UnknownProfile();
        }
        USDC = IEVault(eulerUSDC).asset();
        WETH = IEVault(eulerWETH).asset();
        USDS = IEVault(eulerUSDS).asset();

        admin = vm.envAddress("ADMIN_ETH_ADDRESS");

        string memory twyneAddressesJson = vm.readFile("./TwyneAddresses_output.json");
        collateralVaultFactory = CollateralVaultFactory(vm.parseJsonAddress(twyneAddressesJson, ".collateralVaultFactory"));
        vaultManager = VaultManager(payable(vm.parseJsonAddress(twyneAddressesJson, ".vaultManager")));
        oracleRouter = EulerRouter(vm.parseJsonAddress(twyneAddressesJson, ".oracleRouter"));
        factory = GenericFactory(vm.parseJsonAddress(twyneAddressesJson, ".GenericFactory"));
        intermediateVault = IEVault(vm.parseJsonAddress(twyneAddressesJson, ".intermediateVault"));
        deployer_collateral_vault = EulerCollateralVault(vm.parseJsonAddress(twyneAddressesJson, ".deployerExampleCollateralVault"));
        healthViewer = HealthStatViewer(vm.parseJsonAddress(twyneAddressesJson, ".healthStatViewer"));
        evc = EthereumVaultConnector(payable(collateralVaultFactory.EVC()));
        vm.label(address(eulerOnchainRouter), "eulerOnchainRouter");
        vm.label(address(collateralVaultFactory), "collateralVaultFactory");
        vm.label(address(oracleRouter), "oracleRouter");
        vm.label(address(factory), "factory");
        vm.label(address(intermediateVault), "intermediateVault");
        vm.label(address(deployer_collateral_vault), "deployer_collateral_vault");
        vm.label(address(healthViewer), "healthViewer");
        vm.label(address(evc), "evc");

        runAllChecks();
    }

    /// @notice Run all post-deployment verification checks
    function runAllChecks() internal {
        checkContractDeployments();
        checkOwnershipAndGovernance();
        checkFactoryConfiguration();
        checkVaultManagerConfiguration();
        checkIntermediateVaultConfiguration();
        checkCollateralVaultConfiguration();
        checkOracleConfiguration();
        checkSecurityConfiguration();
        checkIntegrationBetweenContracts();
        checkParameterBounds();
        console2.log("All checks complete, looks good!");
    }

    /// @notice Verify all contracts are deployed with non-zero addresses
    function checkContractDeployments() internal view {
        require(address(collateralVaultFactory) != address(0), "CollateralVaultFactory not deployed");
        require(address(vaultManager) != address(0), "VaultManager not deployed");
        require(address(oracleRouter) != address(0), "OracleRouter not deployed");
        require(address(intermediateVault) != address(0), "Intermediate vault not deployed");
        require(address(deployer_collateral_vault) != address(0), "Collateral vault not deployed");
        require(address(healthViewer) != address(0), "HealthStatViewer not deployed");

        // Check that contracts have code
        require(address(collateralVaultFactory).code.length > 0, "CollateralVaultFactory has no code");
        require(address(vaultManager).code.length > 0, "VaultManager has no code");
        require(address(oracleRouter).code.length > 0, "OracleRouter has no code");
        require(address(intermediateVault).code.length > 0, "Intermediate vault has no code");
        require(address(deployer_collateral_vault).code.length > 0, "Collateral vault has no code");
        require(address(healthViewer).code.length > 0, "HealthStatViewer has no code");
    }

    /// @notice Verify ownership and governance setup
    function checkOwnershipAndGovernance() internal view {
        require(vaultManager.owner() == admin, "VaultManager owner incorrect");
        require(collateralVaultFactory.owner() == admin, "CollateralVaultFactory owner incorrect");
        require(oracleRouter.governor() == address(vaultManager), "OracleRouter governor should be VaultManager");
        require(intermediateVault.governorAdmin() == address(vaultManager), "Intermediate vault governor incorrect");
        require(admin != address(0), "Admin address is zero");

        address beacon = collateralVaultFactory.collateralVaultBeacon(deployer_collateral_vault.targetVault());
        require(UpgradeableBeacon(beacon).owner() == admin, "Beacon owner incorrect");
    }

    /// @notice Verify CollateralVaultFactory configuration
    function checkFactoryConfiguration() internal {
        require(address(collateralVaultFactory.vaultManager()) == address(vaultManager), "Factory VaultManager not set correctly");
        require(address(collateralVaultFactory.EVC()) == address(evc), "Factory EVC not set correctly");
        address beacon = collateralVaultFactory.collateralVaultBeacon(deployer_collateral_vault.targetVault());
        require(beacon != address(0), "Beacon not set for eulerUSDC");
        require(beacon.code.length > 0, "Beacon has no code");

        // Verify beacon points to correct implementation
        address beaconImpl = UpgradeableBeacon(beacon).implementation();
        address testBeaconImpl = address(new TestBeaconImpl());
        bytes memory code = beaconImpl.code;
        vm.etch(beaconImpl, testBeaconImpl.code);

        require(TestBeaconImpl(address(deployer_collateral_vault)).kjarjnwr() == 724976297862, "Beacon implementation incorrect");

        vm.etch(beaconImpl, code);
    }

    /// @notice Verify VaultManager configuration
    function checkVaultManagerConfiguration() internal view {
        // Check oracle router is set
        require(address(vaultManager.oracleRouter()) == address(oracleRouter), "VaultManager oracle router not set");

        // Check collateral vault factory is set
        require(address(vaultManager.collateralVaultFactory()) == address(collateralVaultFactory), "VaultManager factory not set");

        address collateralAsset = intermediateVault.asset();
        // Check max liquidation LTV for eulerWETH
        uint256 maxLiqLTV = vaultManager.maxTwyneLTVs(collateralAsset);
        require(maxLiqLTV == 0.93e4, "Max liquidation LTV not set correctly");
        require(maxLiqLTV > twyneLiqLTV, "Max liquidation LTV should be greater than twyne LTV");

        // Check external liquidation buffer
        uint256 extLiqBuffer = vaultManager.externalLiqBuffers(collateralAsset);
        require(extLiqBuffer == 1e4, "External liquidation buffer not set correctly");

        // Check allowed target vault
        require(vaultManager.isAllowedTargetVault(address(intermediateVault), deployer_collateral_vault.targetVault()), "Target vault not allowed");

        // Check oracle resolved vaults
        require(vaultManager.oracleRouter().resolvedVaults(address(intermediateVault)) == collateralAsset, "Intermediate vault not oracle resolved");
        require(vaultManager.oracleRouter().resolvedVaults(collateralAsset) == IEVault(collateralAsset).asset(), "Intermediate vault not oracle resolved");

        // Check intermediate vault is set
        require(address(vaultManager.getIntermediateVault(collateralAsset)) == address(intermediateVault), "Intermediate vault not set in VaultManager");
    }

    /// @notice Verify intermediate vault configuration
    function checkIntermediateVaultConfiguration() internal view {
        // Check basic vault properties
        require(address(intermediateVault.oracle()) == address(oracleRouter), "Intermediate vault oracle incorrect");
        require(intermediateVault.unitOfAccount() == USD, "Intermediate vault unit of account incorrect");

        // Check hook configuration
        (address hookTarget, uint32 hookedOps) = intermediateVault.hookConfig();
        require(hookTarget != address(0), "Hook target not set");
        require(hookedOps & OP_BORROW != 0, "Borrow hook not set");
        require(hookedOps & OP_LIQUIDATE != 0, "Liquidate hook not set");
        require(hookedOps & OP_FLASHLOAN != 0, "Flashloan hook not set");

        // Check interest rate model is set
        require(intermediateVault.interestRateModel() != address(0), "Interest rate model not set");

        // Check liquidation parameters
        require(intermediateVault.maxLiquidationDiscount() == 0.2e4, "Max liquidation discount incorrect");
        require(intermediateVault.liquidationCoolOffTime() == 1, "Liquidation cooloff time incorrect");

        // Check fee configuration
        require(intermediateVault.feeReceiver() == admin, "Fee receiver incorrect");
        require(intermediateVault.interestFee() == 0, "Interest fee should be zero");

        // Check caps are set
        (uint16 supplyCap, uint16 borrowCap) = intermediateVault.caps();
        require(supplyCap != 0, "Supply cap is zero");
        require(borrowCap != 0, "Borrow cap is zero");

        // Check debt socialization is enabled
        require(intermediateVault.configFlags() & CFG_DONT_SOCIALIZE_DEBT == 0, "Debt socialization should be enabled");
    }

    /// @notice Verify collateral vault configuration
    function checkCollateralVaultConfiguration() internal view {
        // Check basic properties
        require(deployer_collateral_vault.asset() == intermediateVault.asset(), "Collateral vault asset incorrect");

        // Check EVC integration
        require(address(deployer_collateral_vault.EVC()) == address(evc), "Collateral vault EVC incorrect");

        // Verify vault is properly registered
        require(collateralVaultFactory.isCollateralVault(address(deployer_collateral_vault)), "Collateral vault not registered in factory");
    }

    /// @notice Verify oracle configuration and pricing
    function checkOracleConfiguration() internal view {
        address collateralAsset = intermediateVault.asset();
        address underlyingCollateralAsset = IEVault(collateralAsset).asset();
        address targetAsset = deployer_collateral_vault.targetAsset();
        // Verify existing oracle checks from original script
        require(vaultManager.oracleRouter().getQuote(1e18, collateralAsset, USD) != 0, "eulerWETH -> USD oracle not working");
        require(vaultManager.oracleRouter().getQuote(1e18, underlyingCollateralAsset, IEVault(collateralAsset).unitOfAccount()) != 0, "Intermediate vault asset oracle not working");
        require(vaultManager.oracleRouter().getQuote(1e18, targetAsset, underlyingCollateralAsset) != 0, "USDC -> WETH oracle not working");

        // Additional oracle checks
        require(vaultManager.oracleRouter().getQuote(1e18, underlyingCollateralAsset, USD) != 0, "WETH -> USD oracle not working");
        require(vaultManager.oracleRouter().getQuote(1e18, targetAsset, USD) != 0, "USDC -> USD oracle not working");

        // Check oracle prices are reasonable (not zero, not extremely high)
        if (collateralAsset == eulerWETH) {
            uint256 wethPrice = vaultManager.oracleRouter().getQuote(1e18, underlyingCollateralAsset, USD);
            require(wethPrice > 1000e18 && wethPrice < 10000e18, "WETH price seems unreasonable");
        }

        if (targetAsset == USDC || targetAsset == USDS) {
            uint256 usdcPrice = vaultManager.oracleRouter().getQuote(10**uint(IERC20(targetAsset).decimals()), targetAsset, USD);
            require(usdcPrice > 0.95e18 && usdcPrice < 1.05e18, "USDC price should be close to $1");
        }
    }

    /// @notice Verify security-related configurations
    function checkSecurityConfiguration() internal view {
        // Check protocol config settings
        ProtocolConfig protocolConfig = ProtocolConfig(IEVault(intermediateVault).protocolConfigAddress());
        (address feeReceiver, uint16 fees) = protocolConfig.protocolFeeConfig(address(0));
        require(fees == 0, "Protocol fee should be zero");
        require(feeReceiver == admin, "Fee receiver should be admin");
        (uint256 minFee, uint256 maxFee) = protocolConfig.interestFeeRange(address(0));
        require(minFee == 0 && maxFee == 0, "Interest fee range should be zero");

        // Check critical parameters are within safe bounds
        require(twyneLiqLTV <= 0.95e4, "Liquidation LTV too high");
        require(twyneLiqLTV >= 0.5e4, "Liquidation LTV too low");

        // Check that max liquidation LTV is higher than twyne LTV
        uint256 maxLiqLTV = vaultManager.maxTwyneLTVs(intermediateVault.asset());
        require(maxLiqLTV > twyneLiqLTV, "Max liquidation LTV should be higher than twyne LTV");
        require(maxLiqLTV <= 0.95e4, "Max liquidation LTV too high");
    }

    /// @notice Check integration between different contracts
    function checkIntegrationBetweenContracts() internal view {
        // Check VaultManager can call OracleRouter
        require(address(vaultManager.oracleRouter()) == address(oracleRouter), "VaultManager-OracleRouter integration broken");

        // Check CollateralVaultFactory can create vaults with proper beacons
        address beacon = collateralVaultFactory.collateralVaultBeacon(deployer_collateral_vault.targetVault());
        require(beacon != address(0), "Beacon integration broken");

        // Check that collateral vault was created through factory
        require(collateralVaultFactory.isCollateralVault(address(deployer_collateral_vault)), "Factory-CollateralVault integration broken");

        // Check EVC integration across contracts
        require(address(collateralVaultFactory.EVC()) == address(evc), "CollateralVaultFactory-EVC integration broken");
        require(address(intermediateVault.EVC()) == address(evc), "Intermediate vault-EVC integration broken");
        require(address(deployer_collateral_vault.EVC()) == address(evc), "CollateralVault-EVC integration broken");
    }

    /// @notice Verify parameter bounds and limits
    function checkParameterBounds() internal view {
        // Check vault caps are reasonable
        (uint16 supplyCap, uint16 borrowCap) = intermediateVault.caps();
        require(supplyCap > 0 && supplyCap < type(uint16).max, "Supply cap out of bounds");
        require(borrowCap > 0 && borrowCap < type(uint16).max, "Borrow cap out of bounds");

        // Check liquidation parameters
        require(intermediateVault.maxLiquidationDiscount() <= 0.5e4, "Max liquidation discount too high");
        require(intermediateVault.liquidationCoolOffTime() > 0, "Liquidation cooloff time should be positive");

        // Check LTV values
        require(deployer_collateral_vault.twyneLiqLTV() <= vaultManager.maxTwyneLTVs(intermediateVault.asset()), "Collateral vault LTV exceeds maximum");
    }
}