// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";

/// @title VaultManagerRampTest
/// @notice Tests for VaultManager linear ramp-down of maxTwyneLTV and externalLiqBuffer
contract VaultManagerRampTest is Test {
    VaultManager public vaultManager;

    address public admin;
    address public user;

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");

        EthereumVaultConnector evc = new EthereumVaultConnector();
        CollateralVaultFactory factoryImpl = new CollateralVaultFactory(address(evc));
        bytes memory factoryInitData = abi.encodeCall(CollateralVaultFactory.initialize, (admin));
        ERC1967Proxy factoryProxy = new ERC1967Proxy(address(factoryImpl), factoryInitData);

        VaultManager vaultManagerImpl = new VaultManager();
        bytes memory initData =
            abi.encodeCall(VaultManager.initialize, (admin, address(CollateralVaultFactory(payable(address(factoryProxy))))));
        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultManagerImpl), initData);
        vaultManager = VaultManager(payable(address(proxy)));
    }

    function test_maxTwyneLTVRampDown_InterpolatesLinearly() public {
        address intermediateVault = makeAddr("intermediateVault");

        vm.startPrank(admin);
        vaultManager.setMaxLiquidationLTV(intermediateVault, 9300, 0);

        uint start = block.timestamp;
        vaultManager.setMaxLiquidationLTV(intermediateVault, 7000, 1000);
        vm.stopPrank();

        assertEq(vaultManager.maxTwyneLTVs(intermediateVault), 9300);

        (uint16 targetLTV, uint16 initialLTV, uint48 targetTimestamp, uint32 rampDuration) =
            vaultManager.maxTwyneLTVFull(intermediateVault);
        assertEq(targetLTV, 7000);
        assertEq(initialLTV, 9300);
        assertEq(targetTimestamp, uint48(start + 1000));
        assertEq(rampDuration, 1000);

        vm.warp(start + 250);
        assertEq(vaultManager.maxTwyneLTVs(intermediateVault), 8725);

        vm.warp(start + 1000);
        assertEq(vaultManager.maxTwyneLTVs(intermediateVault), 7000);
    }

    function test_externalLiqBufferRampDown_InterpolatesLinearly() public {
        address intermediateVault = makeAddr("intermediateVault");

        vm.startPrank(admin);
        vaultManager.setExternalLiqBuffer(intermediateVault, 10_000, 0);

        uint start = block.timestamp;
        vaultManager.setExternalLiqBuffer(intermediateVault, 4_000, 1000);
        vm.stopPrank();

        assertEq(vaultManager.externalLiqBuffers(intermediateVault), 10_000);

        (uint16 targetBuffer, uint16 initialBuffer, uint48 targetTimestamp, uint32 rampDuration) =
            vaultManager.externalLiqBufferFull(intermediateVault);
        assertEq(targetBuffer, 4_000);
        assertEq(initialBuffer, 10_000);
        assertEq(targetTimestamp, uint48(start + 1000));
        assertEq(rampDuration, 1000);

        vm.warp(start + 250);
        assertEq(vaultManager.externalLiqBuffers(intermediateVault), 8_500);

        vm.warp(start + 1000);
        assertEq(vaultManager.externalLiqBuffers(intermediateVault), 4_000);
    }

    function test_rampDurationMustBeZeroWhenCurrentValueIsZero() public {
        address ivMaxLTV = makeAddr("ivMaxLTV");
        address ivBuffer = makeAddr("ivBuffer");

        vm.startPrank(admin);
        vm.expectRevert();
        vaultManager.setMaxLiquidationLTV(ivMaxLTV, 9000, 1000);

        vm.expectRevert();
        vaultManager.setExternalLiqBuffer(ivBuffer, 7000, 1000);

        // Admin can still set immediately from zero with rampDuration = 0.
        vaultManager.setMaxLiquidationLTV(ivMaxLTV, 9000, 0);
        vaultManager.setExternalLiqBuffer(ivBuffer, 7000, 0);
        vm.stopPrank();

        assertEq(vaultManager.maxTwyneLTVs(ivMaxLTV), 9000);
        assertEq(vaultManager.externalLiqBuffers(ivBuffer), 7000);
    }

    function test_rampUpOrFlatWithDurationReverts() public {
        address intermediateVault = makeAddr("intermediateVault");

        vm.startPrank(admin);
        vaultManager.setMaxLiquidationLTV(intermediateVault, 8000, 0);
        vaultManager.setExternalLiqBuffer(intermediateVault, 9000, 0);

        vm.expectRevert();
        vaultManager.setMaxLiquidationLTV(intermediateVault, 8000, 100);

        vm.expectRevert();
        vaultManager.setMaxLiquidationLTV(intermediateVault, 8100, 100);

        vm.expectRevert();
        vaultManager.setExternalLiqBuffer(intermediateVault, 9000, 100);

        vm.expectRevert();
        vaultManager.setExternalLiqBuffer(intermediateVault, 9100, 100);
        vm.stopPrank();
    }

    function test_maxTwyneLTVRampDown_MidRampChaining() public {
        address intermediateVault = makeAddr("intermediateVault");

        vm.startPrank(admin);
        vaultManager.setMaxLiquidationLTV(intermediateVault, 9000, 0);

        uint start = block.timestamp;
        // Ramp from 9000 → 7000 over 1000s
        vaultManager.setMaxLiquidationLTV(intermediateVault, 7000, 1000);

        // At T+500: effective = 7000 + (9000-7000)*500/1000 = 8000
        vm.warp(start + 500);
        assertEq(vaultManager.maxTwyneLTVs(intermediateVault), 8000);

        // Interrupt mid-ramp: new ramp from 8000 → 6000 over 2000s
        vaultManager.setMaxLiquidationLTV(intermediateVault, 6000, 2000);

        // Verify new ramp snapshots mid-ramp value as initialValue
        (uint16 targetLTV, uint16 initialLTV, uint48 targetTimestamp, uint32 rampDuration) =
            vaultManager.maxTwyneLTVFull(intermediateVault);
        assertEq(targetLTV, 6000);
        assertEq(initialLTV, 8000);
        assertEq(targetTimestamp, uint48(start + 500 + 2000));
        assertEq(rampDuration, 2000);

        // Immediately after setting: still 8000 (no jump)
        assertEq(vaultManager.maxTwyneLTVs(intermediateVault), 8000);

        // At T+500+1000 (halfway through new ramp): 6000 + (8000-6000)*1000/2000 = 7000
        vm.warp(start + 500 + 1000);
        assertEq(vaultManager.maxTwyneLTVs(intermediateVault), 7000);

        // At T+500+2000 (new ramp complete): 6000
        vm.warp(start + 500 + 2000);
        assertEq(vaultManager.maxTwyneLTVs(intermediateVault), 6000);
        vm.stopPrank();
    }

    function test_externalLiqBufferRampDown_MidRampChaining() public {
        address intermediateVault = makeAddr("intermediateVault");

        vm.startPrank(admin);
        vaultManager.setExternalLiqBuffer(intermediateVault, 10_000, 0);

        uint start = block.timestamp;
        // Ramp from 10000 → 6000 over 1000s
        vaultManager.setExternalLiqBuffer(intermediateVault, 6_000, 1000);

        // At T+500: effective = 6000 + (10000-6000)*500/1000 = 8000
        vm.warp(start + 500);
        assertEq(vaultManager.externalLiqBuffers(intermediateVault), 8_000);

        // Interrupt mid-ramp: new ramp from 8000 → 2000 over 2000s
        vaultManager.setExternalLiqBuffer(intermediateVault, 2_000, 2000);

        // Verify new ramp snapshots mid-ramp value as initialValue
        (uint16 targetBuffer, uint16 initialBuffer, uint48 targetTimestamp, uint32 rampDuration) =
            vaultManager.externalLiqBufferFull(intermediateVault);
        assertEq(targetBuffer, 2_000);
        assertEq(initialBuffer, 8_000);
        assertEq(targetTimestamp, uint48(start + 500 + 2000));
        assertEq(rampDuration, 2000);

        // Immediately after setting: still 8000 (no jump)
        assertEq(vaultManager.externalLiqBuffers(intermediateVault), 8_000);

        // At T+500+1000 (halfway through new ramp): 2000 + (8000-2000)*1000/2000 = 5000
        vm.warp(start + 500 + 1000);
        assertEq(vaultManager.externalLiqBuffers(intermediateVault), 5_000);

        // At T+500+2000 (new ramp complete): 2000
        vm.warp(start + 500 + 2000);
        assertEq(vaultManager.externalLiqBuffers(intermediateVault), 2_000);
        vm.stopPrank();
    }

    function test_maxTwyneLTV_ImmediateRaiseAboveCurrentMidRamp() public {
        address intermediateVault = makeAddr("intermediateVault");

        vm.startPrank(admin);
        vaultManager.setMaxLiquidationLTV(intermediateVault, 9000, 0);

        uint start = block.timestamp;
        // Ramp from 9000 → 7000 over 1000s
        vaultManager.setMaxLiquidationLTV(intermediateVault, 7000, 1000);

        // At T+500: effective = 8000
        vm.warp(start + 500);
        assertEq(vaultManager.maxTwyneLTVs(intermediateVault), 8000);

        // Set immediately to 8500 (above current effective 8000, rampDuration = 0)
        vaultManager.setMaxLiquidationLTV(intermediateVault, 8500, 0);
        assertEq(vaultManager.maxTwyneLTVs(intermediateVault), 8500);

        // Ramping up with duration should revert
        vm.expectRevert();
        vaultManager.setMaxLiquidationLTV(intermediateVault, 9000, 1000);
        vm.stopPrank();
    }

    function test_externalLiqBuffer_ImmediateRaiseAboveCurrentMidRamp() public {
        address intermediateVault = makeAddr("intermediateVault");

        vm.startPrank(admin);
        vaultManager.setExternalLiqBuffer(intermediateVault, 10_000, 0);

        uint start = block.timestamp;
        // Ramp from 10000 → 6000 over 1000s
        vaultManager.setExternalLiqBuffer(intermediateVault, 6_000, 1000);

        // At T+500: effective = 8000
        vm.warp(start + 500);
        assertEq(vaultManager.externalLiqBuffers(intermediateVault), 8_000);

        // Set immediately to 9000 (above current effective 8000, rampDuration = 0)
        vaultManager.setExternalLiqBuffer(intermediateVault, 9_000, 0);
        assertEq(vaultManager.externalLiqBuffers(intermediateVault), 9_000);

        // Ramping up with duration should revert
        vm.expectRevert();
        vaultManager.setExternalLiqBuffer(intermediateVault, 10_000, 1000);
        vm.stopPrank();
    }

    function test_externalLiqBufferCanBeZero() public {
        address intermediateVault = makeAddr("intermediateVault");

        vm.prank(admin);
        vaultManager.setExternalLiqBuffer(intermediateVault, 0, 0);

        assertEq(vaultManager.externalLiqBuffers(intermediateVault), 0);
    }
}
