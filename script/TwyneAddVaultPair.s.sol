// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import {BatchScript} from "forge-safe/src/BatchScript.sol";
import {IRMTwyneCurve} from "src/twyne/IRMTwyneCurve.sol";
import {GenericFactory} from "euler-vault-kit/GenericFactory/GenericFactory.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {USD} from "euler-price-oracle/test/utils/EthereumAddresses.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {CrossAdapter} from "euler-price-oracle/src/adapter/CrossAdapter.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {BridgeHookTarget} from "src/TwyneFactory/BridgeHookTarget.sol";
import {OP_BORROW, OP_LIQUIDATE, OP_FLASHLOAN, CFG_DONT_SOCIALIZE_DEBT} from "euler-vault-kit/EVault/shared/Constants.sol";
import {EulerCollateralVault} from "src/twyne/EulerCollateralVault.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @title TwyneAddVaultPair
/// @notice To contact the team regarding security matters, visit https://twyne.xyz/security
/// @dev This script adds a new vault pair to the Twyne protocol.
///      It requires the addresses of the collateral and target Euler vaults to be set as environment variables.
///      COLLATERAL_ASSET_EULER_VAULT: The address of the Euler vault for the collateral asset.
///      TARGET_ASSET_EULER_VAULT: The address of the Euler vault for the target asset.
///      It reads the deployed Twyne contract addresses from `TwyneAddresses_output.json`.
///      PHASE: Set to 0 for contract deployments, 1 configuring deployed contracts.
contract TwyneAddVaultPair is BatchScript {
    address SAFE = 0x8f822A1b550733822bCD4681B44373552c46f940; // set SAFE address
    uint PHASE = 10; // this will revert, intentionally set this way to make the deployer explicitly set this value

    // Contract addresses loaded from JSON
    CollateralVaultFactory collateralVaultFactory;
    VaultManager twyneVaultManager;
    EulerRouter oracleRouter;
    GenericFactory factory;
    address evc;
    address eulerWETH;
    address eulerUSDC;
    address eulerBTC;
    address eulerwstETH;
    address eulerUSDS;

    uint16 supplyCap;

    uint256 deployerKey;


    error UnknownProfile();
    error InvalidCollateral();
    error InvalidPhase();

    function run() public isBatch(SAFE) {
        if (block.chainid == 1) {
            eulerWETH = 0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2;
            eulerUSDC = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
            eulerBTC = 0x998D761eC1BAdaCeb064624cc3A1d37A46C88bA4;
            eulerwstETH = 0xbC4B4AC47582c3E38Ce5940B80Da65401F4628f1;
            eulerUSDS = 0x07F9A54Dc5135B9878d6745E267625BF0E206840;
        } else if (block.chainid == 8453) {
            eulerWETH = 0x859160DB5841E5cfB8D3f144C6b3381A85A4b410;
            eulerUSDC = 0x0A1a3b5f2041F33522C4efc754a7D096f880eE16;
            eulerBTC = 0x882018411Bc4A020A879CEE183441fC9fa5D7f8B;
            eulerwstETH = 0x7b181d6509DEabfbd1A23aF1E65fD46E89572609;
            eulerUSDS = 0x556d518FDFDCC4027A3A1388699c5E11AC201D8b;
        } else {
            revert UnknownProfile();
        }

        require (PHASE <= 1, InvalidPhase());

        deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // TODO Update these assets to meet needs
        // assets should be eTokens (not the base asset)
        address collateralAssetVault = eulerWETH;
        address targetAssetVault = eulerUSDS;
        supplyCap = 24339;

        loadTwyneAddresses();

        if (PHASE == 0) {
            phase0(collateralAssetVault, targetAssetVault);
        } else if (PHASE == 1) {
            phase1(collateralAssetVault, targetAssetVault);
        } else {
            revert("PHASE not set correctly");
        }

        executeBatch(PHASE == 1);
    }

    function loadTwyneAddresses() internal {
        string memory twyneAddressesJson = vm.readFile("./TwyneAddresses_output.json");
        collateralVaultFactory = CollateralVaultFactory(vm.parseJsonAddress(twyneAddressesJson, ".collateralVaultFactory"));
        twyneVaultManager = VaultManager(payable(vm.parseJsonAddress(twyneAddressesJson, ".vaultManager")));
        oracleRouter = EulerRouter(vm.parseJsonAddress(twyneAddressesJson, ".oracleRouter"));
        factory = GenericFactory(vm.parseJsonAddress(twyneAddressesJson, ".GenericFactory"));
        evc = collateralVaultFactory.EVC();
    }

    function verifyeVault(address vaultAddress) internal view {
        assert(IEVault(vaultAddress).EVC() != address(0));
        assert(IEVault(vaultAddress).permit2Address() != address(0));
        assert(IEVault(vaultAddress).unitOfAccount() == USD);
    }

    // Phase 0: Deploy contracts which can be deployed by any EOA
    function phase0(address _collateralAsset, address _targetAsset) internal {
        verifyeVault(_collateralAsset);
        verifyeVault(_targetAsset);

        vm.startBroadcast(deployerKey);

        // 1. Deploy new intermediate vault for the collateral asset
        IEVault new_intermediate_vault;
        bool newVaultCreated = false;
        // if intermediate vault already exists, use it. Otherwise, create a new one.
        try twyneVaultManager.getIntermediateVault(_collateralAsset) returns (address vault) {
            new_intermediate_vault = IEVault(vault);
        // if revert encountered because the vault does not exist, create new intermediate vault
        } catch {
            new_intermediate_vault = newIntermediateVault(_collateralAsset, address(oracleRouter), USD);
            newVaultCreated = true;
        }

        // 4. Set up CrossAdapter for external liquidations
        address underlyingTarget = IEVault(_targetAsset).asset();
        address underlyingCollateral = IEVault(_collateralAsset).asset();

        CrossAdapter crossAdapterOracle;
        if (oracleRouter.getConfiguredOracle(underlyingTarget, underlyingCollateral) == address(0)) {
            // The oracle for targetAsset -> USD is on Euler's main oracle router
            address oracleBaseCross = EulerRouter(IEVault(_targetAsset).oracle()).getConfiguredOracle(underlyingTarget, USD);
            // The oracle for collateralAsset -> USD is on our Twyne oracle router
            address oracleCrossQuote = EulerRouter(IEVault(_targetAsset).oracle()).getConfiguredOracle(underlyingCollateral, USD);
            crossAdapterOracle = new CrossAdapter(underlyingTarget, USD, underlyingCollateral, oracleBaseCross, oracleCrossQuote);
        }

        // deploy collateral vault implementation and new beacon for multisig to use later
        UpgradeableBeacon newUpgrBeacon;
        if (collateralVaultFactory.collateralVaultBeacon(_targetAsset) == address(0)) {
            newUpgrBeacon = new UpgradeableBeacon(address(new EulerCollateralVault(address(evc), _targetAsset)), twyneVaultManager.owner());
            console2.log("New beacon", address(newUpgrBeacon));
        }

        vm.stopBroadcast();

        string memory deploymentJson = "deployment";
        vm.serializeAddress(deploymentJson, "newUpgrBeacon", address(newUpgrBeacon));
        vm.serializeAddress(deploymentJson, "crossAdapterOracle", address(crossAdapterOracle));

        // Add additional metadata
        vm.serializeAddress(deploymentJson, "collateralAsset", _collateralAsset);
        vm.serializeAddress(deploymentJson, "targetAsset", _targetAsset);
        vm.serializeAddress(deploymentJson, "underlyingTarget", underlyingTarget);
        vm.serializeAddress(deploymentJson, "underlyingCollateral", underlyingCollateral);
        vm.serializeUint(deploymentJson, "timestamp", block.timestamp);
        string memory finalJson = vm.serializeUint(deploymentJson, "chainId", block.chainid);

        // Write to file
        string memory fileName = string.concat("VaultPairDeploymentPhase0_", vm.toString(block.chainid), ".json");
        vm.writeJson(finalJson, fileName);

        console2.log("Deployment data serialized to:", fileName);
    }

    // Phase 1: Configure the contracts deployed in phase 0 and 1
    function phase1(address _collateralAsset, address _targetAsset) internal {
        // Read deployment data from phase 0
        string memory fileName = string.concat("VaultPairDeploymentPhase0_", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(fileName);

        // Parse beacon and oracle addresses
        address newBeacon = abi.decode(vm.parseJson(json, ".newUpgrBeacon"), (address));
        address crossAdapterOracle = abi.decode(vm.parseJson(json, ".crossAdapterOracle"), (address));

        // Get the intermediate vault that should have been created in phase 0
        IEVault new_intermediate_vault;
        try twyneVaultManager.getIntermediateVault(_collateralAsset) returns (address vault) {
            new_intermediate_vault = IEVault(vault);
        } catch {
            revert("Intermediate vault not found. Run phase 0 first.");
        }

        require(address(new_intermediate_vault) != address(0), "intermediate vault shouldn't be address(0)");

        bool newVaultCreated = new_intermediate_vault.interestRateModel() == address(0);

        ///////////////////////////////////////
        multisigSetup(new_intermediate_vault, _collateralAsset, _targetAsset, CrossAdapter(crossAdapterOracle), newBeacon, newVaultCreated);
    }

    function newIntermediateVault(address _asset, address _oracle, address _unitOfAccount) internal returns (IEVault) {
        IEVault new_vault = IEVault(factory.createProxy(address(0), true, abi.encodePacked(_asset, _oracle, _unitOfAccount)));

        console2.log("New intermediate vault", address(new_vault));
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
        new_vault.setFeeReceiver(twyneVaultManager.owner());
        new_vault.setInterestFee(0); // set zero governance fee
        new_vault.setCaps(supplyCap, supplyCap); // 38 WETH supply and borrow cap

        new_vault.setGovernorAdmin(address(twyneVaultManager));

        require(new_vault.configFlags() & CFG_DONT_SOCIALIZE_DEBT == 0, "debt will not be socialized");
        return new_vault;
    }

    function multisigSetup(IEVault new_vault, address _collateralAsset, address _targetAsset, CrossAdapter crossAdapterOracle, address newBeacon, bool newVaultCreated) public {
        if (newVaultCreated) {
            // Finish configuration of the new vault with twyneVaultManager
            bytes memory setOracleResolvedVault1Txn = abi.encodeCall(
                VaultManager.setOracleResolvedVault,
                (address(new_vault), true)
            );
            addToBatch(address(twyneVaultManager), 0, setOracleResolvedVault1Txn);

            bytes memory setIntermediateVaultTxn = abi.encodeCall(
                VaultManager.setIntermediateVault,
                (IEVault(new_vault))
            );
            addToBatch(address(twyneVaultManager), 0, setIntermediateVaultTxn);

            bytes memory setOracleResolvedVault2Txn = abi.encodeCall(
                VaultManager.setOracleResolvedVault,
                (_collateralAsset, true)
            );
            addToBatch(address(twyneVaultManager), 0, setOracleResolvedVault2Txn);

            EulerRouter eulerExternalOracle = EulerRouter(EulerRouter(IEVault(_collateralAsset).oracle()).getConfiguredOracle(IEVault(_collateralAsset).asset(), USD));
            require(keccak256(abi.encodePacked(eulerExternalOracle.name())) == keccak256(abi.encodePacked("ChainlinkOracle")) || keccak256(abi.encodePacked(eulerExternalOracle.name())) == keccak256(abi.encodePacked("CrossAdapter"))); // if oracle is not chainlink, then cool-off period is recommended

            bytes memory doCall1Txn = abi.encodeCall(
                VaultManager.doCall,
                (address(twyneVaultManager.oracleRouter()), 0, abi.encodeCall(EulerRouter.govSetConfig, (IEVault(_collateralAsset).asset(), USD, address(eulerExternalOracle))))
            );
            addToBatch(address(twyneVaultManager), 0, doCall1Txn);

            bytes memory setMaxLiquidationLTVTxn = abi.encodeCall(
                VaultManager.setMaxLiquidationLTV,
                (_collateralAsset, 0.93e4)
            );
            addToBatch(address(twyneVaultManager), 0, setMaxLiquidationLTVTxn);

            bytes memory setExternalLiqBufferTxn = abi.encodeCall(
                VaultManager.setExternalLiqBuffer,
                (_collateralAsset, 1e4)
            );
            addToBatch(address(twyneVaultManager), 0, setExternalLiqBufferTxn);
        }

        if (!twyneVaultManager.isAllowedTargetVault(address(new_vault), _targetAsset)) {
            require(IEVault(_targetAsset).LTVBorrow(new_vault.asset()) != 0, InvalidCollateral());
            bytes memory setAllowedTargetVaultTxn = abi.encodeCall(
                VaultManager.setAllowedTargetVault,
                (address(new_vault), _targetAsset)
            );
            addToBatch(address(twyneVaultManager), 0, setAllowedTargetVaultTxn);
        }

        // 3. Deploy a new EulerCollateralVault implementation for the target asset and set the beacon
        //    This assumes one beacon per target asset type.
        if (collateralVaultFactory.collateralVaultBeacon(_targetAsset) == address(0)) {
            bytes memory setBeaconTxn = abi.encodeCall(
                CollateralVaultFactory.setBeacon,
                (_targetAsset, address(newBeacon))
            );
            addToBatch(address(collateralVaultFactory), 0, setBeaconTxn);
        }

        // 4. Set up CrossAdapter for external liquidations
        address underlyingTarget = IEVault(_targetAsset).asset();
        address underlyingCollateral = IEVault(_collateralAsset).asset();

        if (oracleRouter.getConfiguredOracle(underlyingTarget, underlyingCollateral) == address(0)) {
            // Configure Twyne's oracle router to use the CrossAdapter for pricing underlyingTarget against underlyingCollateral
            bytes memory doCall2Txn = abi.encodeCall(
                VaultManager.doCall,
                (address(oracleRouter), 0, abi.encodeCall(EulerRouter.govSetConfig, (underlyingTarget, underlyingCollateral, address(crossAdapterOracle))))
            );
            addToBatch(address(twyneVaultManager), 0, doCall2Txn);
        }

        if (oracleRouter.getConfiguredOracle(underlyingTarget, USD) == address(0)) {
            // The oracle for targetAsset -> USD is on Euler's main oracle router
            address oracleBaseCross = EulerRouter(IEVault(_targetAsset).oracle()).getConfiguredOracle(underlyingTarget, USD);
            // We also need to make sure the base oracle paths are resolvable on our router for other checks
            bytes memory doCall3Txn = abi.encodeCall(
                VaultManager.doCall,
                (address(oracleRouter), 0, abi.encodeCall(EulerRouter.govSetConfig, (underlyingTarget, USD, oracleBaseCross)))
            );
            addToBatch(address(twyneVaultManager), 0, doCall3Txn);
        }
    }
}