// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {TwyneVaultTestBase, console2} from "../TwyneVaultTestBase.t.sol";
import {BridgeHookTarget} from "src/TwyneFactory/BridgeHookTarget.sol";

import "euler-vault-kit/EVault/shared/types/Types.sol";
import {ChainlinkOracle} from "euler-price-oracle/src/adapter/chainlink/ChainlinkOracle.sol";

import {BridgeHookTarget} from "src/TwyneFactory/BridgeHookTarget.sol";
import {IRMTwyneCurve} from "src/twyne/IRMTwyneCurve.sol";
import {MockPriceOracle} from "euler-vault-kit/../test/mocks/MockPriceOracle.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {HealthStatViewer} from "src/twyne/HealthStatViewer.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";


contract MainnetBase is TwyneVaultTestBase {
    ChainlinkOracle USDC_USD_oracle;
    MockPriceOracle mockOracle;
    EulerRouter eulerExternalOracle;

    error InvalidInvariant();
    error NoConfiguredOracle();
    error InvalidCollateral();

    HealthStatViewer healthViewer;

    uint256 WETH_USD_PRICE_INITIAL;
    uint256 constant USDC_USD_PRICE_INITIAL = 1e18 * 1e18 / 1e6;


    // addresses shared in every test file, set based on chainId AKA FOUNDRY_PROFILE .env variable
    // assets
    address aavePool;
    address eulerWETH;
    address eulerCBBTC;
    address eulerWSTETH;
    address eulerUSDC;
    address eulerUSDS;
    address USDC;
    address WETH;
    address WSTETH;
    address USDS;


    function _setData() internal {
        aavePool = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
        eulerWETH = 0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2;
        eulerCBBTC = 0x056f3a2E41d2778D3a0c0714439c53af2987718E;
        eulerWSTETH = 0xbC4B4AC47582c3E38Ce5940B80Da65401F4628f1;
        eulerUSDC = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
        eulerUSDS = 0x07F9A54Dc5135B9878d6745E267625BF0E206840;
        eulerOnChain = EulerRouter(0x83B3b76873D36A28440cF53371dF404c42497136);
        fixtureCollateralAssets = [eulerWETH, eulerWSTETH, eulerCBBTC];
        fixtureTargetAssets = [eulerUSDC, eulerUSDS];
        eulerSwapVerifier = 0xae26485ACDDeFd486Fe9ad7C2b34169d360737c7;
        eulerSwapper = 0x2Bba09866b6F1025258542478C39720A09B728bF;
        morpho = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    }

    function setUp() public virtual override {
        super.setUp();
        _setData();
        maxLTVInitial = 0.93e4;
        externalLiqBufferInitial = 1e4;
        USDC = IEVault(eulerUSDC).asset();
        WETH = IEVault(eulerWETH).asset();
        WSTETH = IEVault(eulerWSTETH).asset();
        USDS = IEVault(eulerUSDS).asset();

        vm.label(USDC, "USDC");
        vm.label(WETH, "WETH");
        vm.label(WSTETH, "WSTETH");
        vm.label(USDS, "USDS");

        // Create vault manager and configure
        vm.startPrank(admin);

        healthViewer = new HealthStatViewer(aavePool);

        vm.stopPrank();
        vm.label(eulerSwapper, "eulerSwapper");
        vm.label(eulerSwapVerifier, "eulerSwapVerifier");
        vm.label(morpho, "morpho");

    }
}