// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.28;

import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {CollateralVaultBase, SafeERC20, IERC20} from "src/twyne/CollateralVaultBase.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {SafeERC20Lib, IERC20 as IERC20_Euler} from "euler-vault-kit/EVault/shared/lib/SafeERC20Lib.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";

/// @title CollateralVault
/// @dev Provides integration logic for Euler Finance as external protocol.
/// @notice In this contract, the EVC is authenticated before any action that may affect the state of the vault or an
/// account. This is done to ensure that if it's EVC calling, the account is correctly authorized.
contract MockCollateralVault is CollateralVaultBase {
    address public immutable targetAsset; // Euler targetVault only supports 1 asset, so store it as immutable
    IEVC public immutable eulerEVC;

    uint public immutable immutableValue; // diff
    uint public newValue; // diff
    uint[49] private __gap; // diff

    /// @param _evc address of EVC deployed by Twyne
    /// @param _targetVault address of the target vault to borrow from in Euler
    constructor(address _evc, address _targetVault, uint _newValue) CollateralVaultBase(_evc, _targetVault) { // diff
        targetAsset = IEVault(targetVault).asset();
        eulerEVC = IEVC(IEVault(targetVault).EVC());
        newValue = _newValue; // diff
        immutableValue = 333; // diff
        _disableInitializers();
    }

    /// @param __intermediateVault address of the intermediate vault
    /// @param __borrower address of vault owner
    /// @param __liqLTV user-specified target LTV
    /// @param __vaultManager VaultManager contract address
    function initialize(
        address __intermediateVault,
        address __borrower,
        uint __liqLTV,
        VaultManager __vaultManager
    ) external initializer {
        __CollateralVaultBase_init(__intermediateVault, __borrower, __liqLTV, __vaultManager);
        address __asset = asset();

        eulerEVC.enableCollateral(address(this), __asset); // necessary for Euler Finance EVK borrowing
        eulerEVC.enableController(address(this), targetVault); // necessary for Euler Finance EVK borrowing
        SafeERC20.forceApprove(IERC20(targetAsset), targetVault, type(uint).max); // necessary for repay()
        SafeERC20.forceApprove(IERC20(IEVault(__asset).asset()), __asset, type(uint).max); // necessary for _depositUnderlying()
        emit T_CollateralVaultInitialized();
    }

    function _getExtLiqLTV() internal view override returns (uint) {
        return IEVault(targetVault).LTVLiquidation(asset());
    }

    /// @dev increment the version for proxy upgrades
    function version() external override pure returns (uint) {
        return 909; // diff
    }

    // diff
    function setNewValue(uint _newValue) external onlyBorrowerAndNotExtLiquidated nonReentrant {
        newValue = _newValue;
    }

    ///
    // Functions defined in CollateralVaultBase requiring custom implementations
    ///

    /// @notice returns the maximum assets that can be repaid to Euler target vault
    function maxRepay() public view override returns (uint) {
        // debtOfExact() isn't used here since it is a scaled value.
        // See test_basicLiquidation_all_collateral() which asserts maxRepay value matches debtOf() value.
        return IEVault(targetVault).debtOf(address(this));
    }

    /// @notice adjust credit reserved from intermediate vault
    function _handleExcessCredit(uint __invariantCollateralAmount) internal override {
        uint vaultAssets = totalAssetsDepositedOrReserved;
        if (vaultAssets > __invariantCollateralAmount) {
            totalAssetsDepositedOrReserved = vaultAssets - intermediateVault.repay(vaultAssets - __invariantCollateralAmount, address(this));
        } else {
            totalAssetsDepositedOrReserved = vaultAssets + intermediateVault.borrow(__invariantCollateralAmount - vaultAssets, address(this));
        }
    }

    /// @notice Calculates the collateral assets that should be held by the collateral vault to comply with invariants
    /// @return uint Returns the amount of collateral assets that the collateral vault should hold with zero excess credit
    function _invariantCollateralAmount() internal view override returns (uint) {
        address __asset = asset();
        // adjExtLiqLTV = β_safe · λ̃_e (1e8 precision)
        uint adjExtLiqLTV = uint(twyneVaultManager.externalLiqBuffers(address(intermediateVault))) * uint(IEVault(targetVault).LTVLiquidation(__asset));
        // When dynamic leg is selected: ceilDiv(adjExtLiqLTV * X, adjExtLiqLTV) = X (exact, no rounding)
        // When chosen leg is selected: rounds up, which is conservative (reserves more collateral)
        return Math.ceilDiv(_collateralScaledByLiqLTV1e8(true, adjExtLiqLTV), adjExtLiqLTV);
    }

    /// @notice borrows target assets from Euler
    function _borrow(uint _targetAmount, address _receiver)
        internal
        override
    {
        IEVault(targetVault).borrow(_targetAmount, _receiver);
    }

    /// @notice sends borrowed target assets to Euler
    function _repay(uint _amount) internal override {
        SafeERC20Lib.safeTransferFrom(IERC20_Euler(targetAsset), borrower, address(this), _amount, permit2);
        IEVault(targetVault).repay(_amount, address(this));
    }

    /// @notice First receives the unwrapped token from the borrower, then sends borrowed target assets to Euler
    function _depositUnderlying(uint underlying) internal override returns (uint) {
        address __asset = asset();
        address underlyingAsset = IEVault(__asset).asset();
        SafeERC20Lib.safeTransferFrom(IERC20_Euler(underlyingAsset), borrower, address(this), underlying, permit2);

        return IEVault(__asset).deposit(underlying, address(this));
    }

    ///
    // Twyne Custom Liquidation Logic
    ///

    function _getBC() internal view override returns (uint, uint) {
        (, uint externalBorrowDebtValue) = IEVault(targetVault).accountLiquidity(address(this), true);

        uint userCollateralValue = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(
            totalAssetsDepositedOrReserved - maxRelease(), asset(), IEVault(intermediateVault).unitOfAccount());

        return (externalBorrowDebtValue, userCollateralValue);
    }

    /// @notice perform checks to determine if this collateral vault is liquidatable
    function _canLiquidate() internal view override returns (bool) {
        // Liquidation scenario 1: If close to liquidation trigger of target asset protocol, liquidate on Twyne
        // How: Check if within some margin (say, 2%) of this liquidation point
        // Note: This method ignores the internal borrow, because Euler does not consider it at all

        address __asset = asset();
        // cache the debt owed to the targetVault
        (uint externalCollateralValueScaledByLiqLTV, uint externalBorrowDebtValue) = IEVault(targetVault).accountLiquidity(address(this), true);

        uint buffer = uint(twyneVaultManager.externalLiqBuffers(address(intermediateVault)));
        // externalCollateralValueScaledByLiqLTV is actual collateral value * externalLiquidationLTV, so it's lower than the real value
        if (externalBorrowDebtValue * MAXFACTOR > buffer * externalCollateralValueScaledByLiqLTV) {
            // note to avoid divide by zero case, don't divide by externalCollateralValueScaledByLiqLTV
            return true;
        }

        // Liquidation scenario 2: If combined debt from internal and external borrow is approaching the total credit
        // How: Cache the debt and credit values, convert all to the same currency, and check if they are within some
        // margin (say, 4%)
        // Note: EVK liquidation logic in the Twyne intermediate vault is blocked by BridgeHookTarget.sol fallback

        // collateralValueScaledByLiqLTV = C · λ̃_t converted to unit of account (1e8 precision on LTV)
        uint adjExtLiqLTV = buffer * uint(IEVault(targetVault).LTVLiquidation(__asset));
        uint collateralValueScaledByLiqLTV = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(
            _collateralScaledByLiqLTV1e8(false, adjExtLiqLTV), __asset, IEVault(intermediateVault).unitOfAccount());

        // note to avoid divide by zero case, don't divide by borrowerOwnedCollateralValue
        return (externalBorrowDebtValue * MAXFACTOR * MAXFACTOR > collateralValueScaledByLiqLTV);
    }

    function _convertBaseToCollateral(uint collateralValue) internal view virtual override returns (uint collateralAmount) {
        collateralAmount = twyneVaultManager.oracleRouter().getQuote(
                collateralValue,
                IEVault(intermediateVault).unitOfAccount(),
                asset()
            );
        return Math.min(totalAssetsDepositedOrReserved - maxRelease(), collateralAmount);
    }

    /// @notice custom balanceOf implementation
    /// @dev returns 0 on external liquidation, because:
    /// handleExternalLiquidation() sets this vault's collateral balance to 0, balanceOf is then
    /// called by the intermediate vault when someone settles the remaining bad debt.
    function balanceOf(address user) external view nonReentrantView override returns (uint) {
        if (user != address(this) && user != borrower) return 0; // diff
        if (borrower == address(0)) return 0;

        uint _totalAssetsDepositedOrReserved = totalAssetsDepositedOrReserved;
        // return 0 if externally liquidated
        if (_totalAssetsDepositedOrReserved > IERC20(asset()).balanceOf(address(this))) return 0;

        return _totalAssetsDepositedOrReserved - maxRelease();
    }

    /// @notice splits remaining collateral between liquidator, intermediate vault and borrow
    function splitCollateralAfterExtLiq(uint _collateralBalance, uint _maxRepay, uint _maxRelease) internal view returns (uint, uint, uint) {
        address __asset = asset();
        uint liquidatorReward;

        if (_maxRepay > 0) {
            liquidatorReward = twyneVaultManager.oracleRouter().getQuote(
                _maxRepay * MAXFACTOR / twyneVaultManager.maxTwyneLTVs(address(intermediateVault)),
                targetAsset,
                IEVault(__asset).asset()
            );

            liquidatorReward = Math.min(_collateralBalance, IEVault(__asset).convertToShares(liquidatorReward));
        }

        uint releaseAmount = Math.min(_collateralBalance - liquidatorReward, _maxRelease);
        uint borrowerClaim = _collateralBalance - releaseAmount - liquidatorReward;

        return (liquidatorReward, releaseAmount, borrowerClaim);
    }

    /// @notice to be called if the vault is liquidated by Euler
    function handleExternalLiquidation() external override callThroughEVC nonReentrant {
        createVaultSnapshot();
        address __asset = asset();
        uint amount = IERC20(__asset).balanceOf(address(this));
        require(totalAssetsDepositedOrReserved > amount, NotExternallyLiquidated());

        {
            (uint externalCollateralValueScaledByLiqLTV, uint externalBorrowDebtValue) = IEVault(targetVault).accountLiquidity(address(this), true);
            // Equality is needed for the complete liquidation case (entire debt and collateral is taken by Euler liquidator)
            require(externalCollateralValueScaledByLiqLTV >= externalBorrowDebtValue, ExternalPositionUnhealthy());
        }

        uint _maxRelease = maxRelease();
        address liquidator = _msgSender();

        if (_maxRelease == 0) {
            require(liquidator == borrower, NoLiquidationForZeroReserve());
        }

        uint _maxRepay = maxRepay();

        (uint liquidatorReward, uint releaseAmount, uint borrowerClaim) = splitCollateralAfterExtLiq(amount, _maxRepay, _maxRelease);

        if (_maxRepay > 0) {
            // step 1: repay all external debt
            SafeERC20Lib.safeTransferFrom(IERC20_Euler(targetAsset), liquidator, address(this), _maxRepay, permit2);
            IEVault(targetVault).repay(_maxRepay, address(this));

            // step 2: transfer collateral reward to liquidator
            SafeERC20Lib.safeTransfer(IERC20_Euler(__asset), liquidator, liquidatorReward);
        }

        if (borrowerClaim > 0) {
            // step 3: return some collateral to borrower
            SafeERC20Lib.safeTransfer(IERC20_Euler(__asset), borrower, borrowerClaim);
        }

        if (releaseAmount > 0) {
            // step 4: release remaining assets. Any non-zero bad debt left after this
            // needs to be socialized via intermediateVault.liquidate in the same batch.
            intermediateVault.repay(releaseAmount, address(this));
        }

        // reset the vault
        delete totalAssetsDepositedOrReserved;
        delete borrower;

        evc.requireVaultStatusCheck();
        emit T_HandleExternalLiquidation();
    }

    /// @notice allow users of the underlying protocol to seamlessly transfer their position to this vault
    function teleport(uint toDeposit, uint toBorrow, uint8 subAccountId) external onlyBorrowerAndNotExtLiquidated whenNotPaused nonReentrant {
        createVaultSnapshot();

        totalAssetsDepositedOrReserved += toDeposit;
        _handleExcessCredit(_invariantCollateralAmount());

        address subAccount = address(uint160(uint160(borrower) ^ subAccountId));

        if (toBorrow == type(uint).max) {
            toBorrow = IEVault(targetVault).debtOf(subAccount);
        }

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);
        items[0] = IEVC.BatchItem({
            targetContract: asset(),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeCall(IERC20.transferFrom, (subAccount, address(this), toDeposit)) // needs allowance
        });
        items[1] = IEVC.BatchItem({
            targetContract: targetVault,
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeCall(IEVault(targetVault).borrow, (toBorrow, address(this)))
        });
        items[2] = IEVC.BatchItem({
            targetContract: targetVault,
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeCall(IEVault(targetVault).repay, (toBorrow, subAccount))
        });
        eulerEVC.batch(items);

        evc.requireAccountAndVaultStatusCheck(address(this));
        emit T_Teleport(toDeposit, toBorrow);
    }
}
