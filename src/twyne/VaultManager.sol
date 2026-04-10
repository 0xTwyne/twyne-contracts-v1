// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "openzeppelin-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "openzeppelin-upgradeable/access/OwnableUpgradeable.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {IErrors} from "src/interfaces/IErrors.sol";
import {IEvents} from "src/interfaces/IEvents.sol";
import {RevertBytes} from "euler-vault-kit/EVault/shared/lib/RevertBytes.sol";

interface ICollateralVaultBase {
    function asset() external view returns (address);
}

/// @title VaultManager
/// @notice To contact the team regarding security matters, visit https://twyne.xyz/security
/// @notice Manages twyne parameters that affect it globally: assets allowed, LTVs, interest rates.
/// To be owned by Twyne multisig.
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

    mapping(address intermediateVault => uint16 maxTwyneLiqLTV) internal _maxTwyneLTVs;
    mapping(address intermediateVault => uint16 externalLiqBuffer) internal _externalLiqBuffers;

    EulerRouter public oracleRouter;

    /// @dev Deprecated. Kept for storage layout compatibility. Use isIntermediateVault instead.
    /// @dev MIGRATION: When upgrading from v2, existing intermediate vaults registered in this mapping
    /// must be re-registered via setIntermediateVault() so they appear in isIntermediateVault.
    mapping(address collateralAddress => address intermediateVault) internal __deprecated_intermediateVaults;
    mapping(address intermediateVault => mapping(address targetVault => bool allowed)) public isAllowedTargetVault;

    mapping(address intermediateVault => address[] targetVaults) public allowedTargetVaultList;

    mapping(address intermediateVault => mapping(address targetVault => mapping(address targetAsset => bool))) public isAllowedTargetAssets;

    mapping(address intermediateVault => RampConfig maxTwyneLTVRamp) internal maxTwyneLTVConfigs;
    mapping(address intermediateVault => RampConfig externalLiqBufferRamp) internal externalLiqBufferConfigs;

    mapping(address intermediateVault => bool) public isIntermediateVault;

    uint[46] private __gap;

    modifier onlyCollateralVaultFactoryOrOwner() {
        require(msg.sender == owner() || msg.sender == collateralVaultFactory, CallerNotOwnerOrCollateralVaultFactory());
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
    }

    /// @dev override required by UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev increment the version for proxy upgrades
    function version() external pure returns (uint) {
        return 3;
    }

    /// @notice Set oracleRouter address. Governance-only.
    function setOracleRouter(address _oracle) external onlyOwner {
        oracleRouter = EulerRouter(_oracle);
        emit T_SetOracleRouter(_oracle);
    }

    /// @notice Register or unregister an intermediate vault. Governance-only.
    /// @param _intermediateVault address of the intermediate vault.
    /// @param _value true to register, false to unregister.
    function setIntermediateVault(IEVault _intermediateVault, bool _value) external onlyOwner {
        isIntermediateVault[address(_intermediateVault)] = _value;
        emit T_SetIntermediateVault(address(_intermediateVault), _value);
    }

    /// @notice Set an allowed target vault for a specific intermediate vault. Governance-only.
    /// @param _intermediateVault address of the intermediate vault.
    /// @param _targetVault The target vault that should be allowed for the intermediate vault.
    function setAllowedTargetVault(address _intermediateVault, address _targetVault) external onlyOwner {
        isAllowedTargetVault[_intermediateVault][_targetVault] = true;
        allowedTargetVaultList[_intermediateVault].push(_targetVault);
        emit T_AddAllowedTargetVault(_intermediateVault, _targetVault);
    }

    /// @notice Set an allowed target asset for a specific intermediate vault. Governance-only.
    /// @notice For Aave like protocol where targetVault can be used to borrow multiple assets
    /// @param _intermediateVault address of the intermediate vault.
    /// @param _targetVault The target vault that should be allowed for the intermediate vault.
    /// @param _targetAsset The target asset to borrow
    function setAllowedTargetAsset(address _intermediateVault, address _targetVault, address _targetAsset) external onlyOwner {
        isAllowedTargetAssets[_intermediateVault][_targetVault][_targetAsset] = true;
        emit  T_AddAllowedTargetVaultAsset(_intermediateVault, _targetVault, _targetAsset);
    }

    /// @notice Remove an allowed target vault for a specific intermediate vault. Governance-only.
    /// @param _intermediateVault address of the intermediate vault.
    /// @param _targetVault The target vault that should be allowed for the intermediate vault.
    /// @param _index The index at which this _targetVault is stored in `allowedTargetVaultList`.
    function removeAllowedTargetVault(address _intermediateVault, address _targetVault, uint _index) external onlyOwner {
        isAllowedTargetVault[_intermediateVault][_targetVault] = false;

        require(allowedTargetVaultList[_intermediateVault][_index] == _targetVault, IncorrectIndex());

        uint lastIndex = allowedTargetVaultList[_intermediateVault].length - 1;
        if (_index != lastIndex) allowedTargetVaultList[_intermediateVault][_index] = allowedTargetVaultList[_intermediateVault][lastIndex];
        allowedTargetVaultList[_intermediateVault].pop();
        emit T_RemoveAllowedTargetVault(_intermediateVault, _targetVault, _index);
    }

    /// @notice Return the length of allowedTargetVaultList. Useful for frontend.
    function targetVaultLength(address _intermediateVault) external view returns (uint) {
        return allowedTargetVaultList[_intermediateVault].length;
    }

    /// @notice Set maxTwyneLiqLTV for an intermediate vault with optional linear ramp-down. Governance-only.
    /// @param _intermediateVault address of the intermediate vault.
    /// @param _ltv new target maxTwyneLiqLTV value (1e4 precision).
    /// @param _rampDuration ramp duration in seconds. Set to 0 for immediate update.
    /// @dev If `_rampDuration > 0`, `_ltv` must be strictly lower than the current effective maxTwyneLTV.
    /// The current effective value is snapshotted as the ramp starting point.
    function setMaxLiquidationLTV(address _intermediateVault, uint16 _ltv, uint32 _rampDuration) external onlyOwner {
        require(_ltv <= MAXFACTOR, ValueOutOfRange());
        uint16 currentLTV = maxTwyneLTVs(_intermediateVault);
        if (_rampDuration > 0) {
            require(_ltv < currentLTV, ValueOutOfRange());
        }

        _maxTwyneLTVs[_intermediateVault] = _ltv;
        maxTwyneLTVConfigs[_intermediateVault] = RampConfig({
            initialValue: currentLTV,
            targetTimestamp: uint48(block.timestamp + _rampDuration),
            rampDuration: _rampDuration
        });
        emit T_SetMaxLiqLTV(_intermediateVault, _ltv, _rampDuration);
    }

    /// @notice Set externalLiqBuffer for an intermediate vault with optional linear ramp-down. Governance-only.
    /// @param _intermediateVault address of the intermediate vault.
    /// @param _liqBuffer new target externalLiqBuffer value (1e4 precision).
    /// @param _rampDuration ramp duration in seconds. Set to 0 for immediate update.
    /// @dev If `_rampDuration > 0`, `_liqBuffer` must be strictly lower than the current effective externalLiqBuffer.
    /// The current effective value is snapshotted as the ramp starting point.
    function setExternalLiqBuffer(address _intermediateVault, uint16 _liqBuffer, uint32 _rampDuration) external onlyOwner {
        require(_liqBuffer <= MAXFACTOR, ValueOutOfRange());
        uint16 currentBuffer = externalLiqBuffers(_intermediateVault);
        if (_rampDuration > 0) {
            require(_liqBuffer < currentBuffer, ValueOutOfRange());
        }

        _externalLiqBuffers[_intermediateVault] = _liqBuffer;
        externalLiqBufferConfigs[_intermediateVault] = RampConfig({
            initialValue: currentBuffer,
            targetTimestamp: uint48(block.timestamp + _rampDuration),
            rampDuration: _rampDuration
        });
        emit T_SetExternalLiqBuffer(_intermediateVault, _liqBuffer, _rampDuration);
    }

    /// @notice Return current effective maxTwyneLTV for an intermediate vault.
    /// @param _intermediateVault address of the intermediate vault.
    /// @return maxTwyneLiqLTV effective maxTwyneLTV after applying ramp interpolation.
    function maxTwyneLTVs(address _intermediateVault) public view returns (uint16 maxTwyneLiqLTV) {
        return _getRampedValue(_maxTwyneLTVs[_intermediateVault], maxTwyneLTVConfigs[_intermediateVault]);
    }

    /// @notice Return current effective externalLiqBuffer for an intermediate vault.
    /// @param _intermediateVault address of the intermediate vault.
    /// @return externalLiqBuffer effective externalLiqBuffer after applying ramp interpolation.
    function externalLiqBuffers(address _intermediateVault) public view returns (uint16 externalLiqBuffer) {
        return _getRampedValue(_externalLiqBuffers[_intermediateVault], externalLiqBufferConfigs[_intermediateVault]);
    }

    /// @notice Return full maxTwyneLTV ramp metadata for an intermediate vault.
    /// @param _intermediateVault address of the intermediate vault.
    /// @return maxTwyneLTV fully converged maxTwyneLTV target (stored target value).
    /// @return initialMaxTwyneLTV initial maxTwyneLTV value when ramp began.
    /// @return targetTimestamp timestamp when current value converges to target.
    /// @return rampDuration configured ramp duration in seconds.
    function maxTwyneLTVFull(address _intermediateVault) external view returns (uint16, uint16, uint48, uint32) {
        RampConfig storage cfg = maxTwyneLTVConfigs[_intermediateVault];
        return (_maxTwyneLTVs[_intermediateVault], cfg.initialValue, cfg.targetTimestamp, cfg.rampDuration);
    }

    /// @notice Return full externalLiqBuffer ramp metadata for an intermediate vault.
    /// @param _intermediateVault address of the intermediate vault.
    /// @return externalLiqBuffer fully converged externalLiqBuffer target (stored target value).
    /// @return initialExternalLiqBuffer initial externalLiqBuffer value when ramp began.
    /// @return targetTimestamp timestamp when current value converges to target.
    /// @return rampDuration configured ramp duration in seconds.
    function externalLiqBufferFull(address _intermediateVault) external view returns (uint16, uint16, uint48, uint32) {
        RampConfig storage cfg = externalLiqBufferConfigs[_intermediateVault];
        return (_externalLiqBuffers[_intermediateVault], cfg.initialValue, cfg.targetTimestamp, cfg.rampDuration);
    }

    /// @notice Set new collateralVaultFactory address. Governance-only.
    /// @param _factory new collateralVaultFactory address.
    function setCollateralVaultFactory(address _factory) external onlyOwner {
        collateralVaultFactory = _factory;
        emit T_SetCollateralVaultFactory(_factory);
    }

    /// @notice Set new LTV values for an intermediate vault by calling EVK.setLTV(). Callable by governance or collateral vault factory.
    /// @param _intermediateVault address of the intermediate vault.
    /// @param _collateralVault address of the collateral vault.
    /// @param _borrowLimit new borrow LTV.
    /// @param _liquidationLimit new liquidation LTV.
    /// @param _rampDuration ramp duration in seconds (0 for immediate effect) during which the liquidation LTV will change.
    function setLTV(IEVault _intermediateVault, address _collateralVault, uint16 _borrowLimit, uint16 _liquidationLimit, uint32 _rampDuration)
        external
        onlyCollateralVaultFactoryOrOwner
    {
        require(ICollateralVaultBase(_collateralVault).asset() == _intermediateVault.asset(), AssetMismatch());
        _intermediateVault.setLTV(_collateralVault, _borrowLimit, _liquidationLimit, _rampDuration);
        emit T_SetLTV(address(_intermediateVault), _collateralVault, _borrowLimit, _liquidationLimit, _rampDuration);
    }

    /// @notice Set new oracleRouter resolved vault value. Callable by governance or collateral vault factory.
    /// @param _vault EVK or collateral vault address. Must implement `convertToAssets()`.
    /// @param _allow bool value to pass to govSetResolvedVault. True to configure the vault, false to clear the record.
    /// @dev called by createCollateralVault() when a new collateral vault is created so collateral can be price properly.
    /// @dev Configures the collateral vault to use internal pricing via `convertToAssets()`.
    function setOracleResolvedVault(address _vault, bool _allow) external onlyCollateralVaultFactoryOrOwner {
        oracleRouter.govSetResolvedVault(_vault, _allow);
        emit T_SetOracleResolvedVault(_vault, _allow);
    }

    /// @notice Set new oracleRouter resolved vault value for any oracle router. Callable by governance or collateral vault factory.
    /// @param _oracleRouter Oracle router which will be called by Vault Manager.
    /// @param _vault EVK or collateral vault address. Must implement `convertToAssets()`.
    /// @param _allow bool value to pass to govSetResolvedVault. True to configure the vault, false to clear the record.
    /// @dev called by createCollateralVault() when a new collateral vault is created so collateral can be price properly.
    /// @dev Configures the collateral vault to use internal pricing via `convertToAssets()`.
    function setOracleResolvedVaultForOracleRouter(address _oracleRouter, address _vault, bool _allow) external onlyCollateralVaultFactoryOrOwner {
        EulerRouter(_oracleRouter).govSetResolvedVault(_vault, _allow);
        emit T_SetOracleResolvedVault(_oracleRouter, _vault, _allow);
    }

    /// @notice Perform an arbitrary external call. Governance-only.
    /// @dev VaultManager is an owner/admin of many contracts in the Twyne system.
    /// @dev This function helps Governance in case a specific a specific external function call was not implemented.
    function doCall(address to, uint value, bytes memory data) external payable onlyOwner {
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
