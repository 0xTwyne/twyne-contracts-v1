// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "forge-std/Vm.sol";
import {EulerWrapper, IEVault} from "src/Periphery/EulerWrapper.sol";

/// @title TwynePeriphery
/// @notice To contact the team regarding security matters, visit https://twyne.xyz/security
contract TwynePeriphery is Script {
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
        deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

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

        string memory json = vm.readFile("TwyneAddresses_output.json");
        bytes memory data = vm.parseJson(json);
        TwyneAddresses memory twyneAddresses = abi.decode(data, (TwyneAddresses));

        vm.startBroadcast(deployerKey);
        EulerWrapper eulerWrapper = new EulerWrapper(IEVault(twyneAddresses.intermediateVault).EVC(), IEVault(eulerWETH).asset());
        vm.stopBroadcast();

        console2.log("eulerWrapper", address(eulerWrapper));
    }
}