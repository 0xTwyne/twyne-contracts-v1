// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.28;

import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {IErrors} from "src/interfaces/IErrors.sol";
import {RevertBytes} from "euler-vault-kit/EVault/shared/lib/RevertBytes.sol";
import {CollateralVaultBase} from "src/twyne/CollateralVaultBase.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";

/// @notice Manages twyne parameters that affect it globally: assets allowed, LTVs, interest rates.
/// To be owned by Twyne multisig.
contract VaultManager is Ownable, IErrors {
    uint internal constant MAXFACTOR = 1e4;

    address public collateralVaultFactory;

    uint16 public maxTwyneLiqLTV; // This is a protocol-wide parameter, not specific to a single asset
    uint16 public externalLiqBuffer; // This is a protocol-wide parameter, not specific to a single asset

    EulerRouter public oracleRouter;

    mapping(address credit => address intermediateVault) internal intermediateVaults;
    mapping(address intermediateVault => mapping(address targetVault => bool allowed)) public isAllowedTargetVault;

    mapping(address intermediateVault => address[] targetVaults) public allowedTargetVaultList;

    modifier onlyCollateralVaultFactoryOrOwner() {
        require(msg.sender == owner() || msg.sender == collateralVaultFactory, CallerNotOwnerOrCollateralVaultFactory());
        _;
    }

    constructor(address _owner, address _factory) Ownable(_owner) {
        collateralVaultFactory = _factory;
        externalLiqBuffer = uint16(MAXFACTOR); // avoids zero case with instant liquidation
    }

    /// @notice Set oracleRouter address. Governance-only.
    function setOracleRouter(address _oracle) external onlyOwner {
        oracleRouter = EulerRouter(_oracle);
    }

    /// @notice Get a collateral vault's intermediate vault.
    /// @param _asset the asset held by the intermediate vault.
    /// @return vault intermediate vault for the given _asset.
    function getIntermediateVault(address _asset) external view returns (address vault) {
        vault = intermediateVaults[_asset];
        require(vault != address(0), IntermediateVaultNotSet());
    }


    /// @notice Set a collateral vault's intermediate vault. Governance-only.
    /// @param _intermediateVault address of the intermediate vault.
    function setIntermediateVault(IEVault _intermediateVault) external onlyOwner {
        address creditAsset = _intermediateVault.asset();
        require(intermediateVaults[creditAsset] == address(0), IntermediateVaultAlreadySet());
        intermediateVaults[creditAsset] = address(_intermediateVault);
    }

    /// @notice Set an allowed target vault for a specific intermediate vault. Governance-only.
    /// @param _intermediateVault address of the intermediate vault.
    /// @param _targetVault The target vault that should be allowed for the intermediate vault.
    function setAllowedTargetVault(address _intermediateVault, address _targetVault) external onlyOwner {
        isAllowedTargetVault[_intermediateVault][_targetVault] = true;
        allowedTargetVaultList[_intermediateVault].push(_targetVault);
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
    }

    /// @notice Return the length of allowedTargetVaultList. Useful for frontend.
    function targetVaultLength(address _intermediateVault) external view returns (uint) {
        return allowedTargetVaultList[_intermediateVault].length;
    }

    /// @notice Set protocol-wide maxTwyneLiqLTV. Governance-only.
    /// @param _ltv new maxTwyneLiqLTV value.
    function setMaxLiquidationLTV(uint16 _ltv) external onlyOwner {
        require(_ltv <= MAXFACTOR, ValueOutOfRange());
        maxTwyneLiqLTV = _ltv;
    }

    /// @notice Set protocol-wide externalLiqBuffer. Governance-only.
    /// @param _liqBuffer new externalLiqBuffer value.
    function setExternalLiqBuffer(uint16 _liqBuffer) external onlyOwner {
        require(0 != _liqBuffer  && _liqBuffer <= MAXFACTOR, ValueOutOfRange());
        externalLiqBuffer = _liqBuffer;
    }

    /// @notice Set new collateralVaultFactory address. Governance-only.
    /// @param _factory new collateralVaultFactory address.
    function setCollateralVaultFactory(address _factory) external onlyOwner {
        collateralVaultFactory = _factory;
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
        require(CollateralVaultBase(_collateralVault).asset() == _intermediateVault.asset(), AssetMismatch());
        _intermediateVault.setLTV(_collateralVault, _borrowLimit, _liquidationLimit, _rampDuration);
    }

    /// @notice Set new oracleRouter resolved vault value. Callable by governance or collateral vault factory.
    /// @param _vault collateral vault address.
    /// @param _allow bool value to pass to govSetResolvedVault. True to configure the vault, false to clear the record.
    /// @dev called by createCollateralVault() when a new collateral vault is created so collateral can be price properly.
    /// @dev Configures the collateral vault to use internal pricing via `convertToAssets()`.
    function setOracleResolvedVault(address _vault, bool _allow) external onlyCollateralVaultFactoryOrOwner {
        oracleRouter.govSetResolvedVault(_vault, _allow);
    }

    /// @notice Perform an arbitrary external call. Governance-only.
    /// @dev VaultManager is an owner/admin of many contracts in the Twyne system.
    /// @dev This function helps Governance in case a specific a specific external function call was not implemented.
    function doCall(address to, uint value, bytes memory data) external payable onlyOwner {
        (bool success, bytes memory _data) = to.call{value: value}(data);
        if (!success) RevertBytes.revertBytes(_data);
    }

    /// @notice Checks that the user-set LTV is within the min and max bounds.
    /// @param _liqLTV The LTV that the user wants to use for their collateral vault.
    /// @param _targetVault The target vault used for the borrow by collateral vault.
    /// @param _collateralAddress The collateral asset used by collateral vault.
    /// @return isAllowedLTV bool indicating whether the user-set LTV is within proper bounds.
    function checkLiqLTV(uint _liqLTV, address _targetVault, address _collateralAddress) public view returns (bool isAllowedLTV) {
        uint16 minLTV = IEVault(_targetVault).LTVLiquidation(_collateralAddress);
        require(uint(minLTV) * uint(externalLiqBuffer) <= _liqLTV * MAXFACTOR && _liqLTV <= maxTwyneLiqLTV, ValueOutOfRange());
        return true;
    }

    /// @notice Checks that the user-set LTV is within the min and max bounds.
    /// @param _liqLTV The LTV that the user wants to use for their collateral vault.
    /// @return isAllowedLTV bool indicating whether the user-set LTV is within proper bounds.
    /// @dev Can be called only by collateral vaults.
    function checkLiqLTVByCollateralVault(uint _liqLTV) external view returns (bool isAllowedLTV) {
        require(CollateralVaultFactory(collateralVaultFactory).isCollateralVault(msg.sender), NotCollateralVault());
        // Twyne assumes single target asset per target vault.
        address _targetVault = CollateralVaultBase(msg.sender).targetVault();
        address _collateralAddress = CollateralVaultBase(msg.sender).asset();

        return checkLiqLTV(_liqLTV, _targetVault, _collateralAddress);
    }

    receive() external payable {}
}
