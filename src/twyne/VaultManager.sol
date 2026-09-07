// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "openzeppelin-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "openzeppelin-upgradeable/access/OwnableUpgradeable.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {IErrors} from "src/interfaces/IErrors.sol";
import {IEvents} from "src/interfaces/IEvents.sol";
import {RevertBytes} from "euler-vault-kit/EVault/shared/lib/RevertBytes.sol";
import {Id} from "morpho/interfaces/IMorpho.sol";

interface ICollateralVaultBase {
    function asset() external view returns (address);
}

/// @title VaultManager
/// @notice To contact the team regarding security matters, visit https://twyne.xyz/security
/// @notice Manages twyne parameters that affect it globally: assets allowed, LTVs, interest rates.
contract VaultManager is UUPSUpgradeable, OwnableUpgradeable, IErrors, IEvents {
    uint internal constant MAXFACTOR = 1e4;

    /// @dev Ramp configuration for a single parameter.
    /// `initialValue` is snapshotted at update time, `targetTimestamp` is convergence time, and
    /// `rampDuration` is the linear interpolation window in seconds.
    struct RampConfig {
        uint16 initialValue;
        uint48 targetTimestamp;
        uint32 rampDuration;
    }

    address public collateralVaultFactory;

    mapping(address intermediateVault => mapping(address targetAsset => uint16 maxTwyneLiqLTV)) internal _maxTwyneLTVs;
    mapping(address intermediateVault => mapping(address targetAsset => uint16 externalLiqBuffer)) internal _externalLiqBuffers;

    EulerRouter internal __deprecated_oracleRouter;
    mapping(address collateralAddress => address intermediateVault) internal __deprecated_intermediateVaults;

    mapping(address intermediateVault => mapping(address targetVault => bool allowed)) public isAllowedTargetVault;

    mapping(address intermediateVault => address[] targetVaults) internal __deprecated_allowedTargetVaultList;

    mapping(address intermediateVault => mapping(address targetVault => mapping(address targetAsset => bool))) public isAllowedTargetAssets;

    mapping(address intermediateVault => mapping(address targetAsset => RampConfig maxTwyneLTVRamp)) internal maxTwyneLTVConfigs;
    mapping(address intermediateVault => mapping(address targetAsset => RampConfig externalLiqBufferRamp)) internal externalLiqBufferConfigs;

    mapping(address intermediateVault => bool) public isIntermediateVault;

    address public admin;

    mapping(address targetVault => mapping(address intermediateVault => mapping(Id marketId => bool isSupported))) public isAllowedMorphoMarket;

    mapping(address intermediateVault => mapping(address targetAsset => uint16 maxBorrowBuffer)) public borrowBuffer;

    uint[43] private __gap;

    modifier onlyAdmin() {
        address sender = _msgSender();
        require(sender == admin || sender == owner(), CallerNotAdmin());
        _;
    }

    modifier onlyCollateralVaultFactoryOrAdmin() {
        require(msg.sender == admin || msg.sender == collateralVaultFactory, CallerNotOwnerOrCollateralVaultFactory());
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /// @param _owner address of initial owner
    /// @param _factory address of collateral vault factory deployment
    function initialize(address _owner, address _factory) external initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        collateralVaultFactory = _factory;
        admin = _owner;
    }

    /// @dev override required by UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev increment the version for proxy upgrades
    function version() external pure returns (uint) {
        return 5;
    }

    /// @notice Register or unregister an intermediate vault. Governance-only.
    /// @param _intermediateVault address of the intermediate vault.
    /// @param _value true to register, false to unregister.
    function setIntermediateVault(IEVault _intermediateVault, bool _value) external onlyAdmin {
        isIntermediateVault[address(_intermediateVault)] = _value;
        emit T_SetIntermediateVault(address(_intermediateVault), _value);
    }

    /// @notice Set an allowed target vault for a specific intermediate vault. Governance-only.
    /// @param _intermediateVault address of the intermediate vault.
    /// @param _targetVault The target vault that should be allowed for the intermediate vault.
    function setAllowedTargetVault(address _intermediateVault, address _targetVault) external onlyAdmin {
        isAllowedTargetVault[_intermediateVault][_targetVault] = true;
        emit T_AddAllowedTargetVault(_intermediateVault, _targetVault);
    }

    /// @notice Set an allowed target asset for a specific intermediate vault. Governance-only.
    /// @notice For Aave like protocol where targetVault can be used to borrow multiple assets
    /// @param _intermediateVault address of the intermediate vault.
    /// @param _targetVault The target vault that should be allowed for the intermediate vault.
    /// @param _targetAsset The target asset to borrow
    function setAllowedTargetAsset(address _intermediateVault, address _targetVault, address _targetAsset) external onlyAdmin {
        isAllowedTargetAssets[_intermediateVault][_targetVault][_targetAsset] = true;
        emit  T_AddAllowedTargetVaultAsset(_intermediateVault, _targetVault, _targetAsset);
    }

    /// @notice Set or unset an allowed Morpho market for a specific target vault and intermediate vault pair.
    /// @param _targetVault address of the target vault (Morpho protocol address).
    /// @param _intermediateVault address of the intermediate vault.
    /// @param _marketId Morpho market id derived from market params.
    /// @param _value true to whitelist the market, false to remove it.
    function setAllowedMorphoMarket(address _targetVault, address _intermediateVault, Id _marketId, bool _value) external onlyAdmin {
        isAllowedMorphoMarket[_targetVault][_intermediateVault][_marketId] = _value;
        emit T_SetAllowedMorphoMarket(_targetVault, _intermediateVault, Id.unwrap(_marketId), _value);
    }

    /// @notice Set the max-borrow buffer for an (intermediate vault, target asset) pair. Governance-only. 1e4 precision (e.g. 300 = 3%).
    /// @param _intermediateVault address of the intermediate vault.
    /// @param _targetAsset address of the target asset.
    /// @param _borrowBuffer max-borrow buffer
    /// @dev `_borrowBuffer` must be strictly less than `maxTwyneLiqLTV - liqLTV_e` for the pair,
    /// otherwise `maxBorrow()` reverts with arithmetic underflow.
    function setBorrowBuffer(address _intermediateVault, address _targetAsset, uint16 _borrowBuffer) external onlyAdmin {
        require(_borrowBuffer <= MAXFACTOR, ValueOutOfRange());
        borrowBuffer[_intermediateVault][_targetAsset] = _borrowBuffer;
        emit T_SetBorrowBuffer(_intermediateVault, _targetAsset, _borrowBuffer);
    }

    /// @notice Set maxTwyneLiqLTV for an (intermediate vault, target asset) pair with optional linear ramp-down. Governance-only.
    /// @param _intermediateVault address of the intermediate vault.
    /// @param _targetAsset address of the target asset.
    /// @param _ltv new target maxTwyneLiqLTV value (1e4 precision).
    /// @param _rampDuration ramp duration in seconds. Set to 0 for immediate update.
    /// @dev If `_rampDuration > 0`, `_ltv` must be strictly lower than the current effective maxTwyneLTV.
    /// The current effective value is snapshotted as the ramp starting point.
    function setMaxLiquidationLTV(address _intermediateVault, address _targetAsset, uint16 _ltv, uint32 _rampDuration) external onlyAdmin {
        require(_ltv <= MAXFACTOR, ValueOutOfRange());
        uint16 currentLTV = maxTwyneLTVs(_intermediateVault, _targetAsset);
        if (_rampDuration > 0) {
            require(_ltv < currentLTV, ValueOutOfRange());
        }

        _maxTwyneLTVs[_intermediateVault][_targetAsset] = _ltv;
        maxTwyneLTVConfigs[_intermediateVault][_targetAsset] = RampConfig({
            initialValue: currentLTV,
            targetTimestamp: uint48(block.timestamp + _rampDuration),
            rampDuration: _rampDuration
        });
        emit T_SetMaxLiqLTV(_intermediateVault, _targetAsset, _ltv, _rampDuration);
    }

    /// @notice Set externalLiqBuffer for an (intermediate vault, target asset) pair with optional linear ramp-down. Governance-only.
    /// @param _intermediateVault address of the intermediate vault.
    /// @param _targetAsset address of the target asset.
    /// @param _liqBuffer new target externalLiqBuffer value (1e4 precision).
    /// @param _rampDuration ramp duration in seconds. Set to 0 for immediate update.
    /// @dev If `_rampDuration > 0`, `_liqBuffer` must be strictly lower than the current effective externalLiqBuffer.
    /// The current effective value is snapshotted as the ramp starting point.
    function setExternalLiqBuffer(address _intermediateVault, address _targetAsset, uint16 _liqBuffer, uint32 _rampDuration) external onlyAdmin {
        require(_liqBuffer <= MAXFACTOR, ValueOutOfRange());
        uint16 currentBuffer = externalLiqBuffers(_intermediateVault, _targetAsset);
        if (_rampDuration > 0) {
            require(_liqBuffer < currentBuffer, ValueOutOfRange());
        }

        _externalLiqBuffers[_intermediateVault][_targetAsset] = _liqBuffer;
        externalLiqBufferConfigs[_intermediateVault][_targetAsset] = RampConfig({
            initialValue: currentBuffer,
            targetTimestamp: uint48(block.timestamp + _rampDuration),
            rampDuration: _rampDuration
        });
        emit T_SetExternalLiqBuffer(_intermediateVault, _targetAsset, _liqBuffer, _rampDuration);
    }

    /// @notice Return current effective maxTwyneLTV for an (intermediate vault, target asset) pair.
    /// @param _intermediateVault address of the intermediate vault.
    /// @param _targetAsset address of the target asset.
    /// @return maxTwyneLiqLTV effective maxTwyneLTV after applying ramp interpolation.
    function maxTwyneLTVs(address _intermediateVault, address _targetAsset) public view returns (uint16) {
        return _getRampedValue(_maxTwyneLTVs[_intermediateVault][_targetAsset], maxTwyneLTVConfigs[_intermediateVault][_targetAsset]);
    }

    /// @notice Return current effective externalLiqBuffer for an (intermediate vault, target asset) pair.
    /// @param _intermediateVault address of the intermediate vault.
    /// @param _targetAsset address of the target asset.
    /// @return externalLiqBuffer effective externalLiqBuffer after applying ramp interpolation.
    function externalLiqBuffers(address _intermediateVault, address _targetAsset) public view returns (uint16) {
        return _getRampedValue(_externalLiqBuffers[_intermediateVault][_targetAsset], externalLiqBufferConfigs[_intermediateVault][_targetAsset]);
    }

    /// @notice Return current effective externalLiqBuffer, maxTwyneLTV, and borrowBuffer for an
    ///   (intermediate vault, target asset) pair in one call.
    /// @param _intermediateVault address of the intermediate vault.
    /// @param _targetAsset address of the target asset.
    /// @return externalLiqBuffer effective externalLiqBuffer after applying ramp interpolation.
    /// @return maxTwyneLiqLTV effective maxTwyneLTV after applying ramp interpolation.
    /// @return borrowBuffer max-borrow buffer for the (intermediate vault, target asset) pair (1e4 precision).
    function liqParams(address _intermediateVault, address _targetAsset) external view returns (uint16, uint16, uint16) {
        return (
            _getRampedValue(_externalLiqBuffers[_intermediateVault][_targetAsset], externalLiqBufferConfigs[_intermediateVault][_targetAsset]),
            _getRampedValue(_maxTwyneLTVs[_intermediateVault][_targetAsset], maxTwyneLTVConfigs[_intermediateVault][_targetAsset]),
            borrowBuffer[_intermediateVault][_targetAsset]
        );
    }

    /// @notice Return full maxTwyneLTV ramp metadata for an (intermediate vault, target asset) pair.
    /// @param _intermediateVault address of the intermediate vault.
    /// @param _targetAsset address of the target asset.
    /// @return maxTwyneLTV fully converged maxTwyneLTV target (stored target value).
    /// @return initialMaxTwyneLTV initial maxTwyneLTV value when ramp began.
    /// @return targetTimestamp timestamp when current value converges to target.
    /// @return rampDuration configured ramp duration in seconds.
    function maxTwyneLTVFull(address _intermediateVault, address _targetAsset) external view returns (uint16, uint16, uint48, uint32) {
        RampConfig storage cfg = maxTwyneLTVConfigs[_intermediateVault][_targetAsset];
        return (_maxTwyneLTVs[_intermediateVault][_targetAsset], cfg.initialValue, cfg.targetTimestamp, cfg.rampDuration);
    }

    /// @notice Return full externalLiqBuffer ramp metadata for an (intermediate vault, target asset) pair.
    /// @param _intermediateVault address of the intermediate vault.
    /// @param _targetAsset address of the target asset.
    /// @return externalLiqBuffer fully converged externalLiqBuffer target (stored target value).
    /// @return initialExternalLiqBuffer initial externalLiqBuffer value when ramp began.
    /// @return targetTimestamp timestamp when current value converges to target.
    /// @return rampDuration configured ramp duration in seconds.
    function externalLiqBufferFull(address _intermediateVault, address _targetAsset) external view returns (uint16, uint16, uint48, uint32) {
        RampConfig storage cfg = externalLiqBufferConfigs[_intermediateVault][_targetAsset];
        return (_externalLiqBuffers[_intermediateVault][_targetAsset], cfg.initialValue, cfg.targetTimestamp, cfg.rampDuration);
    }

    /// @notice Set new collateralVaultFactory address. Governance-only.
    /// @param _factory new collateralVaultFactory address.
    function setCollateralVaultFactory(address _factory) external onlyOwner {
        collateralVaultFactory = _factory;
        emit T_SetCollateralVaultFactory(_factory);
    }

    /// @notice Set the operational admin. Owner-only so this path can be timelocked.
    function setAdmin(address _admin) external onlyOwner {
        require(_admin != address(0), ZeroAddress());
        admin = _admin;
        emit T_SetAdmin(_admin);
    }

    /// @notice Set new LTV values for an intermediate vault by calling EVK.setLTV(). Callable by governance or collateral vault factory.
    /// @param _intermediateVault address of the intermediate vault.
    /// @param _collateralVault address of the collateral vault.
    /// @param _borrowLimit new borrow LTV.
    /// @param _liquidationLimit new liquidation LTV.
    /// @param _rampDuration ramp duration in seconds (0 for immediate effect) during which the liquidation LTV will change.
    function setLTV(IEVault _intermediateVault, address _collateralVault, uint16 _borrowLimit, uint16 _liquidationLimit, uint32 _rampDuration)
        external
        onlyCollateralVaultFactoryOrAdmin
    {
        require(ICollateralVaultBase(_collateralVault).asset() == _intermediateVault.asset(), AssetMismatch());
        _intermediateVault.setLTV(_collateralVault, _borrowLimit, _liquidationLimit, _rampDuration);
        emit T_SetLTV(address(_intermediateVault), _collateralVault, _borrowLimit, _liquidationLimit, _rampDuration);
    }

    /// @notice Set new oracleRouter resolved vault value for any oracle router. Callable by governance or collateral vault factory.
    /// @param _oracleRouter Oracle router which will be called by Vault Manager.
    /// @param _vault EVK or collateral vault address. Must implement `convertToAssets()`.
    /// @param _allow bool value to pass to govSetResolvedVault. True to configure the vault, false to clear the record.
    /// @dev called by createCollateralVault() when a new collateral vault is created so collateral can be price properly.
    /// @dev Configures the collateral vault to use internal pricing via `convertToAssets()`.
    function setOracleResolvedVault(address _oracleRouter, address _vault, bool _allow) external onlyCollateralVaultFactoryOrAdmin {
        EulerRouter(_oracleRouter).govSetResolvedVault(_vault, _allow);
        emit T_SetOracleResolvedVault(_oracleRouter, _vault, _allow);
    }

    /// @notice Perform an arbitrary external call. Governance-only.
    /// @dev VaultManager is an owner/admin of many contracts in the Twyne system.
    /// @dev This function helps Governance in case a specific a specific external function call was not implemented.
    function doCall(address to, uint value, bytes memory data) external payable onlyAdmin {
        (bool success, bytes memory _data) = to.call{value: value}(data);
        if (!success) RevertBytes.revertBytes(_data);
        emit T_DoCall(to, value, data);
    }

    /// @dev Returns the effective value of a ramped parameter at the current block timestamp.
    /// If no active ramp is in progress, returns the stored target value.
    /// Linear interpolation: `target + (initial - target) * timeRemaining / rampDuration`.
    function _getRampedValue(uint _targetValue, RampConfig storage _config) internal view returns (uint16) {
        uint targetTimestamp = _config.targetTimestamp;
        uint initialValue = _config.initialValue;
        if (block.timestamp >= targetTimestamp || _targetValue >= initialValue) {
            // Safe downcast: `_targetValue` is bounded by MAXFACTOR (1e4) at write time.
            return uint16(_targetValue);
        }

        unchecked {
            uint timeRemaining = targetTimestamp - block.timestamp;
            uint currentValue = _targetValue + (initialValue - _targetValue) * timeRemaining / _config.rampDuration;
            // Safe downcast: `currentValue` is between `_targetValue` and `initialValue` because
            // `timeRemaining / rampDuration <= 1` (ramp was set in the past so `block.timestamp >= T_set`).
            // Both bounds are <= MAXFACTOR (1e4) which fits in uint16. The invariant is self-reinforcing:
            // setters enforce `_ltv <= MAXFACTOR`, and `initialValue` is snapshotted from this function's output.
            return uint16(currentValue);
        }
    }

    receive() external payable {}
}
