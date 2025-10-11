// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "forge-std/Vm.sol";
import {ProtocolConfig} from "euler-vault-kit/ProtocolConfig/ProtocolConfig.sol";
import {GenericFactory} from "euler-vault-kit/GenericFactory/GenericFactory.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";

/// @title EulerAdminTransfer
/// @notice To contact the team regarding security matters, visit https://twyne.xyz/security
/// @dev This script is inspired from scripts 51 and 52 in the Euler Finance evk-periphery repo
contract EulerAdminTransfer is Script {
    address deployer;
    address SAFE;

    error UnknownProfile();

    function run() public {
        deployer = vm.envAddress("DEPLOYER_ADDRESS");
        SAFE = vm.envAddress("ADMIN_ETH_ADDRESS");

        if (block.chainid != 1 && block.chainid != 8453) { // mainnet
            revert UnknownProfile();
        }

        setAdminOwnership(deployer, SAFE); // sets new multisig admin owner for addresses
    }

    function setAdminOwnership(address deployerEOA, address admin) public {
        // Parse addresses
        string memory coreAddressesJson = vm.readFile("CoreAddresses_0.json");
        ProtocolConfig protocolConfig = ProtocolConfig(vm.parseJsonAddress(coreAddressesJson, ".protocolConfig"));
        GenericFactory genericFactory = GenericFactory(vm.parseJsonAddress(coreAddressesJson, ".eVaultFactory"));

        string memory peripheryAddressesJson = vm.readFile("PeripheryAddresses_0.json");
        address oracleAdapterRegistry = vm.parseJsonAddress(peripheryAddressesJson, ".oracleAdapterRegistry");
        address externalVaultRegistry = vm.parseJsonAddress(peripheryAddressesJson, ".externalVaultRegistry");
        address irmRegistry = vm.parseJsonAddress(peripheryAddressesJson, ".irmRegistry");
        address governedPerspective = vm.parseJsonAddress(peripheryAddressesJson, ".governedPerspective");

        // Log all addresses for debugging
        console2.log("protocolConfig", address(protocolConfig));
        console2.log("genericFactory", address(genericFactory));
        console2.log("oracleAdapterRegistry", oracleAdapterRegistry);
        console2.log("externalVaultRegistry", externalVaultRegistry);
        console2.log("irmRegistry", irmRegistry);
        console2.log("governedPerspective", governedPerspective);

        // Verify the starting state matches expectations
        require(protocolConfig.admin() == deployerEOA, "protocolConfig needs to have expected admin");
        require(genericFactory.upgradeAdmin() == admin, "genericFactory owner is set by TwyneAdminTransfer.s.sol");
        require(Ownable(oracleAdapterRegistry).owner() == deployerEOA, "oracleAdapterRegistry needs to have expected owner");
        require(Ownable(externalVaultRegistry).owner() == deployerEOA, "externalVaultRegistry needs to have expected owner");
        require(Ownable(irmRegistry).owner() == deployerEOA, "irmRegistry needs to have expected owner");
        require(Ownable(governedPerspective).owner() == deployerEOA, "governedPerspective needs to have expected owner");

        // Set production deployment owner, from evk-periphery script 51
        vm.startBroadcast(deployer);
        protocolConfig.setAdmin(admin);

        // Transfer ownership of periphery contracts, from evk-periphery script 52
        Ownable(oracleAdapterRegistry).transferOwnership(admin);
        Ownable(externalVaultRegistry).transferOwnership(admin);
        Ownable(irmRegistry).transferOwnership(admin);
        Ownable(governedPerspective).transferOwnership(admin);
        vm.stopBroadcast();

        // Verify the end state matches expectations
        require(protocolConfig.admin() == admin, "protocolConfig needs to be set to correct admin");
        require(genericFactory.upgradeAdmin() == admin, "genericFactory needs to be set to correct admin");
        require(Ownable(oracleAdapterRegistry).owner() == admin, "oracleAdapterRegistry needs to be set to correct owner");
        require(Ownable(externalVaultRegistry).owner() == admin, "externalVaultRegistry needs to be set to correct owner");
        require(Ownable(irmRegistry).owner() == admin, "irmRegistry needs to be set to correct owner");
        require(Ownable(governedPerspective).owner() == admin, "governedPerspective needs to be set to correct owner");
    }
}