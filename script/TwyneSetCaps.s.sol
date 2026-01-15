// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "forge-std/Vm.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {EVault} from "euler-vault-kit/EVault/EVault.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {Vault} from "euler-vault-kit/EVault/modules/Vault.sol";
import {Base} from "euler-vault-kit/EVault/shared/Base.sol";
import {IEVault, IGovernance} from "euler-vault-kit/EVault/IEVault.sol";

/// @title TwyneSetCaps
/// @notice To contact the team regarding security matters, visit https://twyne.xyz/security
contract TwyneSetCaps is Script {
    // set asset addresses
    address eulerUSDC;
    address eulerWETH;
    address eulerWSTETH;

    address intermediateVault;
    EthereumVaultConnector evc;
    address vaultManager;

    // New supply caps
    uint16 limit1000 = 25617; // 0.4 ETH
    bytes data1000 = hex"d87f780f00000000000000000000000000000000000000000000000000000000000064110000000000000000000000000000000000000000000000000000000000006411"; // cast calldata "setCaps(uint16,uint16)()" 25617 25617
    bytes newNumber = bytes(abi.encodeWithSelector(IGovernance.setCaps.selector, limit1000, limit1000));
    // require(newNumber != data1000, "not equal");
    // console2.log(test1);
    uint16 limit100k = 25619; // 40 ETH
    bytes data100k = hex"d87f780f00000000000000000000000000000000000000000000000000000000000064130000000000000000000000000000000000000000000000000000000000006413"; // cast calldata "setCaps(uint16,uint16)()" 25619 25619
    uint16 limit500k = 12820; // 200 ETH
    bytes data500k = hex"d87f780f00000000000000000000000000000000000000000000000000000000000032140000000000000000000000000000000000000000000000000000000000003214"; // cast calldata "setCaps(uint16,uint16)()" 12820 12820

    address deployer;
    address admin;

    error UnknownProfile();

    function run() public {
        if (block.chainid == 1) { // mainnet
            eulerUSDC = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
            eulerWETH = 0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2;
            eulerWSTETH = 0xbC4B4AC47582c3E38Ce5940B80Da65401F4628f1;
        } else if (block.chainid == 8453) { // base
            eulerUSDC = 0x0A1a3b5f2041F33522C4efc754a7D096f880eE16;
            eulerWETH = 0x859160DB5841E5cfB8D3f144C6b3381A85A4b410;
            eulerWSTETH = 0x7b181d6509DEabfbd1A23aF1E65fD46E89572609;
        } else {
            revert UnknownProfile();
        }

        vm.label(eulerWETH, "eulerWETH");
        vm.label(eulerUSDC, "eulerUSDC");
        vm.label(eulerWSTETH, "eulerWSTETH");
        admin = vm.envAddress("ADMIN_ETH_ADDRESS");
        deployer = vm.envAddress("DEPLOYER_ADDRESS");

        productionSetup(); // sets up on-chain EVK deployment addresses from evk-periphery script
        updateBeacon();
    }

    function productionSetup() public {
        string memory json = vm.readFile("TwyneAddresses_output.json");
        intermediateVault = address(vm.parseJsonAddress(json, ".intermediateVault"));
        vaultManager = address(vm.parseJsonAddress(json, ".vaultManager"));

    }

    function updateBeacon() public {
        vm.startBroadcast(deployer);

        console2.log("block.chainid", uint(block.chainid));

        // Log the caps before
        (uint16 supplyCapBefore, uint16 borrowCapBefore) = IEVault(intermediateVault).caps();
        console2.log("supply cap before", supplyCapBefore);
        console2.log("borrow cap before", borrowCapBefore);

        VaultManager(payable(vaultManager)).doCall(intermediateVault, 0, data100k);

        // Log the caps after
        (uint16 supplyCapAfter, uint16 borrowCapAfter) = IEVault(intermediateVault).caps();
        console2.log("supply cap after", supplyCapAfter);
        console2.log("borrow cap after", borrowCapAfter);
        require(supplyCapBefore != supplyCapAfter, "Supply cap unchanged");
        require(borrowCapBefore != borrowCapAfter, "Borrow cap unchanged");
    }

}