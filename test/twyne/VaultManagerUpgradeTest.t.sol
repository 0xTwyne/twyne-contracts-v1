// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";

contract VaultManagerCallTarget {
    uint public value;

    function setValue(uint _value) external {
        value = _value;
    }
}

/// @title VaultManagerUpgradeTest
/// @notice Tests for VaultManager UUPS upgrade functionality
contract VaultManagerUpgradeTest is Test {
    VaultManager public vaultManagerImpl;
    VaultManager public vaultManagerImplV2;
    ERC1967Proxy public proxy;
    VaultManager public vaultManager;

    address public admin;
    address public timelock;
    address public user;
    CollateralVaultFactory public factory;
    EthereumVaultConnector public evc;
    EulerRouter public oracleRouter;

    function setUp() public {
        admin = makeAddr("admin");
        timelock = makeAddr("timelock");
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
        assertEq(vaultManager.admin(), admin);
        assertEq(vaultManager.collateralVaultFactory(), address(factory));
    }

    function test_InitializeSetsAdminToOwner() public {
        VaultManager freshImpl = new VaultManager();
        ERC1967Proxy freshProxy = new ERC1967Proxy(
            address(freshImpl),
            abi.encodeCall(VaultManager.initialize, (admin, address(factory)))
        );
        VaultManager freshVaultManager = VaultManager(payable(address(freshProxy)));

        assertEq(freshVaultManager.owner(), admin);
        assertEq(freshVaultManager.admin(), admin);
        assertEq(freshVaultManager.collateralVaultFactory(), address(factory));
    }

    function test_UpgradeImplementation() public {
        // Deploy new implementation
        vaultManagerImplV2 = new VaultManager();

        // Upgrade implementation
        vm.prank(admin);
        vaultManager.upgradeToAndCall(address(vaultManagerImplV2), "");

        // Verify the upgrade worked by checking that the contract still functions
        assertEq(vaultManager.owner(), admin);
        assertEq(vaultManager.admin(), admin);
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
        assertEq(vaultManager.admin(), admin);
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
        assertEq(vaultManager.admin(), admin);
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

    function test_SetAdminOnlyOwner() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(user);
        vm.expectRevert();
        vaultManager.setAdmin(newAdmin);

        vm.prank(admin);
        vaultManager.setAdmin(newAdmin);
        assertEq(vaultManager.admin(), newAdmin);
    }

    function test_SetAdminRevertsForZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(TwyneErrors.ZeroAddress.selector);
        vaultManager.setAdmin(address(0));
    }

    function test_SetAdminRevokesOldAdminOperationalControl() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        vaultManager.setAdmin(newAdmin);

        vm.prank(admin);
        vm.expectRevert(TwyneErrors.CallerNotAdmin.selector);
        vaultManager.setOracleRouter(address(oracleRouter));

        vm.prank(newAdmin);
        vaultManager.setOracleRouter(address(oracleRouter));
    }

    function test_UpgradeCanSetAdminInSameCall() public {
        address newAdmin = makeAddr("newAdmin");
        vaultManagerImplV2 = new VaultManager();

        vm.prank(admin);
        vaultManager.upgradeToAndCall(address(vaultManagerImplV2), abi.encodeCall(VaultManager.setAdmin, (newAdmin)));

        assertEq(vaultManager.owner(), admin);
        assertEq(vaultManager.admin(), newAdmin);
        assertEq(vaultManager.collateralVaultFactory(), address(factory));
    }

    function test_AdminKeepsOperationalControlAfterOwnerTransferredToTimelock() public {
        vm.prank(admin);
        vaultManager.transferOwnership(timelock);

        assertEq(vaultManager.owner(), timelock);
        assertEq(vaultManager.admin(), admin);

        address intermediateVault = makeAddr("intermediateVault");
        address targetVault = makeAddr("targetVault");
        address targetAsset = makeAddr("targetAsset");
        address newFactory = makeAddr("newFactory");

        vm.prank(admin);
        vaultManager.setOracleRouter(address(oracleRouter));
        assertEq(address(vaultManager.oracleRouter()), address(oracleRouter));

        vm.prank(admin);
        vaultManager.setIntermediateVault(IEVault(intermediateVault), true);
        assertTrue(vaultManager.isIntermediateVault(intermediateVault));

        vm.prank(admin);
        vaultManager.setAllowedTargetVault(intermediateVault, targetVault);
        assertTrue(vaultManager.isAllowedTargetVault(intermediateVault, targetVault));

        vm.prank(admin);
        vaultManager.setAllowedTargetAsset(intermediateVault, targetVault, targetAsset);
        assertTrue(vaultManager.isAllowedTargetAssets(intermediateVault, targetVault, targetAsset));

        vm.prank(admin);
        vaultManager.setMaxLiquidationLTV(intermediateVault, 9000, 0);
        assertEq(vaultManager.maxTwyneLTVs(intermediateVault), 9000);

        vm.prank(admin);
        vaultManager.setExternalLiqBuffer(intermediateVault, 9500, 0);
        assertEq(vaultManager.externalLiqBuffers(intermediateVault), 9500);

        vm.prank(admin);
        vaultManager.setCollateralVaultFactory(newFactory);
        assertEq(vaultManager.collateralVaultFactory(), newFactory);

        VaultManagerCallTarget target = new VaultManagerCallTarget();
        vm.prank(admin);
        vaultManager.doCall(address(target), 0, abi.encodeCall(VaultManagerCallTarget.setValue, (42)));
        assertEq(target.value(), 42);
    }

    function test_TimelockOwnerCannotCallAdminOnlyFunctions() public {
        vm.prank(admin);
        vaultManager.transferOwnership(timelock);

        vm.prank(timelock);
        vm.expectRevert(TwyneErrors.CallerNotAdmin.selector);
        vaultManager.setOracleRouter(address(oracleRouter));

        vm.prank(timelock);
        vm.expectRevert(TwyneErrors.CallerNotAdmin.selector);
        vaultManager.setIntermediateVault(IEVault(makeAddr("intermediateVault")), true);

        vm.prank(timelock);
        vm.expectRevert(TwyneErrors.CallerNotAdmin.selector);
        vaultManager.setCollateralVaultFactory(makeAddr("newFactory"));

        VaultManagerCallTarget target = new VaultManagerCallTarget();
        vm.prank(timelock);
        vm.expectRevert(TwyneErrors.CallerNotAdmin.selector);
        vaultManager.doCall(address(target), 0, abi.encodeCall(VaultManagerCallTarget.setValue, (42)));
    }

    function test_AdminCannotUpgradeAfterOwnerTransferredToTimelock() public {
        vaultManagerImplV2 = new VaultManager();

        vm.prank(admin);
        vaultManager.transferOwnership(timelock);

        vm.prank(admin);
        vm.expectRevert();
        vaultManager.upgradeToAndCall(address(vaultManagerImplV2), "");

        vm.prank(timelock);
        vaultManager.upgradeToAndCall(address(vaultManagerImplV2), "");

        assertEq(vaultManager.owner(), timelock);
        assertEq(vaultManager.admin(), admin);
    }
}
