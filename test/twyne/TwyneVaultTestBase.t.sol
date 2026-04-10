// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";

import {GenericFactory} from "euler-vault-kit/GenericFactory/GenericFactory.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";
import {EVault} from "euler-vault-kit/EVault/EVault.sol";
import {ProtocolConfig} from "euler-vault-kit/ProtocolConfig/ProtocolConfig.sol";
import {Dispatch} from "euler-vault-kit/EVault/Dispatch.sol";
import {Initialize} from "euler-vault-kit/EVault/modules/Initialize.sol";
import {Token, IERC20} from "euler-vault-kit/EVault/modules/Token.sol";
import {Vault} from "euler-vault-kit/EVault/modules/Vault.sol";
import {Borrowing} from "euler-vault-kit/EVault/modules/Borrowing.sol";
import {Liquidation} from "euler-vault-kit/EVault/modules/Liquidation.sol";
import {BalanceForwarder} from "euler-vault-kit/EVault/modules/BalanceForwarder.sol";
import {Governance} from "euler-vault-kit/EVault/modules/Governance.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {Base} from "euler-vault-kit/EVault/shared/Base.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {MockBalanceTracker} from "euler-vault-kit/../test/mocks/MockBalanceTracker.sol";
import {MockPriceOracle} from "euler-vault-kit/../test/mocks/MockPriceOracle.sol";
import {SequenceRegistry} from "euler-vault-kit/SequenceRegistry/SequenceRegistry.sol";
import {AssertionsCustomTypes} from "euler-vault-kit/../test/helpers/AssertionsCustomTypes.sol";
import "euler-vault-kit/EVault/shared/Constants.sol";

import {VaultManager} from "src/twyne/VaultManager.sol";
import {BridgeHookTarget} from "src/TwyneFactory/BridgeHookTarget.sol";
import {IRMTwyneCurve} from "src/twyne/IRMTwyneCurve.sol";
import {RiskManager} from "euler-vault-kit/EVault/modules/RiskManager.sol";
import {TwyneStorage} from "./TwyneTestStorage.t.sol";


abstract contract TwyneVaultTestBase is AssertionsCustomTypes, TwyneStorage, Test {

    function setUp() public virtual {
        (alice, aliceKey) = makeAddrAndKey("alice_random"); // active trader alice, trades dog coins
        (bob, bobKey) = makeAddrAndKey("bob_random");

        eve = makeAddr("eve"); // evil eve, blackhat and uses Twyne in ways we don't want
        liquidator = makeAddr("liquidator"); // liquidator of unhealthy positions
        teleporter = makeAddr("teleporter");

        admin = makeAddr("admin");
        feeReceiver = makeAddr("feeReceiver");
        protocolFeeReceiver = makeAddr("protocolFeeReceiver");
        evc = new EthereumVaultConnector();
        factory = new GenericFactory(admin);

        // Deploy CollateralVaultFactory implementation
        CollateralVaultFactory factoryImpl = new CollateralVaultFactory(address(evc));

        // Create initialization data for CollateralVaultFactory
        bytes memory initData = abi.encodeCall(CollateralVaultFactory.initialize, (admin));

        // Deploy CollateralVaultFactory proxy
        ERC1967Proxy factoryProxy = new ERC1967Proxy(address(factoryImpl), initData);
        collateralVaultFactory = CollateralVaultFactory(payable(address(factoryProxy)));

        protocolConfig = new ProtocolConfig(admin, protocolFeeReceiver);
        balanceTracker = address(new MockBalanceTracker());
        oracle = new MockPriceOracle();
        unitOfAccount = address(1);
        permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        sequenceRegistry = address(new SequenceRegistry());
        integrations =
            Base.Integrations(address(evc), address(protocolConfig), sequenceRegistry, balanceTracker, permit2);

        initializeModule = address(new Initialize(integrations));
        tokenModule = address(new Token(integrations));
        vaultModule = address(new Vault(integrations));
        borrowingModule = address(new Borrowing(integrations));
        liquidationModule = address(new Liquidation(integrations));
        riskManagerModule = address(new RiskManager(integrations));
        balanceForwarderModule = address(new BalanceForwarder(integrations));
        governanceModule = address(new Governance(integrations));
        vm.label(address(riskManagerModule), "RiskManager");
        modules = Dispatch.DeployedModules({
            initialize: initializeModule,
            token: tokenModule,
            vault: vaultModule,
            borrowing: borrowingModule,
            liquidation: liquidationModule,
            riskManager: riskManagerModule,
            balanceForwarder: balanceForwarderModule,
            governance: governanceModule
        });

        address evaultImpl = address(new EVault(integrations, modules));


        vm.startPrank(admin);
        protocolConfig.setInterestFeeRange(0, 0); // set fee range to zero
        protocolConfig.setProtocolFeeShare(0); // set protocol fee to zero
        factory.setImplementation(evaultImpl);

        // Deploy VaultManager implementation
        VaultManager vaultManagerImpl = new VaultManager();

        // Create initialization data for VaultManager
        initData = abi.encodeCall(VaultManager.initialize, (admin, address(collateralVaultFactory)));

        // Deploy VaultManager proxy
        ERC1967Proxy vaultManagerProxy = new ERC1967Proxy(address(vaultManagerImpl), initData);
        twyneVaultManager = VaultManager(payable(address(vaultManagerProxy)));

        oracleRouter = new EulerRouter(address(evc), address(twyneVaultManager));
        vm.label(address(oracleRouter), "oracleRouter");

        twyneVaultManager.setOracleRouter(address(oracleRouter));
        collateralVaultFactory.setVaultManager(address(twyneVaultManager));

        vm.stopPrank();
    }

    function getSubAccount(address primary, uint8 subAccountId) internal pure returns (address) {
        require(subAccountId <= 256, "invalid subAccountId");
        return address(uint160(uint160(primary) ^ subAccountId));
    }

    function dealEToken(address eToken, address receiver, uint256 amount) internal returns (uint256 received) {
        address underlyingAsset = IEVault(eToken).asset();
        // scale down the amount if the eToken has less decimals
        if (IEVault(underlyingAsset).decimals() < 18) {
            amount /= (10 ** (18 - IERC20(underlyingAsset).decimals()));
        }
        // deal the underlying asset to the user, then let them approve and deposit to the EVault
        deal(underlyingAsset, receiver, amount);
        vm.startPrank(receiver);
        IERC20(underlyingAsset).approve(eToken, type(uint256).max);

        // cache balanceBefore to measure number of eTokens received
        uint256 balanceBefore = IERC20(eToken).balanceOf(receiver);
        IEVault(eToken).deposit(amount, receiver);
        uint256 balanceAfter = IERC20(eToken).balanceOf(receiver);
        received = balanceAfter - balanceBefore;
        vm.stopPrank();
    }

    function isValidCollateralAsset(address collateralAsset) public view returns (bool) {
        console2.log(collateralAsset);
        for (uint collateralIndex; collateralIndex<fixtureCollateralAssets.length; collateralIndex++) {
            console2.log("List : ", fixtureCollateralAssets[collateralIndex]);
            if (fixtureCollateralAssets[collateralIndex] == collateralAsset) {
                return true;
            }
        }
        return false;
    }

    function isValidTargetAsset(address targetAsset) public view returns (bool) {
        for (uint targetIndex; targetIndex<fixtureTargetAssets.length; targetIndex++) {
            if (fixtureTargetAssets[targetIndex] == targetAsset) {
                return true;
            }
        }
        return false;
    }

}
