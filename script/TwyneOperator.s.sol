// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "forge-std/Vm.sol";
import {LeverageOperator} from "src/operators/LeverageOperator.sol";
import {DeleverageOperator} from "src/operators/DeleverageOperator.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";

/// @title TwyneOperator
/// @notice To contact the team regarding security matters, visit https://twyne.xyz/security
contract TwyneOperator is Script {
    address deployer;
    address eulerSwapVerifier;
    address eulerSwapper;
    address morpho;

    error UnknownProfile();

    function run() public {
        deployer = vm.envAddress("DEPLOYER_ADDRESS");

        if (block.chainid == 1) { // mainnet
            eulerSwapVerifier = 0xae26485ACDDeFd486Fe9ad7C2b34169d360737c7;
            eulerSwapper = 0x2Bba09866b6F1025258542478C39720A09B728bF;
            morpho = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
        } else if (block.chainid == 8453) { // base
            eulerSwapVerifier = 0x30660764A7a05B84608812C8AFC0Cb4845439EEe;
            eulerSwapper = 0x0D3d0F97eD816Ca3350D627AD8e57B6AD41774df;
            morpho = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
        } else {
            revert UnknownProfile();
        }

        string memory json = vm.readFile("TwyneAddresses_output.json");
        address intermediateVault = address(vm.parseJsonAddress(json, ".intermediateVault"));
        address collateralVaultFactory = address(vm.parseJsonAddress(json, ".collateralVaultFactory"));

        // deploy LeverageOperator and DeleverageOperator
        vm.startBroadcast(deployer);

        LeverageOperator levOp = new LeverageOperator(
            IEVault(intermediateVault).EVC(),
            eulerSwapper,
            eulerSwapVerifier,
            morpho,
            collateralVaultFactory
        );

        DeleverageOperator delevOp = new DeleverageOperator(
            IEVault(intermediateVault).EVC(),
            eulerSwapper,
            morpho,
            collateralVaultFactory
        );

        vm.stopBroadcast();

        console2.log("leverageOperator", address(levOp));
        console2.log("deleverageOperator", address(delevOp));
    }
}