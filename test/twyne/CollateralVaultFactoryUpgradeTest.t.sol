// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @title CollateralVaultFactoryUpgradeTest
/// @notice Tests for CollateralVaultFactory UUPS upgrade functionality
contract CollateralVaultFactoryUpgradeTest is Test {
    CollateralVaultFactory public factoryImpl;
    CollateralVaultFactory public factoryImplV2;
    ERC1967Proxy public proxy;
    CollateralVaultFactory public factory;

    VaultManager public vaultManager;
    address public admin;
    address public user;
    EthereumVaultConnector public evc;
    EulerRouter public oracleRouter;

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");

        // Deploy dependencies
        evc = new EthereumVaultConnector();

        // Deploy VaultManager implementation
        VaultManager vaultManagerImpl = new VaultManager();

        // Create initialization data for VaultManager
        bytes memory vaultManagerInitData = abi.encodeCall(VaultManager.initialize, (admin, address(0))); // placeholder factory address

        // Deploy VaultManager proxy
        ERC1967Proxy vaultManagerProxy = new ERC1967Proxy(address(vaultManagerImpl), vaultManagerInitData);
        vaultManager = VaultManager(payable(address(vaultManagerProxy)));

        // Deploy CollateralVaultFactory implementation
        factoryImpl = new CollateralVaultFactory(address(evc));

        // Create initialization data
        bytes memory factoryInitData = abi.encodeCall(CollateralVaultFactory.initialize, (admin));

        // Deploy proxy
        proxy = new ERC1967Proxy(address(factoryImpl), factoryInitData);
        factory = CollateralVaultFactory(payable(address(proxy)));

        // Set the vault manager in the factory
        vm.startPrank(admin);
        factory.setVaultManager(address(vaultManager));
        vm.stopPrank();
    }

    function test_Initialization() public view {
        assertEq(factory.owner(), admin);
        assertEq(address(factory.vaultManager()), address(vaultManager));
    }

    function test_UpgradeImplementation() public {
        // Deploy new implementation
        factoryImplV2 = new CollateralVaultFactory(address(evc));

        // Upgrade implementation
        vm.prank(admin);
        factory.upgradeToAndCall(address(factoryImplV2), "");

        // Verify the upgrade worked by checking that the contract still functions
        assertEq(factory.owner(), admin);
        assertEq(address(factory.vaultManager()), address(vaultManager));
    }

    function test_UpgradeImplementationRevertsIfNotOwner() public {
        // Deploy new implementation
        factoryImplV2 = new CollateralVaultFactory(address(evc));

        // Try to upgrade as non-owner
        vm.prank(user);
        vm.expectRevert();
        factory.upgradeToAndCall(address(factoryImplV2), "");
    }

    function test_UpgradeToZeroAddressReverts() public {
        vm.prank(admin);
        vm.expectRevert();
        factory.upgradeToAndCall(address(0), "");
    }

    function test_ProxyStorageIsolation() public {
        // Set some state
        address testBeacon = makeAddr("testBeacon");
        vm.prank(admin);
        factory.setBeacon(address(0x123), testBeacon);

        // Deploy new implementation
        factoryImplV2 = new CollateralVaultFactory(address(evc));

        // Upgrade implementation
        vm.prank(admin);
        factory.upgradeToAndCall(address(factoryImplV2), "");

        // Verify state is preserved
        assertEq(factory.collateralVaultBeacon(address(0x123)), testBeacon);
        assertEq(factory.owner(), admin);
        assertEq(address(factory.vaultManager()), address(vaultManager));
    }

    function test_ImplementationCannotBeInitialized() public {
        // Try to initialize the implementation directly
        vm.expectRevert();
        factoryImpl.initialize(admin);
    }

    function test_ProxyCannotBeInitializedTwice() public {
        // Try to initialize the proxy again
        vm.expectRevert();
        factory.initialize(user);
    }

    function test_UpgradePreservesPauseState() public {
        // Pause the factory
        vm.prank(admin);
        factory.pause(true);

        // Verify it's paused
        assertTrue(factory.paused());

        // Deploy new implementation
        factoryImplV2 = new CollateralVaultFactory(address(evc));

        // Upgrade implementation
        vm.prank(admin);
        factory.upgradeToAndCall(address(factoryImplV2), "");

        // Verify pause state is preserved
        assertTrue(factory.paused());
    }

    function test_UpgradePreservesBeaconMappings() public {
        // Set some beacons
        address beacon1 = makeAddr("beacon1");
        address beacon2 = makeAddr("beacon2");

        vm.prank(admin);
        factory.setBeacon(address(0x111), beacon1);
        vm.prank(admin);
        factory.setBeacon(address(0x222), beacon2);

        // Deploy new implementation
        factoryImplV2 = new CollateralVaultFactory(address(evc));

        // Upgrade implementation
        vm.prank(admin);
        factory.upgradeToAndCall(address(factoryImplV2), "");

        // Verify beacon mappings are preserved
        assertEq(factory.collateralVaultBeacon(address(0x111)), beacon1);
        assertEq(factory.collateralVaultBeacon(address(0x222)), beacon2);
    }
}
