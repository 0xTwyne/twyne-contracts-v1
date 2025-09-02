// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "forge-std/Vm.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {GenericFactory} from "euler-vault-kit/GenericFactory/GenericFactory.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @title TwyneAdminTransfer
/// @notice To contact the team regarding security matters, visit https://twyne.xyz/security
contract TwyneAdminTransfer is Script {
    address deployer;
    uint256 deployerKey;
    address eulerUSDC;
    address eulerWETH;
    address eulerWSTETH;

    error UnknownProfile();

    struct TwyneAddresses {
        address genericFactory;
        address liqBot;
        address collateralVaultFactory;
        address deployerExampleCollateralVault;
        address healthStatViewer;
        address intermediateVault;
        address oracleRouter;
        address vaultManager;
    }

    function run() public {
        // These two values should be properly set before running
        deployer = vm.envAddress("DEPLOYER_ADDRESS");
        deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address newMultisigOwner = 0x8f822A1b550733822bCD4681B44373552c46f940;

        if (block.chainid == 1) { // mainnet
            eulerUSDC = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
            eulerWETH = 0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2;
            eulerWSTETH = 0xbC4B4AC47582c3E38Ce5940B80Da65401F4628f1;
        } else if (block.chainid == 8453) { // base
            eulerUSDC = 0x0A1a3b5f2041F33522C4efc754a7D096f880eE16;
            eulerWETH = 0x859160DB5841E5cfB8D3f144C6b3381A85A4b410;
            eulerWSTETH = 0x7b181d6509DEabfbd1A23aF1E65fD46E89572609;
        } else if (block.chainid == 146) { // sonic
            eulerUSDC = 0x196F3C7443E940911EE2Bb88e019Fd71400349D9;
            eulerWETH = 0xa5cd24d9792F4F131f5976Af935A505D19c8Db2b;
            eulerWSTETH = 0x05d57366B862022F76Fe93316e81E9f24218bBfC;
        } else {
            revert UnknownProfile();
        }

        setAdminOwnership(deployer, newMultisigOwner); // sets new multisig admin owner for addresses
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
        vm.startBroadcast(deployerKey);
        factory.setUpgradeAdmin(admin);
        collateralVaultFactory.transferOwnership(admin);
        vaultManager.transferOwnership(admin);
        address beaconAddr = collateralVaultFactory.collateralVaultBeacon(eulerUSDC);
        UpgradeableBeacon(beaconAddr).transferOwnership(admin);
        vaultManager.doCall(address(intermediateVault), 0, abi.encodeCall(intermediateVault.setFeeReceiver, admin));
        vm.stopBroadcast();

        // Verify the end state matches expectations
        require(factory.upgradeAdmin() == admin, "factory needs to be set to correct admin");
        require(collateralVaultFactory.owner() == admin, "collateralVaultFactory needs to be set to correct admin");
        require(oracleRouter.governor() == address(vaultManager), "oracleRouter needs to be set to correct admin");
        require(vaultManager.owner() == admin, "vaultManager needs to be set to correct admin");
        require(intermediateVault.feeReceiver() == admin, "intermediateVault needs to be set to correct admin");
    }
}