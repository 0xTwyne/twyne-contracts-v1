// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {EulerTestBase} from "./EulerTestBase.t.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {CrossAdapter} from "euler-price-oracle/src/adapter/CrossAdapter.sol";
import {EulerCollateralVault} from "src/twyne/EulerCollateralVault.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";
import {console2} from "forge-std/Test.sol";

contract EulerTestNormalActions is EulerTestBase {
    function setUp() public virtual override {
        super.setUp();
    }

    // This test simulates the TwyneAddVaultPair script to add a new asset pair
    function e_addNewPair(address _collateralAsset, address _targetAsset) public noGasMetering {
        e_creditDeposit(eulerWETH);

        // start deployment as twyneVaultManager (multisig)
        vm.startPrank(twyneVaultManager.owner());

        IEVault new_intermediate_vault;
        // 1. Deploy new intermediate vault for the collateral asset
        // if intermediate vault already exists
        try twyneVaultManager.getIntermediateVault(_collateralAsset) returns (address vault) {
            new_intermediate_vault = IEVault(vault);
        // if revert encountered because the vault does not exist, create new intermediate vault
        } catch {
            new_intermediate_vault = newIntermediateVault(_collateralAsset, address(oracleRouter), USD);
        }

        // 4. Set up CrossAdapter for external liquidations
        address underlyingTarget = IEVault(_targetAsset).asset();
        address underlyingCollateral = IEVault(_collateralAsset).asset();

        // The oracle for targetAsset -> USD is on Euler's main oracle router
        address oracleBaseCross = EulerRouter(IEVault(_targetAsset).oracle()).getConfiguredOracle(underlyingTarget, USD);

        // The oracle for collateralAsset -> USD is on our Twyne oracle router
        address oracleCrossQuote = EulerRouter(IEVault(_targetAsset).oracle()).getConfiguredOracle(underlyingCollateral, USD);

        CrossAdapter crossAdapterOracle = new CrossAdapter(underlyingTarget, USD, underlyingCollateral, oracleBaseCross, oracleCrossQuote);

        // Finish configuration of the new vault with twyneVaultManager
        twyneVaultManager.setOracleResolvedVault(address(new_intermediate_vault), true);
        twyneVaultManager.setOracleResolvedVault(_collateralAsset, true); // need to set this for recursive resolveOracle() lookup
        eulerExternalOracle = EulerRouter(EulerRouter(IEVault(_collateralAsset).oracle()).getConfiguredOracle(IEVault(_collateralAsset).asset(), USD));
        twyneVaultManager.doCall(address(twyneVaultManager.oracleRouter()), 0, abi.encodeCall(EulerRouter.govSetConfig, (IEVault(_collateralAsset).asset(), USD, address(eulerExternalOracle))));
        // twyneVaultManager.setIntermediateVault(IEVault(new_intermediate_vault)); // already done in newIntermediateVault()

        // 2. Configure twyneVaultManager for the new pair
        twyneVaultManager.setMaxLiquidationLTV(_collateralAsset, 0.93e4); // 93%
        twyneVaultManager.setExternalLiqBuffer(_collateralAsset, 1e4); // 1%
        twyneVaultManager.setAllowedTargetVault(address(new_intermediate_vault), _targetAsset);

        // 3. Deploy a new EulerCollateralVault implementation for the target asset and set the beacon
        //    This assumes one beacon per target asset type.
        address eulerCollateralVaultImpl = address(new EulerCollateralVault(address(evc), _targetAsset));
        collateralVaultFactory.setBeacon(_targetAsset, address(new UpgradeableBeacon(eulerCollateralVaultImpl, twyneVaultManager.owner())));

        // 4. Set up CrossAdapter for external liquidations
        // Configure Twyne's oracle router to use the CrossAdapter for pricing underlyingTarget against underlyingCollateral
        twyneVaultManager.doCall(address(oracleRouter), 0, abi.encodeCall(EulerRouter.govSetConfig, (underlyingTarget, underlyingCollateral, address(crossAdapterOracle))));

        // We also need to make sure the base oracle paths are resolvable on our router for other checks
        twyneVaultManager.doCall(address(oracleRouter), 0, abi.encodeCall(EulerRouter.govSetConfig, (underlyingTarget, USD, oracleBaseCross)));

        // 5. Optionally, deploy an example collateral vault
        EulerCollateralVault(
            collateralVaultFactory.createCollateralVault(
                _collateralAsset,
                _targetAsset,
                twyneLiqLTV
            )
        );
        vm.stopPrank();
    }

    function test_e_addNewPair() public noGasMetering {
        address collateralAsset = eulerUSDC;
        address targetAsset = eulerWETH;
        e_addNewPair(collateralAsset, targetAsset);

        // Add assertions to verify the necessary oracle paths are properly setup
        require(twyneVaultManager.oracleRouter().getQuote(1e16, collateralAsset, USD) != 0, "bad setup for collateral asset oracle"); // eWETH -> USD
        require(twyneVaultManager.oracleRouter().getQuote(1e16, IEVault(collateralAsset).asset(), IEVault(collateralAsset).unitOfAccount()) != 0, "bad setup for collateral asset underlying oracle"); // USDC -> WETH
        require(twyneVaultManager.oracleRouter().getQuote(1e16, IEVault(targetAsset).asset(), USD) != 0, "bad setup for target asset accounting oracle"); // WETH -> USD
        require(twyneVaultManager.oracleRouter().getQuote(1e16, IEVault(targetAsset).asset(), IEVault(collateralAsset).asset()) != 0, "bad setup for target asset oracle"); // WETH -> USDC
        require(twyneVaultManager.getIntermediateVault(collateralAsset) != address(0), "intermediate vault not properly created");
    }

    function test_e_deleteAssetPair() public noGasMetering {

    }
}
