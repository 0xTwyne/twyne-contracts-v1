// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";

/// @title CollateralVaultFactoryUpgradeTest
/// @notice Tests for CollateralVaultFactory UUPS upgrade functionality
contract CollateralVaultFactoryUpgradeTest is Test {
    CollateralVaultFactory public factoryImpl;
    CollateralVaultFactory public factoryImplV2;
    ERC1967Proxy public proxy;
    CollateralVaultFactory public factory;

    VaultManager public vaultManager;
    address public admin;
    address public timelock;
    address public user;
    EthereumVaultConnector public evc;
    EulerRouter public oracleRouter;

    function setUp() public {
        admin = makeAddr("admin");
        timelock = makeAddr("timelock");
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
        assertEq(factory.admin(), admin);
        assertEq(address(factory.vaultManager()), address(vaultManager));
    }

    function test_InitializeSetsAdminToOwner() public {
        CollateralVaultFactory freshImpl = new CollateralVaultFactory(address(evc));
        ERC1967Proxy freshProxy = new ERC1967Proxy(
            address(freshImpl),
            abi.encodeCall(CollateralVaultFactory.initialize, (admin))
        );
        CollateralVaultFactory freshFactory = CollateralVaultFactory(payable(address(freshProxy)));

        assertEq(freshFactory.owner(), admin);
        assertEq(freshFactory.admin(), admin);
    }

    function test_UpgradeImplementation() public {
        // Deploy new implementation
        factoryImplV2 = new CollateralVaultFactory(address(evc));

        // Upgrade implementation
        vm.prank(admin);
        factory.upgradeToAndCall(address(factoryImplV2), "");

        // Verify the upgrade worked by checking that the contract still functions
        assertEq(factory.owner(), admin);
        assertEq(factory.admin(), admin);
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
        assertEq(factory.admin(), admin);
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

    function test_SetAdminOnlyOwner() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(user);
        vm.expectRevert();
        factory.setAdmin(newAdmin);

        vm.prank(admin);
        factory.setAdmin(newAdmin);
        assertEq(factory.admin(), newAdmin);
    }

    function test_SetAdminRevertsForZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(TwyneErrors.ZeroAddress.selector);
        factory.setAdmin(address(0));
    }

    function test_SetAdminRevokesOldAdminOperationalControl() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        factory.setAdmin(newAdmin);

        vm.prank(admin);
        vm.expectRevert(TwyneErrors.CallerNotAdmin.selector);
        factory.setBeacon(address(0x123), makeAddr("beacon"));

        vm.prank(newAdmin);
        factory.setBeacon(address(0x123), makeAddr("newBeacon"));
    }

    function test_UpgradeCanSetAdminInSameCall() public {
        address newAdmin = makeAddr("newAdmin");
        factoryImplV2 = new CollateralVaultFactory(address(evc));

        vm.prank(admin);
        factory.upgradeToAndCall(address(factoryImplV2), abi.encodeCall(CollateralVaultFactory.setAdmin, (newAdmin)));

        assertEq(factory.owner(), admin);
        assertEq(factory.admin(), newAdmin);
        assertEq(address(factory.vaultManager()), address(vaultManager));
    }

    function test_AdminKeepsOperationalControlAfterOwnerTransferredToTimelock() public {
        vm.prank(admin);
        factory.transferOwnership(timelock);

        assertEq(factory.owner(), timelock);
        assertEq(factory.admin(), admin);

        address beacon = makeAddr("beacon");
        vm.prank(admin);
        factory.setBeacon(address(0x123), beacon);
        assertEq(factory.collateralVaultBeacon(address(0x123)), beacon);

        vm.prank(admin);
        factory.setCategoryId(address(0x123), address(0x456), address(0x789), 1);
        assertEq(factory.categoryId(address(0x123), address(0x456), address(0x789)), 1);

        address pauseGuardian = makeAddr("pauseGuardian");
        vm.prank(admin);
        factory.setPauseGuardian(pauseGuardian);
        assertEq(factory.pauseGuardian(), pauseGuardian);

        vm.prank(admin);
        factory.pause();
        assertTrue(factory.paused());

        vm.prank(admin);
        factory.unpause();
        assertFalse(factory.paused());
    }

    function test_TimelockOwnerCannotCallAdminOnlyFunctions() public {
        vm.prank(admin);
        factory.transferOwnership(timelock);

        vm.prank(timelock);
        vm.expectRevert(TwyneErrors.CallerNotAdmin.selector);
        factory.setBeacon(address(0x123), makeAddr("beacon"));

        vm.prank(timelock);
        vm.expectRevert(TwyneErrors.CallerNotAdmin.selector);
        factory.setCategoryId(address(0x123), address(0x456), address(0x789), 1);

        vm.prank(timelock);
        vm.expectRevert(TwyneErrors.CallerNotAdmin.selector);
        factory.setPauseGuardian(makeAddr("pauseGuardian"));

        vm.prank(timelock);
        vm.expectRevert(TwyneErrors.CallerNotAdmin.selector);
        factory.setVaultManager(address(vaultManager));
    }

    function test_AdminCannotUpgradeAfterOwnerTransferredToTimelock() public {
        factoryImplV2 = new CollateralVaultFactory(address(evc));

        vm.prank(admin);
        factory.transferOwnership(timelock);

        vm.prank(admin);
        vm.expectRevert();
        factory.upgradeToAndCall(address(factoryImplV2), "");

        vm.prank(timelock);
        factory.upgradeToAndCall(address(factoryImplV2), "");

        assertEq(factory.owner(), timelock);
        assertEq(factory.admin(), admin);
    }

    function test_UpgradePreservesPauseState() public {
        // Pause the factory
        vm.prank(admin);
        factory.pause();

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

    function test_SetPauseGuardianAndAdminCanPauseUnpause() public {
        address pauseGuardian = makeAddr("pauseGuardian");
        vm.prank(admin);
        factory.setPauseGuardian(pauseGuardian);
        assertEq(factory.pauseGuardian(), pauseGuardian);

        vm.prank(pauseGuardian);
        factory.pause();
        assertTrue(factory.paused());

        vm.prank(admin);
        factory.unpause();
        assertFalse(factory.paused());
    }

    function test_PauseRevertsForNonAdminAndNonGuardian() public {
        address pauseGuardian = makeAddr("pauseGuardian");
        vm.prank(admin);
        factory.setPauseGuardian(pauseGuardian);

        vm.prank(user);
        vm.expectRevert(TwyneErrors.CallerNotOwnerOrPauseGuardian.selector);
        factory.pause();
    }

    function test_UnpauseRevertsForPauseGuardian() public {
        address pauseGuardian = makeAddr("pauseGuardian");
        vm.prank(admin);
        factory.setPauseGuardian(pauseGuardian);

        vm.prank(pauseGuardian);
        factory.pause();
        assertTrue(factory.paused());

        vm.prank(pauseGuardian);
        vm.expectRevert();
        factory.unpause();
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
