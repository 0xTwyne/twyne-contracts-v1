// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "forge-std/Vm.sol";
import {BatchScript} from "forge-safe/src/BatchScript.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {EVault} from "euler-vault-kit/EVault/EVault.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {Vault} from "euler-vault-kit/EVault/modules/Vault.sol";
import {Base} from "euler-vault-kit/EVault/shared/Base.sol";
import {EulerCollateralVault} from "src/twyne/EulerCollateralVault.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @title TwyneUpgradeBeacon
/// @notice To contact the team regarding security matters, visit https://twyne.xyz/security
contract TwyneUpgradeBeacon is BatchScript {
    address SAFE = 0x8f822A1b550733822bCD4681B44373552c46f940; // set SAFE address
    uint PHASE = 10; // this will revert, intentionally set this way to make the deployer explicitly set this value

    // set asset addresses
    address eulerUSDC;
    address eulerWETH;
    address eulerWSTETH;
    address eulerUSDS;

    address newCollateralVaultImpl;
    address exampleCollateralVault;
    address evc;

    CollateralVaultFactory collateralVaultFactory;

    uint256 deployerKey;

    error UnknownProfile();

    function run() public isBatch(SAFE) {
        if (block.chainid == 1) { // mainnet
            eulerUSDC = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
            eulerWETH = 0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2;
            eulerWSTETH = 0xbC4B4AC47582c3E38Ce5940B80Da65401F4628f1;
            eulerUSDS = 0x07F9A54Dc5135B9878d6745E267625BF0E206840;
        } else if (block.chainid == 8453) { // base
            eulerUSDC = 0x0A1a3b5f2041F33522C4efc754a7D096f880eE16;
            eulerWETH = 0x859160DB5841E5cfB8D3f144C6b3381A85A4b410;
            eulerWSTETH = 0x7b181d6509DEabfbd1A23aF1E65fD46E89572609;
            eulerUSDS = 0x556d518FDFDCC4027A3A1388699c5E11AC201D8b;
        } else {
            revert UnknownProfile();
        }

        require (PHASE <= 1, "PHASE not set correctly");

        vm.label(eulerWETH, "eulerWETH");
        vm.label(eulerUSDC, "eulerUSDC");
        vm.label(eulerWSTETH, "eulerWSTETH");
        deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        loadTwyneAddresses();

        console2.log("block.chainid", uint(block.chainid));

        if (PHASE == 0) {
            phase0();
        } else if (PHASE == 1) {
            phase1();
        } else {
            revert("PHASE not set correctly");
        }

        executeBatch(PHASE == 1);
    }

    function loadTwyneAddresses() internal {
        string memory twyneAddressesJson = vm.readFile("./TwyneAddresses_output.json");
        collateralVaultFactory = CollateralVaultFactory(vm.parseJsonAddress(twyneAddressesJson, ".collateralVaultFactory"));
        exampleCollateralVault = vm.parseJsonAddress(twyneAddressesJson, ".deployerExampleCollateralVault");
        evc = payable(collateralVaultFactory.EVC());
    }

    function phase0() internal {
        vm.startBroadcast(deployerKey);

        // Prepare the set of Euler target vaults we maintain beacons for on this chain
        address[] memory eulerTargets = new address[](4);
        eulerTargets[0] = eulerUSDC;
        eulerTargets[1] = eulerWETH;
        eulerTargets[2] = eulerWSTETH;
        eulerTargets[3] = eulerUSDS;

        // Accumulate JSON of findings and deployments
        string memory deploymentJson = "deployment";
        string memory finalJson;

        for (uint256 i = 0; i < eulerTargets.length; i++) {
            address targetVault = eulerTargets[i];
            if (targetVault == address(0)) continue;

            address beacon = collateralVaultFactory.collateralVaultBeacon(targetVault);
            vm.label(beacon, string.concat("beacon_", vm.toString(targetVault)));


            if (beacon == address(0)) {
                console2.log("No beacon set for targetVault, skipping:", targetVault);
                continue;
            }

            address currentImpl = UpgradeableBeacon(beacon).implementation();
            vm.label(currentImpl, string.concat("currentCollateralVaultImpl_", vm.toString(targetVault)));
            console2.log("current impl for targetVault", targetVault, currentImpl);

            uint256 implVersion = EulerCollateralVault(currentImpl).version();
            console2.log("current impl version", implVersion);

            if (implVersion == 0) {
                // Deploy new implementation specific to this target vault
                address newImpl = address(new EulerCollateralVault(evc, targetVault));
                vm.label(newImpl, string.concat("newCollateralVaultImpl_", vm.toString(targetVault)));
                console2.log("deployed new impl for targetVault", targetVault, newImpl);

                // Sanity: ensure version incremented
                uint256 newVersion = EulerCollateralVault(newImpl).version();
                require(newVersion == 1, "New impl must be v1");

                // Record deployment
                finalJson = vm.serializeAddress(
                    deploymentJson,
                    string.concat("newImpl_", vm.toString(targetVault)),
                    newImpl
                );
            } else {
                // If not 0, it must be 1 per upgrade plan
                require(implVersion == 1, "Unexpected impl version (must be 0 or 1)");
            }
        }

        vm.stopBroadcast();

        string memory fileName = string.concat("UpgradeBeaconPhase0_", vm.toString(block.chainid), ".json");
        vm.writeJson(finalJson, fileName);
        console2.log("Deployment data serialized to:", fileName);
    }

    function phase1() public {
        string memory fileName = string.concat("UpgradeBeaconPhase0_", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(fileName);

        // Prepare the set of Euler target vaults we maintain beacons for on this chain
        address[] memory eulerTargets = new address[](4);
        eulerTargets[0] = eulerUSDC;
        eulerTargets[1] = eulerWETH;
        eulerTargets[2] = eulerWSTETH;
        eulerTargets[3] = eulerUSDS;

        for (uint256 i = 0; i < eulerTargets.length; i++) {
            address targetVault = eulerTargets[i];
            if (targetVault == address(0)) continue;

            address beacon = collateralVaultFactory.collateralVaultBeacon(targetVault);
            if (beacon == address(0)) {
                console2.log("No beacon set for targetVault, skipping:", targetVault);
                continue;
            }

            address currentImpl = UpgradeableBeacon(beacon).implementation();
            uint256 implVersion = EulerCollateralVault(currentImpl).version();

            if (implVersion == 0) {
                // Read deployed impl from Phase 0 output and upgrade beacon
                string memory key = string.concat(".newImpl_", vm.toString(targetVault));
                address deployedNewImpl = vm.parseJsonAddress(json, key);
                require(deployedNewImpl != address(0), "Missing newImpl in phase0 json");

                bytes memory updateBeaconTxn = abi.encodeCall(
                    UpgradeableBeacon.upgradeTo, (deployedNewImpl)
                );

                addToBatch(beacon, updateBeaconTxn);
                console2.log("queued upgradeTo for targetVault", targetVault, "->", deployedNewImpl);
            } else {
                // If not 0, it must be 1 per upgrade plan
                require(implVersion == 1, "Unexpected impl version (must be 0 or 1)");
            }
        }
    }

}