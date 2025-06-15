// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.28;

import {Ownable, Context} from "openzeppelin-contracts/access/Ownable.sol";
import {Pausable} from "openzeppelin-contracts/utils/Pausable.sol";
import {BeaconProxy} from "openzeppelin-contracts/proxy/beacon/BeaconProxy.sol";
import {CollateralVaultBase} from "src/twyne/CollateralVaultBase.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {EVCUtil} from "ethereum-vault-connector/utils/EVCUtil.sol";
import {IErrors} from "src/interfaces/IErrors.sol";
import {IEvents} from "src/interfaces/IEvents.sol";

/// @title CollateralVaultFactory
/// @notice To contact the team regarding security matters, visit https://twyne.xyz/security
contract CollateralVaultFactory is Ownable, Pausable, EVCUtil, IErrors, IEvents {
    mapping(address targetVault => address beacon) public collateralVaultBeacon;
    mapping(address => bool) public isCollateralVault;

    /// @dev collateralVaults that are deployed by borrower or liquidated by borrower.
    /// vault may not be currently owned by borrower.
    mapping(address borrower => address[] collateralVaults) public collateralVaults;

    VaultManager public vaultManager;
    mapping(address => uint nonce) public nonce;

    constructor(address _owner, address _evc) Ownable(_owner) EVCUtil(_evc) {}

    function getCollateralVaults(address borrower) external view returns (address[] memory) {
        return collateralVaults[borrower];
    }

    /// @notice Set a new vault manager address. Governance-only.
    function setVaultManager(address _manager) external onlyOwner {
        vaultManager = VaultManager(payable(_manager));
        emit T_SetVaultManager(_manager);
    }

    /// @notice Set a new beacon address for a specific target vault. Governance-only.
    function setBeacon(address targetVault, address beacon) external onlyOwner {
        collateralVaultBeacon[targetVault] = beacon;
        emit T_SetBeacon(targetVault, beacon);
    }

    /// @notice callable only by a collateral vault in the case where it has been liquidated
    function setCollateralVaultLiquidated(address liquidator) external {
        require(isCollateralVault[msg.sender], NotCollateralVault());
        collateralVaults[liquidator].push(msg.sender);
        emit T_SetCollateralVaultLiquidated(msg.sender, liquidator);
    }

    /// @dev pause deposit and borrowing via collateral vault
    function pause(bool p) external onlyOwner {
        p ? _pause() : _unpause();
        emit T_FactoryPause(p);
    }

    function _msgSender() internal view override(Context, EVCUtil) returns (address) {
        return EVCUtil._msgSender();
    }

    /// @notice This function is called when a borrower wants to deploy a new collateral vault.
    /// @param _asset address of vault asset
    /// @param _targetVault address of the target vault, used for the lookup of the beacon proxy implementation contract
    /// @param _liqLTV user-specified target LTV
    /// @return vault address of the newly created collateral vault
    function createCollateralVault(address _asset, address _targetVault, uint _liqLTV)
        external
        whenNotPaused
        callThroughEVC
        returns (address vault)
    {
        // First validate the input params
        address intermediateVault = vaultManager.getIntermediateVault(_asset);
        // collateral is allowed because the above line will revert if collateral is not recognized
        require(vaultManager.isAllowedTargetVault(intermediateVault, _targetVault), NotIntermediateVault());

        address msgSender = _msgSender();
        vault = address(new BeaconProxy{salt: keccak256(abi.encodePacked(msgSender, nonce[msgSender]++))}(collateralVaultBeacon[_targetVault], ""));
        isCollateralVault[vault] = true;

        collateralVaults[msgSender].push(vault);

        CollateralVaultBase(vault).initialize(IERC20(_asset), msgSender, _liqLTV, vaultManager);
        vaultManager.setOracleResolvedVault(vault, true);
        // Having hardcoded _liquidationLimit here is fine since vault's liquidation by intermediateVault is disabled
        // during normal operation. It's allowed only when vault is externally liquidated and that too it's to settle bad debt.
        vaultManager.setLTV(IEVault(intermediateVault), vault, 1e4, 1e4, 0);

        emit T_CollateralVaultCreated(vault);
    }
}
