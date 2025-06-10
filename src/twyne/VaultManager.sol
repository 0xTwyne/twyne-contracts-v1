// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.28;

import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {IErrors} from "src/interfaces/IErrors.sol";
import {IEvents} from "src/interfaces/IEvents.sol";
import {RevertBytes} from "euler-vault-kit/EVault/shared/lib/RevertBytes.sol";
import {CollateralVaultBase} from "src/twyne/CollateralVaultBase.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";

/// @title IRMLinearKink
/// @notice To contact the team regarding security matters, visit https://twyne.xyz/security
/// @notice Manages twyne parameters that affect it globally: assets allowed, LTVs, interest rates.
/// To be owned by Twyne multisig.
contract VaultManager is Ownable, IErrors, IEvents {
    uint internal constant MAXFACTOR = 1e4;

    address public collateralVaultFactory;

    mapping(address collateralAddress => uint16 maxTwyneLiqLTV) public maxTwyneLTVs; // mapped to underlying asset in the collateral vault (can use intermediateVault for now)
    mapping(address collateralAddress => uint16 externalLiqBuffer) public externalLiqBuffers; // mapped to underlying asset in the collateral vault (can use intermediateVault for now)

    EulerRouter public oracleRouter;

    mapping(address collateralAddress => address intermediateVault) internal intermediateVaults;
    mapping(address intermediateVault => mapping(address targetVault => bool allowed)) public isAllowedTargetVault;

    mapping(address intermediateVault => address[] targetVaults) public allowedTargetVaultList;

    modifier onlyCollateralVaultFactoryOrOwner() {
        require(msg.sender == owner() || msg.sender == collateralVaultFactory, CallerNotOwnerOrCollateralVaultFactory());
        _;
    }

    constructor(address _owner, address _factory) Ownable(_owner) {
        collateralVaultFactory = _factory;
    }

    /// @notice Set oracleRouter address. Governance-only.
    function setOracleRouter(address _oracle) external onlyOwner {
        oracleRouter = EulerRouter(_oracle);
        emit T_SetOracleRouter(_oracle);
    }

    /// @notice Get a collateral vault's intermediate vault.
    /// @param _collateralAddress the collateral asset held by the intermediate vault.
    /// @return vault intermediate vault for the given _collateralAddress.
    function getIntermediateVault(address _collateralAddress) external view returns (address vault) {
        vault = intermediateVaults[_collateralAddress];
        require(vault != address(0), IntermediateVaultNotSet());
    }


    /// @notice Set a collateral vault's intermediate vault. Governance-only.
    /// @param _intermediateVault address of the intermediate vault.
    function setIntermediateVault(IEVault _intermediateVault) external onlyOwner {
        address creditAsset = _intermediateVault.asset();
        require(intermediateVaults[creditAsset] == address(0), IntermediateVaultAlreadySet());
        intermediateVaults[creditAsset] = address(_intermediateVault);
        emit T_SetIntermediateVault(address(_intermediateVault));
    }

    /// @notice Set an allowed target vault for a specific intermediate vault. Governance-only.
    /// @param _intermediateVault address of the intermediate vault.
    /// @param _targetVault The target vault that should be allowed for the intermediate vault.
    function setAllowedTargetVault(address _intermediateVault, address _targetVault) external onlyOwner {
        require(IEVault(_intermediateVault).unitOfAccount() == IEVault(_targetVault).unitOfAccount(), AssetMismatch());
        isAllowedTargetVault[_intermediateVault][_targetVault] = true;
        allowedTargetVaultList[_intermediateVault].push(_targetVault);
        emit T_AddAllowedTargetVault(_intermediateVault, _targetVault);
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

    /// @notice Set protocol-wide maxTwyneLiqLTV. Governance-only.
    /// @param _ltv new maxTwyneLiqLTV value.
    function setMaxLiquidationLTV(address _collateralAddress, uint16 _ltv) external onlyOwner {
        require(_ltv <= MAXFACTOR, ValueOutOfRange());
        maxTwyneLTVs[_collateralAddress] = _ltv;
        emit T_SetMaxLiqLTV(_collateralAddress, _ltv);
    }

    /// @notice Set protocol-wide externalLiqBuffer. Governance-only.
    /// @param _liqBuffer new externalLiqBuffer value.
    function setExternalLiqBuffer(address _collateralAddress, uint16 _liqBuffer) external onlyOwner {
        require(0 != _liqBuffer  && _liqBuffer <= MAXFACTOR, ValueOutOfRange());
        externalLiqBuffers[_collateralAddress] = _liqBuffer;
        emit T_SetExternalLiqBuffer(_collateralAddress, _liqBuffer);
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
        require(CollateralVaultBase(_collateralVault).asset() == _intermediateVault.asset(), AssetMismatch());
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

    /// @notice Perform an arbitrary external call. Governance-only.
    /// @dev VaultManager is an owner/admin of many contracts in the Twyne system.
    /// @dev This function helps Governance in case a specific a specific external function call was not implemented.
    function doCall(address to, uint value, bytes memory data) external payable onlyOwner {
        (bool success, bytes memory _data) = to.call{value: value}(data);
        if (!success) RevertBytes.revertBytes(_data);
        emit T_DoCall(to, value, data);
    }

    /// @notice Checks that the user-set LTV is within the min and max bounds.
    /// @param _liqLTV The LTV that the user wants to use for their collateral vault.
    /// @param _targetVault The target vault used for the borrow by collateral vault.
    /// @param _collateralAddress The collateral asset used by collateral vault.
    function checkLiqLTV(uint _liqLTV, address _targetVault, address _collateralAddress) external view {
        uint16 minLTV = IEVault(_targetVault).LTVLiquidation(_collateralAddress);
        require(uint(minLTV) * uint(externalLiqBuffers[_collateralAddress]) <= _liqLTV * MAXFACTOR && _liqLTV <= maxTwyneLTVs[_collateralAddress], ValueOutOfRange());
    }

    receive() external payable {}
}
