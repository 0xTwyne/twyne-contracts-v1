// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "forge-std/Vm.sol";
import {EulerWrapper, IEVault} from "src/Periphery/EulerWrapper.sol";

/// @title TwynePeriphery
/// @notice To contact the team regarding security matters, visit https://twyne.xyz/security
contract TwynePeriphery is Script {
    address eulerUSDC;
    address eulerWETH;
    address eulerWSTETH;
    address deployer;

    error UnknownProfile();

    function run() public {
        deployer = vm.envAddress("DEPLOYER_ADDRESS");
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

        string memory json = vm.readFile("TwyneAddresses_output.json");

        address intermediateVault = address(vm.parseJsonAddress(json, ".intermediateVault"));

        vm.startBroadcast(deployer);
        EulerWrapper eulerWrapper = new EulerWrapper(IEVault(intermediateVault).EVC(), IEVault(eulerWETH).asset());
        vm.stopBroadcast();

        console2.log("eulerWrapper", address(eulerWrapper));
    }
}