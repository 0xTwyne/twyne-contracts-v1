// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "forge-std/Vm.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {ProtocolConfig} from "euler-vault-kit/ProtocolConfig/ProtocolConfig.sol";
import {GenericFactory} from "euler-vault-kit/GenericFactory/GenericFactory.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @title TwyneAdminTransfer
/// @notice To contact the team regarding security matters, visit https://twyne.xyz/security
contract TwyneAdminTransfer is Script {
    address deployer;
    address eulerUSDC;
    address eulerWETH;
    address SAFE;

    error UnknownProfile();

    // Assumption is that this is run immediately after the deployment script
    // AND that the deployment script only deployed an eWETH collateral asset and USDC target asset pair
    function run() public {
        deployer = vm.envAddress("DEPLOYER_ADDRESS"); // set deployer EOA address
        SAFE = vm.envAddress("ADMIN_ETH_ADDRESS");

        if (block.chainid == 1) { // mainnet
            eulerUSDC = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
            eulerWETH = 0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2;
        } else if (block.chainid == 8453) { // base
            eulerUSDC = 0x0A1a3b5f2041F33522C4efc754a7D096f880eE16;
            eulerWETH = 0x859160DB5841E5cfB8D3f144C6b3381A85A4b410;
        } else {
            revert UnknownProfile();
        }

        setAdminOwnership(deployer, SAFE); // sets new multisig admin owner for addresses
    }

    function setAdminOwnership(address deployerEOA, address admin) public {
        // Parse addresses
        string memory twyneAddressesJson = vm.readFile("TwyneAddresses_output.json");
        CollateralVaultFactory collateralVaultFactory = CollateralVaultFactory(vm.parseJsonAddress(twyneAddressesJson, ".collateralVaultFactory"));
        VaultManager vaultManager = VaultManager(payable(vm.parseJsonAddress(twyneAddressesJson, ".vaultManager")));
        EulerRouter oracleRouter = EulerRouter(vm.parseJsonAddress(twyneAddressesJson, ".oracleRouter"));
        GenericFactory factory = GenericFactory(vm.parseJsonAddress(twyneAddressesJson, ".GenericFactory"));
        IEVault intermediateVault = IEVault(vm.parseJsonAddress(twyneAddressesJson, ".intermediateVault"));

        // Log all addresses for debugging (the ordering approach for these is unclear)
        console2.log("factory", address(factory));
        console2.log("collateralVaultFactory", address(collateralVaultFactory));
        console2.log("oracleRouter", address(oracleRouter));
        console2.log("vaultManager", address(vaultManager));

        // Verify the starting state matches expectations
        require(factory.upgradeAdmin() == deployerEOA, "factory needs to have expected admin");
        require(collateralVaultFactory.owner() == deployerEOA, "collateralVaultFactory needs to have expected admin");
        require(oracleRouter.governor() == address(vaultManager), "oracleRouter needs to have expected admin");
        require(vaultManager.owner() == deployerEOA, "vaultManager needs to have expected admin");

        // Set production deployment owner
        vm.startBroadcast(deployer);
        factory.setUpgradeAdmin(admin);
        collateralVaultFactory.transferOwnership(admin);
        vaultManager.doCall(address(intermediateVault), 0, abi.encodeCall(intermediateVault.setFeeReceiver, admin));

        ProtocolConfig protocolConfig = ProtocolConfig(IEVault(intermediateVault).protocolConfigAddress());
        protocolConfig.setFeeReceiver(admin);
        vaultManager.transferOwnership(admin);
        address beaconAddr = collateralVaultFactory.collateralVaultBeacon(eulerUSDC);
        UpgradeableBeacon(beaconAddr).transferOwnership(admin);
        vm.stopBroadcast();

        // Verify the end state matches expectations
        require(factory.upgradeAdmin() == admin, "factory needs to be set to correct admin");
        require(collateralVaultFactory.owner() == admin, "collateralVaultFactory needs to be set to correct admin");
        require(oracleRouter.governor() == address(vaultManager), "oracleRouter needs to be set to correct admin");
        require(vaultManager.owner() == admin, "vaultManager needs to be set to correct admin");
        require(intermediateVault.feeReceiver() == admin, "intermediateVault needs to be set to correct admin");
    }
}