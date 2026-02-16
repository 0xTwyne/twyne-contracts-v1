// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import { TwyneVaultTestBase, console2 } from "../TwyneVaultTestBase.t.sol";
import {BridgeHookTarget} from "src/TwyneFactory/BridgeHookTarget.sol";

import {GenericFactory} from "euler-vault-kit/GenericFactory/GenericFactory.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";

import {EVault} from "euler-vault-kit/EVault/EVault.sol";

import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";


import {TestERC20} from "euler-vault-kit/../test/mocks/TestERC20.sol";
import {MockBalanceTracker} from "euler-vault-kit/../test/mocks/MockBalanceTracker.sol";
import {MockPriceOracle} from "euler-vault-kit/../test/mocks/MockPriceOracle.sol";
import {IRMTestDefault} from "euler-vault-kit/../test/mocks/IRMTestDefault.sol";
import {IHookTarget} from "euler-vault-kit/interfaces/IHookTarget.sol";

import "euler-vault-kit/EVault/shared/Constants.sol";

import {ChainlinkOracle} from "euler-price-oracle/src/adapter/chainlink/ChainlinkOracle.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {HealthStatViewer} from "src/twyne/HealthStatViewer.sol";
import {EulerWrapper} from "src/Periphery/EulerWrapper.sol";
import {LeverageOperator} from "src/operators/LeverageOperator.sol";
import {DeleverageOperator} from "src/operators/DeleverageOperator.sol";
import {IRMTwyneCurve} from "src/twyne/IRMTwyneCurve.sol";

import {LeverageOperator} from "src/operators/LeverageOperator.sol";
import {DeleverageOperator} from "src/operators/DeleverageOperator.sol";
import {LeverageOperator_EulerFL} from "src/operators/LeverageOperator_EulerFL.sol";
import {DeleverageOperator_EulerFL} from "src/operators/DeleverageOperator_EulerFL.sol";


//
contract PlasmaBase is TwyneVaultTestBase {

    ChainlinkOracle USDC_USD_oracle;
    MockPriceOracle mockOracle;
    EulerRouter eulerExternalOracle;

    error InvalidInvariant();
    error NoConfiguredOracle();
    error InvalidCollateral();

    HealthStatViewer healthViewer;
    LeverageOperator leverageOperator;
    DeleverageOperator deleverageOperator;
    LeverageOperator_EulerFL leverageOperator_EulerFL;
    DeleverageOperator_EulerFL deleverageOperator_EulerFL;

    uint256 WETH_USD_PRICE_INITIAL;
    uint256 constant USDC_USD_PRICE_INITIAL = 1e18 * 1e18 / 1e6;

    address aavePool;
    address eulerYzPP;
    address eulerUSDT;
    address USDT;
    address YzPP;

    ChainlinkOracle USDT_USD_oracle;

    uint256 YzPP_USD_PRICE_INITIAL;
    uint256 constant USDT_USD_PRICE_INITIAL = 1e18 * 1e18 / 1e6;

    function _setData() internal {
        aavePool = 0x925a2A7214Ed92428B5b1B090F80b25700095e12;
        eulerYzPP = 0xfc5c4e5593A352CEDc9E5D7fD4e21b321140c345;
        eulerUSDT = 0xFE8d21E64e0c6CFb9abF224e805452acdE8e91Fa;
        eulerOnChain = EulerRouter(0x41BEE60835C2D9bc85aD12391f29e6269dA39Fb7);
        fixtureCollateralAssets = [eulerYzPP];
        fixtureTargetAssets = [eulerUSDT];
        eulerSwapVerifier = 0xae26485ACDDeFd486Fe9ad7C2b34169d360737c7;
        eulerSwapper = 0x2Bba09866b6F1025258542478C39720A09B728bF;
        morpho = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    }

    function setUp() public virtual override {
        super.setUp();
        _setData();

        USDT = IEVault(eulerUSDT).asset();
        YzPP = IEVault(eulerYzPP).asset();


        vm.label(USDT, "USDT");
        vm.label(YzPP, "YzPP");




        // Create vault manager and configure
        vm.startPrank(admin);

        healthViewer = new HealthStatViewer(aavePool);

        // Deploy LeverageOperator
        leverageOperator = new LeverageOperator(
            address(evc),
            eulerSwapper,
            eulerSwapVerifier,
            morpho,
            address(collateralVaultFactory)
        );

        // Deploy DeleverageOperator
        deleverageOperator = new DeleverageOperator(
            address(evc),
            eulerSwapper,
            morpho,
            address(collateralVaultFactory)
        );

        // Add labels for new addresses
        vm.label(address(leverageOperator), "leverageOperator");
        vm.label(address(deleverageOperator), "deleverageOperator");
        vm.label(eulerSwapper, "eulerSwapper");
        vm.label(eulerSwapVerifier, "eulerSwapVerifier");
        vm.label(morpho, "morpho");



        vm.stopPrank();


        // Create and test oracle types
        // Create mock oracle for WETH-eWETH 1-to-1 conversion
        mockOracle = new MockPriceOracle();

        vm.startPrank(admin);

        maxLTVInitial = 0.93e4;
        externalLiqBufferInitial = 1e4;
        require(twyneLiqLTV <= maxLTVInitial, "twyneLiqLTV is not set properly");


    }

}


