// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import {BatchScript} from "forge-safe/src/BatchScript.sol";
import {IRMTwyneCurve} from "src/twyne/IRMTwyneCurve.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";

/// @title ParamChangeScript
/// @notice To contact the team regarding security matters, visit https://twyne.xyz/security
/// @dev This script changes max liquidation LTV and updates IRM curve for an intermediate vault
contract ParamChangeScript is BatchScript {
    VaultManager twyneVaultManager;
    address intermediateVault;
    address SAFE;

    address eulerWETH;
    address eulerUSDC;
    address eulerBTC;
    address eulerwstETH;
    address eulerUSDS;
    address eulerUSDT;

    error UnknownProfile();

    function run() public {
        if (block.chainid == 1) {
            eulerWETH = 0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2;
            eulerUSDC = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
            eulerBTC = 0x998D761eC1BAdaCeb064624cc3A1d37A46C88bA4;
            eulerwstETH = 0xbC4B4AC47582c3E38Ce5940B80Da65401F4628f1;
            eulerUSDS = 0x07F9A54Dc5135B9878d6745E267625BF0E206840;
            eulerUSDT = 0x313603FA690301b0CaeEf8069c065862f9162162;
        } else if (block.chainid == 8453) {
            eulerWETH = 0x859160DB5841E5cfB8D3f144C6b3381A85A4b410;
            eulerUSDC = 0x0A1a3b5f2041F33522C4efc754a7D096f880eE16;
            eulerBTC = 0x882018411Bc4A020A879CEE183441fC9fa5D7f8B;
            eulerwstETH = 0x7b181d6509DEabfbd1A23aF1E65fD46E89572609;
            eulerUSDS = 0x556d518FDFDCC4027A3A1388699c5E11AC201D8b;
            eulerUSDT = 0x313603FA690301b0CaeEf8069c065862f9162162; // No USDT support on Base
        } else {
            revert UnknownProfile();
        }

        SAFE = vm.envAddress("ADMIN_ETH_ADDRESS");

        string memory twyneAddressesJson = vm.readFile("./TwyneAddresses_output.json");
        twyneVaultManager = VaultManager(payable(vm.parseJsonAddress(twyneAddressesJson, ".vaultManager")));
        intermediateVault = vm.parseJsonAddress(twyneAddressesJson, ".intermediateVault");

        addParameterChanges();

        executeBatch(true);
    }

    function addParameterChanges() internal isBatch(SAFE) {
        // TODO Change max liquidation LTV
        // TODO Specify which collateral asset this applies to
        address collateralAsset = eulerWETH;

        bytes memory setMaxLiquidationLTVTxn = abi.encodeCall(
            VaultManager.setMaxLiquidationLTV,
            (collateralAsset, 0.96e4) // 96%
        );
        addToBatch(address(twyneVaultManager), 0, setMaxLiquidationLTVTxn);

        // TODO Update IRM curve of intermediate vault
        IRMTwyneCurve newIRM = new IRMTwyneCurve({
            idealKinkInterestRate_: 2e3, // 20%
            linearKinkUtilizationRate_: 9e3, // 90%
            maxInterestRate_: 3e4, // 300%
            nonlinearPoint_: 5e17 // 50%
        });

        bytes memory setInterestRateModelTxn = abi.encodeCall(
            VaultManager.doCall,
            (intermediateVault, 0, abi.encodeCall(IEVault(intermediateVault).setInterestRateModel, (address(newIRM))))
        );
        addToBatch(address(twyneVaultManager), 0, setInterestRateModelTxn);
    }
}