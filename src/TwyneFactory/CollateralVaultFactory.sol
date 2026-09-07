// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.28;

import {OwnableUpgradeable, ContextUpgradeable} from "openzeppelin-upgradeable/access/OwnableUpgradeable.sol";
import {Pausable} from "openzeppelin-contracts/utils/Pausable.sol";
import {UUPSUpgradeable} from "openzeppelin-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BeaconProxy} from "openzeppelin-contracts/proxy/beacon/BeaconProxy.sol";
import {AaveV3CollateralVault} from "src/twyne/AaveV3CollateralVault.sol";
import {EulerCollateralVault} from "src/twyne/EulerCollateralVault.sol";
import {MorphoCollateralVault} from "src/twyne/MorphoCollateralVault.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {EVCUtil} from "ethereum-vault-connector/utils/EVCUtil.sol";
import {IErrors} from "src/interfaces/IErrors.sol";
import {IEvents} from "src/interfaces/IEvents.sol";
import {MarketParams} from "morpho/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho/libraries/MarketParamsLib.sol";


/// @dev Ordered by severity. Higher value = more restrictive.
/// `whenNotPaused` blocks at the supplied threshold and above.
/// New levels can be inserted while preserving the `Active = 0` default.
enum PauseState {
    Active,
    Frozen,
    Paused
}


