// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {GenericFactory} from "euler-vault-kit/GenericFactory/GenericFactory.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {EVault} from "euler-vault-kit/EVault/EVault.sol";
import {ProtocolConfig} from "euler-vault-kit/ProtocolConfig/ProtocolConfig.sol";
import {Dispatch} from "euler-vault-kit/EVault/Dispatch.sol";
import {Base} from "euler-vault-kit/EVault/shared/Base.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {MockPriceOracle} from "euler-vault-kit/../test/mocks/MockPriceOracle.sol";
import {SequenceRegistry} from "euler-vault-kit/SequenceRegistry/SequenceRegistry.sol";
import "euler-vault-kit/EVault/shared/Constants.sol";

import {VaultManager} from "src/twyne/VaultManager.sol";

abstract contract TwyneStorage {
    EthereumVaultConnector public evc;
    address admin;
    address feeReceiver;
    address protocolFeeReceiver;
    ProtocolConfig protocolConfig;
    address balanceTracker;
    MockPriceOracle oracle;
    address unitOfAccount;
    address permit2;
    address sequenceRegistry;
    GenericFactory public factory;
    CollateralVaultFactory public collateralVaultFactory;

    Base.Integrations integrations;
    Dispatch.DeployedModules modules;

    address initializeModule;
    address tokenModule;
    address vaultModule;
    address borrowingModule;
    address liquidationModule;
    address riskManagerModule;
    address balanceForwarderModule;
    address governanceModule;

    address eulerSwapVerifier;
    address eulerSwapper;
    address morpho;
    address constant USD = address(840);
    uint256 ethPrice;
    EulerRouter eulerOnChain;
    uint forkBlockDiff;

    EulerRouter oracleRouter;
    VaultManager twyneVaultManager;

    address[] public fixtureCollateralAssets;
    address[] public fixtureTargetAssets;

    uint forkBlock;

    error UnknownProfile();


    uint256 aliceKey; // Alice needs a private key for permit2 signing
    address alice;
    uint bobKey;
    address bob; // benevolent bob, supplies intermediate asset
    address eve; // evil eve, blackhat and uses Twyne in ways we don't want
    address liquidator; // liquidator of unhealthy positions
    address teleporter;


    uint16 maxLTVInitial;
    uint16 externalLiqBufferInitial;
    uint16 twyneLiqLTV = 0.9e4;
    uint constant MAXFACTOR = 1e4;
    uint256 constant INITIAL_DEALT_ERC20 = 100 ether;
    uint256 INITIAL_DEALT_ETOKEN = 20 ether;
    uint256 CREDIT_LP_AMOUNT = 8 ether;
    uint256 COLLATERAL_AMOUNT = 5 ether;
    uint256 BORROW_USD_AMOUNT;


}