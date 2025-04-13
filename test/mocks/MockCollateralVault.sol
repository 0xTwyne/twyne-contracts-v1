// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.19;

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

    /// @param _asset address of vault asset
    /// @param _borrower address of vault owner
    /// @param _liqLTV user-specified target LTV
    /// @param _vaultManager VaultManager contract address
    function initialize(
        IERC20 _asset,
        address _borrower,
        uint _liqLTV,
        VaultManager _vaultManager
    ) external initializer override {
        __CollateralVaultBase_init(_asset, _borrower, _liqLTV, _vaultManager);

        eulerEVC.enableCollateral(address(this), address(_asset));
        eulerEVC.enableController(address(this), targetVault);
        SafeERC20.forceApprove(IERC20(targetAsset), targetVault, type(uint).max);
    }

    /// @notice Disables the controller.
    /// @dev The controller is only disabled if the account has no debt.
    /// @dev required by IVault inheritance of VaultBase
    function disableController() external override callThroughEVC { // diff
        revert("not implemented"); // diff, to test proxy upgrade
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

    /// @notice check whether internal accounting allows the vault to be rebalanced
    /// @dev reverts if not able to rebalance
    function _canRebalance() internal view override returns (uint excessCredit) {
        uint vaultAssets = totalAssetsDepositedOrReserved;
        uint userCollateral = vaultAssets - maxRelease();
        uint liqLTV_external = uint(IEVault(targetVault).LTVLiquidation(asset())) * uint(twyneVaultManager.externalLiqBuffer()); // 1e8 precision

        // rebalance() isn't protected by invariant check (no requireVaultStatusCheck in rebalance()).
        // Thus, we underestimate the excess credit to release so that after its release,
        // this vault doesn't have negative excess credit.
        uint maxVaultAssets = Math.ceilDiv(userCollateral * twyneLiqLTV * MAXFACTOR, liqLTV_external);

        require(vaultAssets > maxVaultAssets, CannotRebalance());
        unchecked { excessCredit = vaultAssets - maxVaultAssets; }
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
        address _asset = asset();
        address underlyingAsset = IEVault(_asset).asset();
        SafeERC20Lib.safeTransferFrom(IERC20_Euler(underlyingAsset), borrower, address(this), underlying, permit2);
        SafeERC20.forceApprove(IERC20(underlyingAsset), _asset, type(uint).max);

        return IEVault(_asset).deposit(underlying, address(this));
    }

    ///
    // Twyne Custom Liquidation Logic
    ///

    /// @notice perform checks to determine if this collateral vault is liquidatable
    function _canLiquidate() internal view override returns (bool) {
        // Liquidation scenario 1: If close to liquidation trigger of target asset protocol, liquidate on Twyne
        // How: Check if within some margin (say, 2%) of this liquidation point
        // Note: This method ignores the internal borrow, because Euler does not consider it at all

        // cache the debt owed to the targetVault
        (uint externalCollateralValueScaledByLiqLTV, uint externalBorrowDebtValue) = IEVault(targetVault).accountLiquidity(address(this), true);

        // externalCollateralValueScaledByLiqLTV is actual collateral value * externalLiquidationLTV, so it's lower than the real value
        if (externalBorrowDebtValue * MAXFACTOR > uint(twyneVaultManager.externalLiqBuffer()) * externalCollateralValueScaledByLiqLTV) {
            // note to avoid divide by zero case, don't divide by externalCollateralValueScaledByLiqLTV
            return true;
        }

        // Liquidation scenario 2: If combined debt from internal and external borrow is approaching the total credit
        // How: Cache the debt and credit values, convert all to the same currency, and check if they are within some
        // margin (say, 4%)
        // Note: EVK liquidation logic in the Twyne intermediate vault is blocked by BridgeHookTarget.sol fallback

        // Definitions of variables:
        // vaultOwnedCollateralAmount = total amount of assets held by the borrower's vault
        //   borrower owned collateral + intermediate vault borrowed principal
        // internalBorrowDebtAmount = debt owed from the borrower's vault to the intermediate vault
        //   intermediate vault borrowed principal + intermediate vault borrow interest
        // userOwnedCollateralAmount = vaultOwnedCollateralAmount - internalBorrowDebtAmount
        // userOwnedCollateralValue = userOwnedCollateralAmount converted to USD
        uint userCollateralValue = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(
            totalAssetsDepositedOrReserved - maxRelease(), asset(), IEVault(intermediateVault).unitOfAccount());

        // note to avoid divide by zero case, don't divide by borrowerOwnedCollateralValue
        return (externalBorrowDebtValue * MAXFACTOR > twyneLiqLTV * userCollateralValue);
    }

    /// @notice custom balanceOf implementation
    function balanceOf(address user) external view nonReentrantRO override returns (uint) {
        if (user != address(this) && user != borrower) return 0; // diff
        if (borrower == address(0)) return 0;

        uint _totalAssetsDepositedOrReserved = totalAssetsDepositedOrReserved;
        uint amount = IERC20(asset()).balanceOf(address(this));
        uint _maxRelease = maxRelease();

        // If this vault has been externally liquidated
        if (_totalAssetsDepositedOrReserved > amount) {
            (,uint releaseAmount,) = splitCollateralAfterExtLiq(amount, maxRepay(), _maxRelease);
            return releaseAmount;
        }

        return _totalAssetsDepositedOrReserved - _maxRelease;
    }

    /// @notice splits remaining collateral between liquidator, intermediate vault and borrow
    function splitCollateralAfterExtLiq(uint _collateralBalance, uint _maxRepay, uint _maxRelease) internal view returns (uint, uint, uint) {
        address _asset = asset();
        uint liquidatorReward;

        if (_maxRepay > 0) {
            liquidatorReward = EulerRouter(twyneVaultManager.oracleRouter()).getQuote(
                _maxRepay * MAXFACTOR / twyneVaultManager.maxTwyneLiqLTV(),
                targetAsset,
                IEVault(_asset).asset()
            );

            liquidatorReward = IEVault(_asset).convertToShares(liquidatorReward);
        }

        // TODO can this arithmetic revert?
        uint releaseAmount = Math.min(_collateralBalance - liquidatorReward, _maxRelease);
        uint borrowerClaim = _collateralBalance - releaseAmount - liquidatorReward;

        return (liquidatorReward, releaseAmount, borrowerClaim);
    }

    /// @notice to be called if the vault is liquidated by Euler
    function handleExternalLiquidation() external override callThroughEVC nonReentrant {
        createVaultSnapshot();
        address _asset = asset();
        uint amount = IERC20(_asset).balanceOf(address(this));
        require(totalAssetsDepositedOrReserved > amount, NotExternallyLiquidated());

        address liquidator = _msgSender();
        uint _maxRepay = maxRepay();

        (uint liquidatorReward, uint releaseAmount, uint borrowerClaim) = splitCollateralAfterExtLiq(amount, _maxRepay, maxRelease());

        if (_maxRepay > 0) {
            // step 1: repay all external debt
            SafeERC20Lib.safeTransferFrom(IERC20_Euler(targetAsset), liquidator, address(this), _maxRepay, permit2);
            IEVault(targetVault).repay(_maxRepay, address(this));

            // step 2: transfer collateral reward to liquidator
            SafeERC20Lib.safeTransfer(IERC20_Euler(_asset), liquidator, liquidatorReward);
        }

        if (borrowerClaim > 0) {
            // step 3: return some collateral to borrower
            SafeERC20Lib.safeTransfer(IERC20_Euler(_asset), borrower, borrowerClaim);
        }

        if (releaseAmount > 0) {
            // step 4: release remaining assets, socializing bad debt among credit LPs
            intermediateVault.repay(releaseAmount, address(this));
        }

        // reset the vault
        delete totalAssetsDepositedOrReserved;
        delete borrower;

        evc.requireVaultStatusCheck();
    }

    /// @notice Checks if the vault's current state maintains required invariants for safe operation
    /// @return bool Returns true if all invariants are maintained, false otherwise
    function _hasNonNegativeExcessCredit() internal view override returns (bool) {
        uint vaultAssets = totalAssetsDepositedOrReserved;
        uint userCollateral = vaultAssets - maxRelease();
        uint liqLTV_external = uint(IEVault(targetVault).LTVLiquidation(asset())) * uint(twyneVaultManager.externalLiqBuffer()); // 1e8

        return (vaultAssets * liqLTV_external >= userCollateral * twyneLiqLTV * MAXFACTOR);
    }

    /// @notice allow users of the underlying protocol to seamlessly transfer their position to this vault
    function teleport(uint toDeposit, uint toReserve, uint toBorrow) external override onlyBorrowerAndNotExtLiquidated whenNotPaused nonReentrant {
        createVaultSnapshot();

        totalAssetsDepositedOrReserved += toDeposit + toReserve;
        intermediateVault.borrow(toReserve, address(this));

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);
        items[0] = IEVC.BatchItem({
            targetContract: asset(),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeCall(IERC20.transferFrom, (borrower, address(this), toDeposit)) // needs allowance
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
            data: abi.encodeCall(IEVault(targetVault).repay, (toBorrow, borrower))
        });
        eulerEVC.batch(items);

        evc.requireAccountAndVaultStatusCheck(address(this));
    }
}