/// @title CollateralVaultFactory
/// @notice To contact the team regarding security matters, visit https://twyne.xyz/security
contract CollateralVaultFactory is UUPSUpgradeable, OwnableUpgradeable, EVCUtil, IErrors, IEvents {
    mapping(address targetVault => address beacon) public collateralVaultBeacon;
    mapping(address => bool) public isCollateralVault;

    /// @dev collateralVaults that are deployed by borrower or liquidated by borrower.
    /// vault may not be currently owned by borrower.
    mapping(address borrower => address[] collateralVaults) public collateralVaults;

    VaultManager public vaultManager;
    mapping(address borrower => uint nonce) public nonce;
    mapping(address targetVault => mapping(address collateralAsset => mapping(address targetAsset => uint8 categoryId))) public categoryId;
    address public pauseGuardian;
    address public admin;
    PauseState public pauseState;

    uint[46] private __gap;

    constructor(address _evc) EVCUtil(_evc) {
        _disableInitializers();
    }

    /// @notice Initialize the CollateralVaultFactory
    /// @param _owner Address of the initial owner
    function initialize(address _owner) external initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        admin = _owner;
    }

    /// @dev override required by UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    modifier onlyAdmin() {
        address sender = _msgSender();
        require(sender == admin || sender == owner(), CallerNotAdmin());
        _;
    }

    /// @dev increment the version for proxy upgrades
    function version() external pure returns (uint) {
        return 5;
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
    function setBeacon(address targetVault, address beacon) external onlyAdmin {
        collateralVaultBeacon[targetVault] = beacon;
        emit T_SetBeacon(targetVault, beacon);
    }

    /// @notice callable only by a collateral vault in the case where it has been liquidated
    function setCollateralVaultLiquidated(address liquidator) external {
        require(isCollateralVault[msg.sender], NotCollateralVault());
        collateralVaults[liquidator].push(msg.sender);
        emit T_SetCollateralVaultLiquidated(msg.sender, liquidator);
    }

    function setCategoryId(address _targetVault, address _collateralAsset, address _targetAsset, uint8 _categoryId) external onlyAdmin {
        categoryId[_targetVault][_collateralAsset][_targetAsset] = _categoryId;
        emit T_CategoryIdSet(_targetVault, _collateralAsset, _targetAsset, _categoryId);
    }

    /// @notice Set the operational admin. Owner-only so this path can be timelocked.
    function setAdmin(address _admin) external onlyOwner {
        require(_admin != address(0), ZeroAddress());
        admin = _admin;
        emit T_SetAdmin(_admin);
    }

    /// @notice Set a dedicated pause guardian that can only trigger emergency pauses.
    function setPauseGuardian(address _pauseGuardian) external onlyAdmin {
        pauseGuardian = _pauseGuardian;
        emit T_SetPauseGuardian(_pauseGuardian);
    }

    /// @dev Emergency escalation to full pause. Callable by admin or guardian.
    /// Guardian's only lever. Admin can also de-escalate via `setPauseState`.
    function pause() external {
        address sender = _msgSender();
        require(sender == admin || sender == pauseGuardian, CallerNotOwnerOrPauseGuardian());
        pauseState = PauseState.Paused;
        emit T_PauseStateChanged(uint8(PauseState.Paused));
    }

    /// @dev Set any pause level (Active, Frozen, Paused, or future levels). Admin-only.
    function setPauseState(PauseState newState) external onlyAdmin {
        pauseState = newState;
        emit T_PauseStateChanged(uint8(newState));
    }

    /// @dev Blocks when `pauseState` reaches `threshold` or any stricter level.
    /// Functions pass the severity at which they should start blocking
    /// (e.g. `PauseState.Frozen` blocks at both Frozen and Paused).
    modifier whenNotPaused(PauseState threshold) {
        require(pauseState < threshold, Pausable.EnforcedPause());
        _;
    }

    function _msgSender() internal view override(ContextUpgradeable, EVCUtil) returns (address) {
        return EVCUtil._msgSender();
    }

    /// @notice This function is called when a borrower wants to deploy a new Euler collateral vault.
    /// @param _intermediateVault address of the intermediate vault
    /// @param _targetVault address of the target vault, used for the lookup of the beacon proxy implementation contract
    /// @param _liqLTV user-specified target LTV
    /// @return vault address of the newly created collateral vault
    function createEulerCollateralVault(address _intermediateVault, address _targetVault, uint _liqLTV)
        public
        callThroughEVC
        whenNotPaused(PauseState.Frozen)
        returns (address vault)
    {
        require(vaultManager.isAllowedTargetVault(_intermediateVault, _targetVault), NotIntermediateVault());
        address msgSender;
        (vault, msgSender) = _deployVault(_intermediateVault, _targetVault);
        EulerCollateralVault(vault).initialize(_intermediateVault, msgSender, _liqLTV, vaultManager);
        _finalizeVault(_intermediateVault, vault);
    }

    /// @notice This function is called when a borrower wants to deploy a new Aave collateral vault.
    /// @param _intermediateVault address of the intermediate vault
    /// @param _targetVault address of the target vault, used for the lookup of the beacon proxy implementation contract
    /// @param _liqLTV user-specified target LTV
    /// @param _targetAsset debt token to be borrowed
    /// @return vault address of the newly created collateral vault
    function createAaveV3CollateralVault(address _intermediateVault, address _targetVault, uint _liqLTV, address _targetAsset)
        public
        callThroughEVC
        whenNotPaused(PauseState.Frozen)
        returns (address vault)
    {
        require(vaultManager.isAllowedTargetAssets(_intermediateVault, _targetVault, _targetAsset), NotIntermediateVault());
        address msgSender;
        (vault, msgSender) = _deployVault(_intermediateVault, _targetVault);
        address _asset = IEVault(_intermediateVault).asset();
        AaveV3CollateralVault(vault).initialize(_intermediateVault, msgSender, _liqLTV, vaultManager, _targetAsset, categoryId[_targetVault][_asset][_targetAsset]);
        _finalizeVault(_intermediateVault, vault);
    }

    /// @notice This function is called when a borrower wants to deploy a new Morpho collateral vault.
    /// @param _intermediateVault address of the intermediate vault
    /// @param _targetVault address of the target vault, used for the lookup of the beacon proxy implementation contract
    /// @param _marketParams Morpho market configuration used to initialize the vault
    /// @param _liqLTV user-specified target LTV
    /// @return vault address of the newly created collateral vault
    function createMorphoCollateralVault(address _intermediateVault, address _targetVault, MarketParams memory _marketParams, uint _liqLTV)
        external
        callThroughEVC
        whenNotPaused(PauseState.Frozen)
        returns (address vault)
    {
        require(vaultManager.isAllowedMorphoMarket(_targetVault, _intermediateVault, MarketParamsLib.id(_marketParams)), NotIntermediateVault());
        address msgSender;
        (vault, msgSender) = _deployVault(_intermediateVault, _targetVault);
        MorphoCollateralVault(vault).initialize(_intermediateVault, msgSender, _liqLTV, vaultManager, _marketParams);
        _finalizeVault(_intermediateVault, vault);
    }

    /// @dev Shared pre-initialization: validate intermediate vault, deploy BeaconProxy, register vault.
    function _deployVault(address _intermediateVault, address _targetVault) private returns (address vault, address msgSender) {
        msgSender = _msgSender();
        require(vaultManager.isIntermediateVault(_intermediateVault), IntermediateVaultNotSet());
        vault = address(new BeaconProxy{salt: keccak256(abi.encodePacked(msgSender, nonce[msgSender]++))}(collateralVaultBeacon[_targetVault], ""));
        isCollateralVault[vault] = true;
        collateralVaults[msgSender].push(vault);
    }

    /// @dev Shared post-initialization: register oracle, set LTV, emit event.
    /// Having hardcoded liquidationLimit=1e4 is fine since vault's liquidation by intermediateVault is disabled
    /// during normal operation. It's allowed only when vault is externally liquidated and that too it's to settle bad debt.
    function _finalizeVault(address _intermediateVault, address vault) private {
        vaultManager.setOracleResolvedVault(IEVault(_intermediateVault).oracle(), vault, true);
        vaultManager.setLTV(IEVault(_intermediateVault), vault, 1e4, 1e4, 0);
        emit T_CollateralVaultCreated(vault);
    }
}
