// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";

/// @title VaultManagerUpgradeTest
/// @notice Tests for VaultManager UUPS upgrade functionality
contract VaultManagerUpgradeTest is Test {
    VaultManager public vaultManagerImpl;
    VaultManager public vaultManagerImplV2;
    ERC1967Proxy public proxy;
    VaultManager public vaultManager;

    address public admin;
    address public user;
    CollateralVaultFactory public factory;
    EthereumVaultConnector public evc;
    EulerRouter public oracleRouter;

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");

        // Deploy dependencies
        evc = new EthereumVaultConnector();
        // Deploy CollateralVaultFactory implementation
        CollateralVaultFactory factoryImpl = new CollateralVaultFactory(address(evc));

        // Create initialization data for CollateralVaultFactory
        bytes memory factoryInitData = abi.encodeCall(CollateralVaultFactory.initialize, (admin));

        // Deploy CollateralVaultFactory proxy
        ERC1967Proxy factoryProxy = new ERC1967Proxy(address(factoryImpl), factoryInitData);
        factory = CollateralVaultFactory(payable(address(factoryProxy)));

        // Deploy VaultManager implementation
        vaultManagerImpl = new VaultManager();

        // Create initialization data
        bytes memory initData = abi.encodeCall(VaultManager.initialize, (admin, address(factory)));

        // Deploy proxy
        proxy = new ERC1967Proxy(address(vaultManagerImpl), initData);
        vaultManager = VaultManager(payable(address(proxy)));
        oracleRouter = new EulerRouter(address(evc), address(vaultManager));
    }

    function test_Initialization() public view {
        assertEq(vaultManager.owner(), admin);
        assertEq(vaultManager.collateralVaultFactory(), address(factory));
    }

    function test_UpgradeImplementation() public {
        // Deploy new implementation
        vaultManagerImplV2 = new VaultManager();

        // Upgrade implementation
        vm.prank(admin);
        vaultManager.upgradeToAndCall(address(vaultManagerImplV2), "");

        // Verify the upgrade worked by checking that the contract still functions
        assertEq(vaultManager.owner(), admin);
        assertEq(vaultManager.collateralVaultFactory(), address(factory));
    }

    function test_UpgradeImplementationRevertsIfNotOwner() public {
        // Deploy new implementation
        vaultManagerImplV2 = new VaultManager();

        // Try to upgrade as non-owner
        vm.prank(user);
        vm.expectRevert();
        vaultManager.upgradeToAndCall(address(vaultManagerImplV2), "");
    }

    function test_UpgradeToAndCall1() public {
        // Deploy new implementation
        vaultManagerImplV2 = new VaultManager();

        // Upgrade and call
        vm.prank(admin);
        vaultManager.upgradeToAndCall(address(vaultManagerImplV2), "");

        // Verify the upgrade and call worked
        assertEq(vaultManager.owner(), admin);
        assertEq(vaultManager.collateralVaultFactory(), address(factory));
    }

    function test_UpgradeToAndCallRevertsIfNotOwner() public {
        // Deploy new implementation
        vaultManagerImplV2 = new VaultManager();

        // Create new initialization data for the upgrade
        bytes memory initData = abi.encodeCall(VaultManager.initialize, (user, address(factory)));

        // Try to upgrade and call as non-owner
        vm.prank(user);
        vm.expectRevert();
        vaultManager.upgradeToAndCall(address(vaultManagerImplV2), initData);
    }

    function test_UpgradeToZeroAddressReverts() public {
        vm.prank(admin);
        vm.expectRevert();
        vaultManager.upgradeToAndCall(address(0), "");
    }

    function test_UpgradeToAndCallWithZeroAddressReverts() public {
        bytes memory initData = abi.encodeCall(VaultManager.initialize, (user, address(factory)));

        vm.prank(admin);
        vm.expectRevert();
        vaultManager.upgradeToAndCall(address(0), initData);
    }

    function test_ProxyStorageIsolation() public {
        // Set some state
        vm.prank(admin);
        vaultManager.setOracleRouter(address(oracleRouter));

        // Deploy new implementation
        vaultManagerImplV2 = new VaultManager();

        // Upgrade implementation
        vm.prank(admin);
        vaultManager.upgradeToAndCall(address(vaultManagerImplV2), "");

        // Verify state is preserved
        assertEq(address(vaultManager.oracleRouter()), address(oracleRouter));
        assertEq(vaultManager.owner(), admin);
        assertEq(vaultManager.collateralVaultFactory(), address(factory));
    }

    function test_ImplementationCannotBeInitialized() public {
        // Try to initialize the implementation directly
        vm.expectRevert();
        vaultManagerImpl.initialize(admin, address(factory));
    }

    function test_ProxyCannotBeInitializedTwice() public {
        // Try to initialize the proxy again
        vm.expectRevert();
        vaultManager.initialize(user, address(factory));
    }
}
