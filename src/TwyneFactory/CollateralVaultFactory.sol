// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.28;

import {OwnableUpgradeable, ContextUpgradeable} from "openzeppelin-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "openzeppelin-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "openzeppelin-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BeaconProxy} from "openzeppelin-contracts/proxy/beacon/BeaconProxy.sol";
import {AaveV3CollateralVault} from "src/twyne/AaveV3CollateralVault.sol";
import {EulerCollateralVault} from "src/twyne/EulerCollateralVault.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {EVCUtil} from "ethereum-vault-connector/utils/EVCUtil.sol";
import {IErrors} from "src/interfaces/IErrors.sol";
import {IEvents} from "src/interfaces/IEvents.sol";


enum VaultType {
    EULER_V2,
    AAVE_V3
}


/// @title CollateralVaultFactory
/// @notice To contact the team regarding security matters, visit https://twyne.xyz/security
contract CollateralVaultFactory is UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable, EVCUtil, IErrors, IEvents {
    mapping(address targetVault => address beacon) public collateralVaultBeacon;
    mapping(address => bool) public isCollateralVault;

    /// @dev collateralVaults that are deployed by borrower or liquidated by borrower.
    /// vault may not be currently owned by borrower.
    mapping(address borrower => address[] collateralVaults) public collateralVaults;

    VaultManager public vaultManager;
    mapping(address borrower => uint nonce) public nonce;
    mapping(address targetVault => mapping(address collateralAsset => mapping( address targetAsset => uint8 categoryId))) public categoryId;

    uint[49] private __gap;

    constructor(address _evc) EVCUtil(_evc) {
        _disableInitializers();
    }

    /// @notice Initialize the CollateralVaultFactory
    /// @param _owner Address of the initial owner
    function initialize(address _owner) external initializer {
        __Ownable_init(_owner);
        __Pausable_init();
        __UUPSUpgradeable_init();
    }

    /// @dev override required by UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev increment the version for proxy upgrades
    function version() external pure returns (uint) {
        return 2;
    }

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

    function setCategoryId(address _targetVault, address _collateralAsset, address _targetAsset, uint8 _categoryId) external onlyOwner {
        categoryId[_targetVault][_collateralAsset][_targetAsset] = _categoryId;
        emit T_CategoryIdSet(_targetVault, _collateralAsset, _targetAsset, _categoryId);
    }

    /// @dev pause deposit and borrowing via collateral vault
    function pause(bool p) external onlyOwner {
        p ? _pause() : _unpause();
        emit T_FactoryPause(p);
    }

    function _msgSender() internal view override(ContextUpgradeable, EVCUtil) returns (address) {
        return EVCUtil._msgSender();
    }

    /// @notice This function is called when a borrower wants to deploy a new collateral vault.
    /// @param _vaultType type of vault, only EULER_V2 or AAVE_V3 allowed
    /// @param _asset address of vault asset
    /// @param _targetVault address of the target vault, used for the lookup of the beacon proxy implementation contract
    /// @param _liqLTV user-specified target LTV
    /// @param _targetAsset debt token to be borrowed
    /// @return vault address of the newly created collateral vault
    function createCollateralVault(VaultType _vaultType, address _asset, address _targetVault, uint _liqLTV, address _targetAsset)
        external
        callThroughEVC
        whenNotPaused
        returns (address vault)
    {
        // First validate the input params
        address intermediateVault = vaultManager.getIntermediateVault(_asset);
        if (_vaultType == VaultType.EULER_V2) {
            // collateral is allowed because the above line will revert if collateral is not recognized
            require(vaultManager.isAllowedTargetVault(intermediateVault, _targetVault), NotIntermediateVault());
        } else if (_vaultType == VaultType.AAVE_V3) {
            require(vaultManager.isAllowedTargetAssets(intermediateVault, _targetVault, _targetAsset), NotIntermediateVault());
        }
        address msgSender = _msgSender();
        vault = address(new BeaconProxy{salt: keccak256(abi.encodePacked(msgSender, nonce[msgSender]++))}(collateralVaultBeacon[_targetVault], ""));
        isCollateralVault[vault] = true;

        collateralVaults[msgSender].push(vault);
        if (_vaultType == VaultType.EULER_V2) {
            EulerCollateralVault(vault).initialize(IERC20(_asset), msgSender, _liqLTV, vaultManager);
            vaultManager.setOracleResolvedVault(vault, true);
        } else {
            AaveV3CollateralVault(vault).initialize(IERC20(_asset), msgSender, _liqLTV, vaultManager, _targetAsset, categoryId[_targetVault][_asset][_targetAsset]);
            vaultManager.setOracleResolvedVaultForOracleRouter(IEVault(intermediateVault).oracle(), vault, true);
        }
        // Having hardcoded _liquidationLimit here is fine since vault's liquidation by intermediateVault is disabled
        // during normal operation. It's allowed only when vault is externally liquidated and that too it's to settle bad debt.
        vaultManager.setLTV(IEVault(intermediateVault), vault, 1e4, 1e4, 0);

        emit T_CollateralVaultCreated(vault);
    }
}
