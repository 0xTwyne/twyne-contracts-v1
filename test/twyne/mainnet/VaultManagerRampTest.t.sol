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
    address public targetAsset;

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");
        targetAsset = makeAddr("targetAsset");

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
        vaultManager.setMaxLiquidationLTV(intermediateVault, targetAsset, 9300, 0);

        uint start = block.timestamp;
        vaultManager.setMaxLiquidationLTV(intermediateVault, targetAsset, 7000, 1000);
        vm.stopPrank();

        assertEq(vaultManager.maxTwyneLTVs(intermediateVault, targetAsset), 9300);

        (uint16 targetLTV, uint16 initialLTV, uint48 targetTimestamp, uint32 rampDuration) =
            vaultManager.maxTwyneLTVFull(intermediateVault, targetAsset);
        assertEq(targetLTV, 7000);
        assertEq(initialLTV, 9300);
        assertEq(targetTimestamp, uint48(start + 1000));
        assertEq(rampDuration, 1000);

        vm.warp(start + 250);
        assertEq(vaultManager.maxTwyneLTVs(intermediateVault, targetAsset), 8725);

        vm.warp(start + 1000);
        assertEq(vaultManager.maxTwyneLTVs(intermediateVault, targetAsset), 7000);
    }

    function test_externalLiqBufferRampDown_InterpolatesLinearly() public {
        address intermediateVault = makeAddr("intermediateVault");

        vm.startPrank(admin);
        vaultManager.setExternalLiqBuffer(intermediateVault, targetAsset, 10_000, 0);

        uint start = block.timestamp;
        vaultManager.setExternalLiqBuffer(intermediateVault, targetAsset, 4_000, 1000);
        vm.stopPrank();

        assertEq(vaultManager.externalLiqBuffers(intermediateVault, targetAsset), 10_000);

        (uint16 targetBuffer, uint16 initialBuffer, uint48 targetTimestamp, uint32 rampDuration) =
            vaultManager.externalLiqBufferFull(intermediateVault, targetAsset);
        assertEq(targetBuffer, 4_000);
        assertEq(initialBuffer, 10_000);
        assertEq(targetTimestamp, uint48(start + 1000));
        assertEq(rampDuration, 1000);

        vm.warp(start + 250);
        assertEq(vaultManager.externalLiqBuffers(intermediateVault, targetAsset), 8_500);

        vm.warp(start + 1000);
        assertEq(vaultManager.externalLiqBuffers(intermediateVault, targetAsset), 4_000);
    }

    function test_rampDurationMustBeZeroWhenCurrentValueIsZero() public {
        address ivMaxLTV = makeAddr("ivMaxLTV");
        address ivBuffer = makeAddr("ivBuffer");

        vm.startPrank(admin);
        vm.expectRevert();
        vaultManager.setMaxLiquidationLTV(ivMaxLTV, targetAsset, 9000, 1000);

        vm.expectRevert();
        vaultManager.setExternalLiqBuffer(ivBuffer, targetAsset, 7000, 1000);

        // Admin can still set immediately from zero with rampDuration = 0.
        vaultManager.setMaxLiquidationLTV(ivMaxLTV, targetAsset, 9000, 0);
        vaultManager.setExternalLiqBuffer(ivBuffer, targetAsset, 7000, 0);
        vm.stopPrank();

        assertEq(vaultManager.maxTwyneLTVs(ivMaxLTV, targetAsset), 9000);
        assertEq(vaultManager.externalLiqBuffers(ivBuffer, targetAsset), 7000);
    }

    function test_rampUpOrFlatWithDurationReverts() public {
        address intermediateVault = makeAddr("intermediateVault");

        vm.startPrank(admin);
        vaultManager.setMaxLiquidationLTV(intermediateVault, targetAsset, 8000, 0);
        vaultManager.setExternalLiqBuffer(intermediateVault, targetAsset, 9000, 0);

        vm.expectRevert();
        vaultManager.setMaxLiquidationLTV(intermediateVault, targetAsset, 8000, 100);

        vm.expectRevert();
        vaultManager.setMaxLiquidationLTV(intermediateVault, targetAsset, 8100, 100);

        vm.expectRevert();
        vaultManager.setExternalLiqBuffer(intermediateVault, targetAsset, 9000, 100);

        vm.expectRevert();
        vaultManager.setExternalLiqBuffer(intermediateVault, targetAsset, 9100, 100);
        vm.stopPrank();
    }

    function test_maxTwyneLTVRampDown_MidRampChaining() public {
        address intermediateVault = makeAddr("intermediateVault");

        vm.startPrank(admin);
        vaultManager.setMaxLiquidationLTV(intermediateVault, targetAsset, 9000, 0);

        uint start = block.timestamp;
        // Ramp from 9000 → 7000 over 1000s
        vaultManager.setMaxLiquidationLTV(intermediateVault, targetAsset, 7000, 1000);

        // At T+500: effective = 7000 + (9000-7000)*500/1000 = 8000
        vm.warp(start + 500);
        assertEq(vaultManager.maxTwyneLTVs(intermediateVault, targetAsset), 8000);

        // Interrupt mid-ramp: new ramp from 8000 → 6000 over 2000s
        vaultManager.setMaxLiquidationLTV(intermediateVault, targetAsset, 6000, 2000);

        // Verify new ramp snapshots mid-ramp value as initialValue
        (uint16 targetLTV, uint16 initialLTV, uint48 targetTimestamp, uint32 rampDuration) =
            vaultManager.maxTwyneLTVFull(intermediateVault, targetAsset);
        assertEq(targetLTV, 6000);
        assertEq(initialLTV, 8000);
        assertEq(targetTimestamp, uint48(start + 500 + 2000));
        assertEq(rampDuration, 2000);

        // Immediately after setting: still 8000 (no jump)
        assertEq(vaultManager.maxTwyneLTVs(intermediateVault, targetAsset), 8000);

        // At T+500+1000 (halfway through new ramp): 6000 + (8000-6000)*1000/2000 = 7000
        vm.warp(start + 500 + 1000);
        assertEq(vaultManager.maxTwyneLTVs(intermediateVault, targetAsset), 7000);

        // At T+500+2000 (new ramp complete): 6000
        vm.warp(start + 500 + 2000);
        assertEq(vaultManager.maxTwyneLTVs(intermediateVault, targetAsset), 6000);
        vm.stopPrank();
    }

    function test_externalLiqBufferRampDown_MidRampChaining() public {
        address intermediateVault = makeAddr("intermediateVault");

        vm.startPrank(admin);
        vaultManager.setExternalLiqBuffer(intermediateVault, targetAsset, 10_000, 0);

        uint start = block.timestamp;
        // Ramp from 10000 → 6000 over 1000s
        vaultManager.setExternalLiqBuffer(intermediateVault, targetAsset, 6_000, 1000);

        // At T+500: effective = 6000 + (10000-6000)*500/1000 = 8000
        vm.warp(start + 500);
        assertEq(vaultManager.externalLiqBuffers(intermediateVault, targetAsset), 8_000);

        // Interrupt mid-ramp: new ramp from 8000 → 2000 over 2000s
        vaultManager.setExternalLiqBuffer(intermediateVault, targetAsset, 2_000, 2000);

        // Verify new ramp snapshots mid-ramp value as initialValue
        (uint16 targetBuffer, uint16 initialBuffer, uint48 targetTimestamp, uint32 rampDuration) =
            vaultManager.externalLiqBufferFull(intermediateVault, targetAsset);
        assertEq(targetBuffer, 2_000);
        assertEq(initialBuffer, 8_000);
        assertEq(targetTimestamp, uint48(start + 500 + 2000));
        assertEq(rampDuration, 2000);

        // Immediately after setting: still 8000 (no jump)
        assertEq(vaultManager.externalLiqBuffers(intermediateVault, targetAsset), 8_000);

        // At T+500+1000 (halfway through new ramp): 2000 + (8000-2000)*1000/2000 = 5000
        vm.warp(start + 500 + 1000);
        assertEq(vaultManager.externalLiqBuffers(intermediateVault, targetAsset), 5_000);

        // At T+500+2000 (new ramp complete): 2000
        vm.warp(start + 500 + 2000);
        assertEq(vaultManager.externalLiqBuffers(intermediateVault, targetAsset), 2_000);
        vm.stopPrank();
    }

    function test_maxTwyneLTV_ImmediateRaiseAboveCurrentMidRamp() public {
        address intermediateVault = makeAddr("intermediateVault");

        vm.startPrank(admin);
        vaultManager.setMaxLiquidationLTV(intermediateVault, targetAsset, 9000, 0);

        uint start = block.timestamp;
        // Ramp from 9000 → 7000 over 1000s
        vaultManager.setMaxLiquidationLTV(intermediateVault, targetAsset, 7000, 1000);

        // At T+500: effective = 8000
        vm.warp(start + 500);
        assertEq(vaultManager.maxTwyneLTVs(intermediateVault, targetAsset), 8000);

        // Set immediately to 8500 (above current effective 8000, rampDuration = 0)
        vaultManager.setMaxLiquidationLTV(intermediateVault, targetAsset, 8500, 0);
        assertEq(vaultManager.maxTwyneLTVs(intermediateVault, targetAsset), 8500);

        // Ramping up with duration should revert
        vm.expectRevert();
        vaultManager.setMaxLiquidationLTV(intermediateVault, targetAsset, 9000, 1000);
        vm.stopPrank();
    }

    function test_externalLiqBuffer_ImmediateRaiseAboveCurrentMidRamp() public {
        address intermediateVault = makeAddr("intermediateVault");

        vm.startPrank(admin);
        vaultManager.setExternalLiqBuffer(intermediateVault, targetAsset, 10_000, 0);

        uint start = block.timestamp;
        // Ramp from 10000 → 6000 over 1000s
        vaultManager.setExternalLiqBuffer(intermediateVault, targetAsset, 6_000, 1000);

        // At T+500: effective = 8000
        vm.warp(start + 500);
        assertEq(vaultManager.externalLiqBuffers(intermediateVault, targetAsset), 8_000);

        // Set immediately to 9000 (above current effective 8000, rampDuration = 0)
        vaultManager.setExternalLiqBuffer(intermediateVault, targetAsset, 9_000, 0);
        assertEq(vaultManager.externalLiqBuffers(intermediateVault, targetAsset), 9_000);

        // Ramping up with duration should revert
        vm.expectRevert();
        vaultManager.setExternalLiqBuffer(intermediateVault, targetAsset, 10_000, 1000);
        vm.stopPrank();
    }

    function test_externalLiqBufferCanBeZero() public {
        address intermediateVault = makeAddr("intermediateVault");

        vm.prank(admin);
        vaultManager.setExternalLiqBuffer(intermediateVault, targetAsset, 0, 0);

        assertEq(vaultManager.externalLiqBuffers(intermediateVault, targetAsset), 0);
    }

    /// @notice liqParams bundles externalLiqBuffer, maxTwyneLTV and borrowBuffer in one call;
    ///         the first two must apply ramp interpolation exactly like the individual getters.
    function test_liqParamsReturnsBufferMaxLTVAndBorrowBuffer() public {
        address intermediateVault = makeAddr("intermediateVault");

        vm.startPrank(admin);
        vaultManager.setMaxLiquidationLTV(intermediateVault, targetAsset, 9300, 0);
        vaultManager.setExternalLiqBuffer(intermediateVault, targetAsset, 10_000, 0);

        uint start = block.timestamp;
        // Active ramps: maxTwyneLTV 9300 → 7000, externalLiqBuffer 10_000 → 4_000 over 1000s.
        vaultManager.setMaxLiquidationLTV(intermediateVault, targetAsset, 7000, 1000);
        vaultManager.setExternalLiqBuffer(intermediateVault, targetAsset, 4_000, 1000);
        vaultManager.setBorrowBuffer(intermediateVault, targetAsset, 300);
        vm.stopPrank();

        // Pair keying: the buffer is scoped to (intermediateVault, targetAsset) only.
        address otherAsset = makeAddr("otherAsset");
        assertEq(vaultManager.borrowBuffer(intermediateVault, otherAsset), 0, "borrowBuffer leaked to another target asset");

        vm.warp(start + 250); // mid-ramp for both ramped params

        (uint16 buffer, uint16 maxTwyneLiqLTV, uint16 borrowBuffer) =
            vaultManager.liqParams(intermediateVault, targetAsset);
        assertEq(buffer, vaultManager.externalLiqBuffers(intermediateVault, targetAsset));
        assertEq(maxTwyneLiqLTV, vaultManager.maxTwyneLTVs(intermediateVault, targetAsset));
        assertEq(borrowBuffer, vaultManager.borrowBuffer(intermediateVault, targetAsset), "borrowBuffer not returned");

        // Mid-ramp sanity: both ramped values are strictly between initial and target.
        assertGt(buffer, 4_000);
        assertLt(buffer, 10_000);
        assertGt(maxTwyneLiqLTV, 7000);
        assertLt(maxTwyneLiqLTV, 9300);
        assertEq(borrowBuffer, 300);
    }

    /// @notice Per-(intermediateVault, targetAsset) entries must be fully independent:
    ///         distinct values coexist, ramping one pair leaves the other untouched, and a
    ///         never-configured asset key reads zero instead of aliasing a sibling entry.
    function test_perAssetConfigIsolation() public {
        address intermediateVault = makeAddr("intermediateVault");
        address assetA = makeAddr("assetA");
        address assetB = makeAddr("assetB");

        vm.startPrank(admin);
        vaultManager.setMaxLiquidationLTV(intermediateVault, assetA, 9_000, 0);
        vaultManager.setMaxLiquidationLTV(intermediateVault, assetB, 7_500, 0);
        vaultManager.setExternalLiqBuffer(intermediateVault, assetA, 8_000, 0);
        vaultManager.setExternalLiqBuffer(intermediateVault, assetB, 6_000, 0);
        vm.stopPrank();

        // Immediate values stay distinct per key.
        assertEq(vaultManager.maxTwyneLTVs(intermediateVault, assetA), 9_000);
        assertEq(vaultManager.maxTwyneLTVs(intermediateVault, assetB), 7_500);
        assertEq(vaultManager.externalLiqBuffers(intermediateVault, assetA), 8_000);
        assertEq(vaultManager.externalLiqBuffers(intermediateVault, assetB), 6_000);

        // A never-configured asset reads zero, not a sibling entry's value.
        address neverConfigured = makeAddr("neverConfigured");
        assertEq(vaultManager.maxTwyneLTVs(intermediateVault, neverConfigured), 0, "maxTwyneLTV aliased");
        assertEq(vaultManager.externalLiqBuffers(intermediateVault, neverConfigured), 0, "externalLiqBuffer aliased");

        // Ramp assetA down; assetB must keep its value and ramp metadata untouched.
        vm.startPrank(admin);
        uint start = block.timestamp;
        vaultManager.setMaxLiquidationLTV(intermediateVault, assetA, 5_000, 1_000);
        vm.stopPrank();

        vm.warp(start + 500); // assetA halfway: 5_000 + 4_000 * 500 / 1_000 = 7_000
        assertEq(vaultManager.maxTwyneLTVs(intermediateVault, assetA), 7_000);
        assertEq(vaultManager.maxTwyneLTVs(intermediateVault, assetB), 7_500, "assetB value drifted from assetA ramp");
        assertEq(vaultManager.externalLiqBuffers(intermediateVault, assetB), 6_000, "assetB buffer drifted");

        (uint16 targetLTV_B,,, uint32 rampDuration_B) = vaultManager.maxTwyneLTVFull(intermediateVault, assetB);
        assertEq(targetLTV_B, 7_500, "assetB target LTV mutated");
        assertEq(rampDuration_B, 0, "assetB ramp duration mutated");
    }
}
