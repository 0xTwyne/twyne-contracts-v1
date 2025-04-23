// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.28;

import {ReentrancyGuardUpgradeable} from "openzeppelin-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {EVCUtil} from "ethereum-vault-connector/utils/EVCUtil.sol";
import {IErrors} from "src/interfaces/IErrors.sol";
import {IVault} from "ethereum-vault-connector/interfaces/IVault.sol";

/// @title VaultBase
/// @dev This contract is from evc-playground https://github.com/euler-xyz/evc-playground/blob/master/src/vaults/VaultBase.sol
/// @dev This contract is an abstract base contract for Vaults.
/// It declares functions that must be defined in the child contract in order to
/// correctly implement the controller release, vault status snapshotting and account/vaults
/// status checks.
abstract contract VaultBase is EVCUtil, ReentrancyGuardUpgradeable, IErrors, IVault {
    uint private snapshot;
    uint[50] private __gap;

    constructor(address _evc) EVCUtil(_evc) {}

    function __VaultBase_init() internal onlyInitializing {}

    /// @notice Prevents read-only reentrancy (should be used for view functions)
    modifier nonReentrantRO() virtual {
        if (_reentrancyGuardEntered()) {
            revert ReentrancyGuardReentrantCall();
        }
        _;
    }

    /// @notice Creates a snapshot of the vault state
    function createVaultSnapshot() internal {
        // We delete snapshots on `checkVaultStatus`, which can only happen at the end of the EVC batch. Snapshots are
        // taken before any action is taken on the vault that affects the vault asset records and deleted at the end, so
        // that asset calculations are always based on the state before the current batch of actions.
        if (snapshot == 0) {
            snapshot = doCreateVaultSnapshot();
        }
    }

    /// @notice Checks the vault status
    /// @dev Executed as a result of requiring vault status check on the EVC.
    function checkVaultStatus() external onlyEVCWithChecksInProgress returns (bytes4 magicValue) {
        doCheckVaultStatus(snapshot);
        delete snapshot;

        return IVault.checkVaultStatus.selector;
    }

    /// @notice Checks the account status
    /// @dev Executed on a controller as a result of requiring account status check on the EVC.
    function checkAccountStatus(
        address /*account*/,
        address[] calldata /*collaterals*/
    ) external view onlyEVCWithChecksInProgress returns (bytes4 magicValue) {

        return IVault.checkAccountStatus.selector;
    }

    /// @notice Creates a snapshot of the vault state
    /// @dev Must be overridden by child contracts
    function doCreateVaultSnapshot() internal virtual returns (uint);

    /// @notice Checks the vault status
    /// @dev Must be overridden by child contracts
    function doCheckVaultStatus(uint) internal virtual;
}
