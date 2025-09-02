// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import "euler-vault-kit/EVault/shared/types/Types.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {EulerCollateralVault} from "src/twyne/EulerCollateralVault.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";


/// @title Twyne Collateral Vault v1 Upgrade Tests
/// @notice Tests for the first upgrade of Collateral Vaults to v1. Independent of other tests.
/// @dev This upgrade updates the `teleport` function to allow Euler subaccounts to teleport their position to Twyne.
contract TwyneUpgradeTests is Test {
    error UnknownProfile();

    address USDC;
    address eulerWETH;
    address eulerUSDC;

    VaultManager twyneVaultManager;
    IEVault intermediate_vault;
    CollateralVaultFactory collateralVaultFactory;
    EthereumVaultConnector evc;

    /// @notice Sets base chain addresses and labels commonly used by the tests.
    function setUp() public {
        if (block.chainid == 8453) { // base
            eulerWETH = 0x859160DB5841E5cfB8D3f144C6b3381A85A4b410;
            eulerUSDC = 0x0A1a3b5f2041F33522C4efc754a7D096f880eE16;
        } else {
            revert UnknownProfile();
        }

        USDC = IEVault(eulerUSDC).asset();
        vm.label(eulerUSDC, "eulerUSDC");
        vm.label(eulerWETH, "eulerWETH");

        vm.label(USDC, "USDC");

        twyneVaultManager = VaultManager(payable(0x5357426530F997E03Fcf8F68bdB4a7ac6ABa5d9f));
        vm.label(address(twyneVaultManager), "twyneVaultManager");
        intermediate_vault = IEVault(twyneVaultManager.getIntermediateVault(eulerWETH));
        vm.label(address(intermediate_vault), "intermediate_vault");
        collateralVaultFactory = CollateralVaultFactory(0xBe3205Ec9FF7314e9Df89d91ee28C5a22BEb1200);
        vm.label(address(collateralVaultFactory), "collateralVaultFactory");
        evc = EthereumVaultConnector(payable(0xC36aED7b7816aA21B660a33a637a8f9B9B70ad6c));
        vm.label(address(evc), "onchainEVC");
    }

    /// @notice Derives a subaccount address from a primary address and subaccount id.
    /// @param primary The primary EOA address.
    /// @param subAccountId The subaccount id (0-256).
    /// @return The derived subaccount address used by EVC/Euler.
    function getSubAccount(address primary, uint8 subAccountId) internal pure returns (address) {
        require(subAccountId <= 256, "invalid subAccountId");
        return address(uint160(uint160(primary) ^ subAccountId));
    }

    /// @notice Mints eTokens to `receiver` by dealing underlying and depositing into the EVault.
    /// @param eToken The EVault (eToken) address to deposit into.
    /// @param receiver The recipient of the minted eTokens.
    /// @param amount The nominal 18-decimal amount of underlying to deposit.
    /// @return received The number of eTokens minted to `receiver`.
    function dealEToken(address eToken, address receiver, uint256 amount) internal returns (uint256 received) {
        address underlyingAsset = IEVault(eToken).asset();
        // scale down the amount if the eToken has less decimals
        if (IEVault(underlyingAsset).decimals() < 18) {
            amount /= (10 ** (18 - IERC20(underlyingAsset).decimals()));
        }

        deal(underlyingAsset, receiver, amount);
        vm.startPrank(receiver);
        IERC20(underlyingAsset).approve(eToken, type(uint256).max);

        uint256 balanceBefore = IERC20(eToken).balanceOf(receiver);
        IEVault(eToken).deposit(amount, receiver);
        uint256 balanceAfter = IERC20(eToken).balanceOf(receiver);
        received = balanceAfter - balanceBefore;
        vm.stopPrank();
    }

    /// @notice Opens a borrow position on Euler (using eulerWETH as collateral and eulerUSDC for debt) for `subAccount1` owned by `user`.
    /// @dev Enables controller and collateral via EVC batch and borrows USDC to `user`.
    /// @param user The EOA initiating the position.
    /// @param subAccount1 The user's Euler subaccount to collateralize and borrow against.
    function e_createDebtPositionOnEuler(address user, address subAccount1) internal {
        IEVC eulerEVC = IEVC(IEVault(eulerUSDC).EVC());

        // Give user some collateral tokens
        uint256 collateralAmount = 10 ether;
        deal(address(IEVault(eulerWETH).asset()), user, collateralAmount);

        // User deposits collateral to Euler for subAccount1
        vm.startPrank(user);
        IERC20(IEVault(eulerWETH).asset()).approve(eulerWETH, collateralAmount);
        IEVault(eulerWETH).deposit(collateralAmount, subAccount1);
        vm.stopPrank();

        uint eulerWETHCollateralAmount = IEVault(eulerWETH).balanceOf(subAccount1);

        // Step 1: Open a borrow position on Euler using subAccount1 through EVC batch
        vm.startPrank(user);

        // Enable controller and collateral for subAccount1
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);
        items[0] = IEVC.BatchItem({
            targetContract: address(eulerEVC),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeCall(IEVC.enableController, (subAccount1, eulerUSDC))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(eulerEVC),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeCall(IEVC.enableCollateral, (subAccount1, eulerWETH))
        });

        // Borrow USDC against eulerWETH collateral
        uint256 borrowAmount = 5000 * 10**6; // 5000 USDC
        items[2] = IEVC.BatchItem({
            targetContract: eulerUSDC,
            onBehalfOfAccount: subAccount1,
            value: 0,
            data: abi.encodeCall(IEVault(eulerUSDC).borrow, (borrowAmount, user))
        });

        eulerEVC.batch(items);
        vm.stopPrank();

        // Verify the borrow position is created
        assertEq(IEVault(eulerUSDC).debtOf(subAccount1), borrowAmount, "Debt not created correctly");
        assertEq(IEVault(eulerWETH).balanceOf(subAccount1), eulerWETHCollateralAmount, "Collateral balance incorrect");
    }

    /// @notice Verifies that `teleport` continues to work after upgrading the collateral vault beacon implementation.
    /// @dev Simulates a beacon upgrade to a new `EulerCollateralVault` implementation and teleports a subaccount position.
    function test_e_teleportSubAccountProxyUpgrade() public {
        // Current time: Block at which version 0 of collateral vault is active
        vm.rollFork(33455299);
        // Bob deposits into intermediate_vault to earn boosted yield
        address bob = makeAddr("bob");
        uint CREDIT_LP_AMOUNT = 8 ether;
        dealEToken(eulerWETH, bob, CREDIT_LP_AMOUNT*2);

        vm.startPrank(bob);
        IERC20(eulerWETH).approve(address(intermediate_vault), type(uint256).max);
        intermediate_vault.deposit(CREDIT_LP_AMOUNT, bob);
        vm.stopPrank();

        // Setup: Create a user with collateral and a subaccount
        address user = makeAddr("user");
        address subAccount1 = getSubAccount(user, 1);
        vm.label(subAccount1, "subAccount1");
        IEVC eulerEVC = IEVC(IEVault(eulerUSDC).EVC());
        vm.label(address(eulerEVC), "eulerEVC");

        e_createDebtPositionOnEuler(user, subAccount1);

        // Step 2: Create a collateral vault and teleport the position
        vm.startPrank(user);
        EulerCollateralVault teleporter_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createCollateralVault(eulerWETH, eulerUSDC, 0.9e4)
        );
        vm.stopPrank();
        vm.label(address(teleporter_collateral_vault), "teleporter_collateral_vault");
        vm.label(address(teleporter_collateral_vault.intermediateVault()), "intermediateVault");

        // Fetch the eulerUSDC beacon from collateral vault factory
        address currentBeacon = collateralVaultFactory.collateralVaultBeacon(eulerUSDC);
        vm.label(currentBeacon, "currentBeacon");
        address oldImplementation = UpgradeableBeacon(currentBeacon).implementation();
        vm.label(oldImplementation, "implementation");
        require(currentBeacon != address(0), "Beacon not found for eulerUSDC");

        // Deploy a new implementation of EulerCollateralVault
        // In a real scenario, this would be a new version with updated logic
        address newImplementation = address(new EulerCollateralVault(address(evc), eulerUSDC));
        vm.label(newImplementation, "newImplementation");

        // Upgrade the beacon to point to the new implementation
        // This requires admin/owner privileges
        vm.startPrank(UpgradeableBeacon(currentBeacon).owner());
        UpgradeableBeacon(currentBeacon).upgradeTo(newImplementation);
        vm.stopPrank();

        // Verify the upgrade was successful
        assertEq(UpgradeableBeacon(currentBeacon).implementation(), newImplementation, "Beacon implementation not upgraded");
        assertTrue(UpgradeableBeacon(currentBeacon).implementation() != oldImplementation, "Implementation should have changed");

        // Verify the new vault is using the upgraded implementation
        // The vault should function normally with the new implementation
        assertEq(teleporter_collateral_vault.borrower(), user, "Vault borrower should be user");
        assertEq(address(teleporter_collateral_vault.asset()), eulerWETH, "Vault asset should be eulerWETH");
        assertEq(address(teleporter_collateral_vault.targetVault()), eulerUSDC, "Target vault should be eulerUSDS");
        assertEq(teleporter_collateral_vault.version(), 1, "Collateral vault is returning older version number");

        uint collateralAmount = IERC20(eulerWETH).balanceOf(subAccount1);
        uint borrowAmount = IEVault(eulerUSDC).debtOf(subAccount1);

        // Approve and teleport through batch
        vm.startPrank(user);
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: eulerWETH,
            onBehalfOfAccount: subAccount1,
            value: 0,
            data: abi.encodeCall(IERC20.approve, (address(teleporter_collateral_vault), collateralAmount))
        });
        eulerEVC.batch(items);

        items[0] = IEVC.BatchItem({
            targetContract: address(teleporter_collateral_vault),
            onBehalfOfAccount: user,
            value: 0,
            data: abi.encodeCall(EulerCollateralVault.teleport, (collateralAmount, borrowAmount, 1))
        });

        evc.batch(items);
        vm.stopPrank();

        assertEq(teleporter_collateral_vault.maxRepay(), borrowAmount, "borrow amount doesn't match after teleport");
        assertEq(teleporter_collateral_vault.totalAssetsDepositedOrReserved() - teleporter_collateral_vault.maxRelease(), collateralAmount, "collateral amount doesn't match after teleport");
    }

    /// @notice Verifies deposit, borrow, withdraw, and repay work after a simulated proxy upgrade.
    function test_e_postUpgradeCollateralVault() public noGasMetering {
        // Current time: Block at which version 0 of collateral vault is active
        vm.rollFork(33455299);

        address alice = makeAddr("alice");
        dealEToken(eulerWETH, alice, 10e18);

        vm.startPrank(alice);
        EulerCollateralVault alice_collateral_vault = EulerCollateralVault(
            collateralVaultFactory.createCollateralVault(eulerWETH, eulerUSDC, 0.9e4)
        );

        vm.label(address(alice_collateral_vault), "alice_collateral_vault");

        IERC20(eulerWETH).approve(address(alice_collateral_vault), type(uint).max);
        IERC20(USDC).approve(address(alice_collateral_vault), type(uint).max);
        vm.stopPrank();

        e_postUpgradeCollateralVault(alice_collateral_vault);

        address currentBeacon = collateralVaultFactory.collateralVaultBeacon(eulerUSDC);
        vm.label(currentBeacon, "currentBeacon");
        address oldImplementation = UpgradeableBeacon(currentBeacon).implementation();
        vm.label(oldImplementation, "implementation");
        require(currentBeacon != address(0), "Beacon not found for eulerUSDC");


        // Deploy a new implementation of EulerCollateralVault
        // In a real scenario, this would be a new version with updated logic
        address newImplementation = address(new EulerCollateralVault(address(evc), eulerUSDC));

        // Upgrade the beacon to point to the new implementation
        // This requires admin/owner privileges
        vm.startPrank(UpgradeableBeacon(currentBeacon).owner());
        UpgradeableBeacon(currentBeacon).upgradeTo(newImplementation);
        vm.stopPrank();

        // Verify the upgrade was successful
        assertEq(UpgradeableBeacon(currentBeacon).implementation(), newImplementation, "Beacon implementation not upgraded");
        assertTrue(UpgradeableBeacon(currentBeacon).implementation() != oldImplementation, "Implementation should have changed");

        // Verify the new vault is using the upgraded implementation
        // The vault should function normally with the new implementation
        assertEq(alice_collateral_vault.borrower(), alice, "Vault borrower should be user");
        assertEq(address(alice_collateral_vault.asset()), eulerWETH, "Vault asset should be eulerWETH");
        assertEq(address(alice_collateral_vault.targetVault()), eulerUSDC, "Target vault should be eulerUSDS");
        assertEq(alice_collateral_vault.version(), 1, "Collateral vault is returning older version number");

        e_postUpgradeCollateralVault(alice_collateral_vault);
    }

    /// @notice Helper that performs deposit/borrow followed by withdraw/repay against a given collateral vault using EVC batch.
    /// @param collateralVault The collateral vault under test.
    function e_postUpgradeCollateralVault(EulerCollateralVault collateralVault) internal {
        address borrower = collateralVault.borrower();
        vm.startPrank(borrower);
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: address(collateralVault),
            onBehalfOfAccount: borrower,
            value: 0,
            data: abi.encodeCall(collateralVault.deposit, (1e18))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(collateralVault),
            onBehalfOfAccount: borrower,
            value: 0,
            data: abi.encodeCall(collateralVault.borrow, (100*10e6, borrower))
        });

        evc.batch(items);

        items[0] = IEVC.BatchItem({
            targetContract: address(collateralVault),
            onBehalfOfAccount: borrower,
            value: 0,
            data: abi.encodeCall(collateralVault.withdraw, (0.5e18, borrower))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(collateralVault),
            onBehalfOfAccount: borrower,
            value: 0,
            data: abi.encodeCall(collateralVault.repay, (10*10e6))
        });

        evc.batch(items);
        vm.stopPrank();
    }

    /// @notice Post-upgrade onchain validation: run after the real beacon upgrade has occurred onchain.
    /// @dev Uses an existing deployed collateral vault and exercises deposit, borrow, withdraw, repay.
    /// @custom:integration Requires forking a block where v1 is live.
    function test_e_postRealUpgradeCollateralVault() public noGasMetering {
        // Current time: Block at which version 1 of collateral vault is active
        vm.rollFork(33938432);

        EulerCollateralVault collateralVault = EulerCollateralVault(0x613fb21975a1B819cA10458451D8914c41440942);

        dealEToken(eulerWETH, collateralVault.borrower(), 10e18);

        vm.startPrank(collateralVault.borrower());
        IERC20(eulerWETH).approve(address(collateralVault), type(uint).max);
        IERC20(USDC).approve(address(collateralVault), type(uint).max);
        vm.stopPrank();

        e_postUpgradeCollateralVault(collateralVault);
    }
}
