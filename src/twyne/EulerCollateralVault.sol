// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.28;

import {CollateralVaultBase} from "src/twyne/CollateralVaultBase.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {SafeERC20Lib, IERC20 as IERC20_Euler} from "euler-vault-kit/EVault/shared/lib/SafeERC20Lib.sol";
import {SafeERC20, IERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";

/// @title EulerCollateralVault
/// @notice To contact the team regarding security matters, visit https://twyne.xyz/security
/// @dev Provides integration logic for Euler Finance as external protocol.
/// @notice In this contract, the EVC is authenticated before any action that may affect the state of the vault or an
/// account. This is done to ensure that if it's EVC calling, the account is correctly authorized.
contract EulerCollateralVault is CollateralVaultBase {
    address public immutable targetAsset; // Euler targetVault only supports 1 asset, so store it as immutable
    IEVC public immutable eulerEVC;

    uint[50] private __gap;

    /// @param _evc address of EVC deployed by Twyne
    /// @param _targetVault address of the target vault to borrow from in Euler
    constructor(address _evc, address _targetVault) CollateralVaultBase(_evc, _targetVault) {
        targetAsset = IEVault(targetVault).asset();
        eulerEVC = IEVC(IEVault(targetVault).EVC());
        _disableInitializers();
    }

    /// @param __asset address of vault asset
    /// @param __borrower address of vault owner
    /// @param __liqLTV user-specified target LTV
    /// @param __vaultManager VaultManager contract address
    function initialize(
        IERC20 __asset,
        address __borrower,
        uint __liqLTV,
        VaultManager __vaultManager
    ) external initializer {
        __CollateralVaultBase_init(__asset, __borrower, __liqLTV, __vaultManager);

        eulerEVC.enableCollateral(address(this), address(__asset)); // necessary for Euler Finance EVK borrowing
        eulerEVC.enableController(address(this), targetVault); // necessary for Euler Finance EVK borrowing
        SafeERC20.forceApprove(IERC20(targetAsset), targetVault, type(uint).max); // necessary for repay()
        SafeERC20.forceApprove(IERC20(IEVault(address(__asset)).asset()), address(__asset), type(uint).max); // necessary for _depositUnderlying()
        emit T_CollateralVaultInitialized();
    }

    /// @dev increment the version for proxy upgrades
    function version() external override pure returns (uint) {
        return 2;
    }

    /// @notice Returns Euler's liquidation LTV for the given collateral asset
    /// @param _asset The collateral asset address
    /// @return uint The liquidation LTV in 1e4 precision
    function _getExtLiqLTV(address _asset) internal view override returns (uint) {
        return IEVault(targetVault).LTVLiquidation(_asset);
    }

    /// @notice Validates that the provided liqLTV is within acceptable bounds for Euler
    /// @dev Ensures: eulerLiqLTV * buffer <= liqLTV * MAXFACTOR && liqLTV <= maxLTV
    /// @param _liqLTV The liquidation LTV to validate (in 1e4 precision)
    /// @param _asset The collateral asset address (used to fetch buffer, maxLTV, and Euler's LTV)
    function _checkLiqLTV(uint _liqLTV, address _asset) internal view override {
        uint buffer = uint(twyneVaultManager.externalLiqBuffers(_asset));
        uint maxLTV = uint(twyneVaultManager.maxTwyneLTVs(_asset));
        require(_getExtLiqLTV(_asset) * buffer <= _liqLTV * MAXFACTOR && _liqLTV <= maxLTV, ValueOutOfRange());
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
        } else if (vaultAssets < __invariantCollateralAmount) {
            totalAssetsDepositedOrReserved = vaultAssets + intermediateVault.borrow(__invariantCollateralAmount - vaultAssets, address(this));
        }
    }

    /// @notice Calculates the collateral assets that should be held by the collateral vault to comply with invariants
    /// @return uint Returns the amount of collateral assets that the collateral vault should hold with zero excess credit
    function _invariantCollateralAmount() internal view override returns (uint) {
        uint userCollateral = totalAssetsDepositedOrReserved - maxRelease();
        uint liqLTV_external = uint(IEVault(targetVault).LTVLiquidation(asset())) * uint(twyneVaultManager.externalLiqBuffers(asset())); // 1e8 precision

        return Math.ceilDiv(userCollateral * twyneLiqLTV * MAXFACTOR, liqLTV_external);
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

    /// @notice Returns debt (B) and user collateral (C) in the intermediate vault's unit of account
    /// @dev B = external borrow debt value from Euler's accountLiquidity
    /// @dev C = user-owned collateral converted to unit of account via EulerRouter oracle
    /// @return B The total debt value in unit of account
    /// @return C The user-owned collateral value in unit of account
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

        // externalCollateralValueScaledByLiqLTV is actual collateral value * externalLiquidationLTV, so it's lower than the real value
        if (externalBorrowDebtValue * MAXFACTOR > uint(twyneVaultManager.externalLiqBuffers(__asset)) * externalCollateralValueScaledByLiqLTV) {
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
            totalAssetsDepositedOrReserved - maxRelease(), __asset, IEVault(intermediateVault).unitOfAccount());

        // note to avoid divide by zero case, don't divide by borrowerOwnedCollateralValue
        return (externalBorrowDebtValue * MAXFACTOR > twyneLiqLTV * userCollateralValue);
    }

    /// @notice Converts collateral value from unit of account to native collateral asset units
    /// @dev Uses EulerRouter oracle to convert from unit of account to underlying, then to shares
    /// @dev Returns the minimum of calculated amount and user-owned collateral
    /// @param collateralValue The collateral value in unit of account
    /// @return collateralAmount The collateral amount in wrapper shares
    function _convertBaseToCollateral(uint collateralValue) internal view virtual override returns (uint collateralAmount) {
        collateralAmount = twyneVaultManager.oracleRouter().getQuote(
                collateralValue,
                IEVault(intermediateVault).unitOfAccount(),
                IEVault(asset()).asset()
            );
        return Math.min(totalAssetsDepositedOrReserved - maxRelease(), IEVault(asset()).convertToShares(collateralAmount));
    }

    /// @notice custom balanceOf implementation
    /// @dev returns 0 on external liquidation, because:
    /// handleExternalLiquidation() sets this vault's collateral balance to 0, balanceOf is then
    /// called by the intermediate vault when someone settles the remaining bad debt.
    function balanceOf(address user) external view nonReentrantView override returns (uint) {
        if (user != address(this)) return 0;
        if (borrower == address(0)) return 0;

        uint _totalAssetsDepositedOrReserved = totalAssetsDepositedOrReserved;
        // return 0 if externally liquidated
        if (_totalAssetsDepositedOrReserved > IERC20(asset()).balanceOf(address(this))) return 0;

        return _totalAssetsDepositedOrReserved - maxRelease();
    }

    /// @notice Splits remaining collateral after external liquidation (whitepaper Section 6.3.1)
    /// @dev After external protocol liquidates the position, remaining collateral is split three ways:
    ///
    /// 1. C_LP (releaseAmount) → returned to intermediate vault for CLP (credit liquidity provider)
    /// 2. borrowerClaim → returned to borrower based on dynamic incentive model
    /// 3. liquidatorReward → goes to liquidator as compensation for handling the liquidation
    ///
    /// The split follows these steps:
    /// Step 1: Calculate user collateral = B_ext / λ̃^max_t (debt at max Twyne LTV)
    ///   - This is the minimum collateral needed to cover the external debt at maximum LTV
    ///   - Capped by actual remaining collateral balance
    ///
    /// Step 2: Calculate C_LP = min(remaining collateral after user portion, maxRelease)
    ///   - CLP gets back their reserved portion, up to what's available
    ///
    /// Step 3: Remaining collateral (C_new = balance - C_LP) is split between borrower and liquidator
    ///   - Uses collateralForBorrower(B, C_new) which applies dynamic incentive i(λ_t)
    ///   - Liquidator gets: C_new - borrowerClaim
    ///
    /// @param _collateralBalance Total remaining collateral after external liquidation
    /// @param _maxRepay Maximum debt that can be repaid (B_ext in target asset units)
    /// @param _maxRelease Maximum collateral that can be released to CLP
    /// @return liquidatorReward Collateral going to liquidator
    /// @return releaseAmount Collateral returning to intermediate vault (C_LP)
    /// @return borrowerClaim Collateral returning to borrower
    function splitCollateralAfterExtLiq(uint _collateralBalance, uint _maxRepay, uint _maxRelease) internal view returns (uint, uint, uint) {
        address __asset = asset();

        if (_maxRepay == 0) {
            uint _releaseAmount = Math.min(_collateralBalance, _maxRelease);
            uint _borrowerClaim = _collateralBalance - _releaseAmount;
            return (0, _releaseAmount, _borrowerClaim);
        }

        // Step 1: Calculate user's portion of collateral (C_temp)
        // userCollateral = B_ext / λ̃^max_t (converted to collateral asset units)
        // This represents the collateral value needed to cover debt at max Twyne LTV
        // Convert _maxRepay / maxTwyneLTV from targetAsset to collateral underlying
        EulerRouter oracle = twyneVaultManager.oracleRouter();
        uint userCollateral = oracle.getQuote(
            _maxRepay * MAXFACTOR / twyneVaultManager.maxTwyneLTVs(__asset),
            targetAsset,
            IEVault(__asset).asset()
        );

        // Convert to collateral and cap by available balance
        userCollateral = Math.min(_collateralBalance, IEVault(__asset).convertToShares(userCollateral));

        // Step 2: Calculate CLP gets min(C_left - C_temp, C_LP^old)
        // This is the amount intermediate vault gets back
        uint releaseAmount = Math.min(_collateralBalance - userCollateral, _maxRelease);

        // Step 3: Calculate C_new which is C_left - CLP.
        // Collateral to be split between borrower and liquidator
        userCollateral = _collateralBalance - releaseAmount;

        // Step 3: Split userCollateral between borrower and liquidator using dynamic incentive
        // Calculate userCollateral in USD
        uint C_new = oracle.getQuote(
                userCollateral,
                __asset,
                IEVault(__asset).unitOfAccount()
            );

        // borrow amount in USD
        (, uint B) = IEVault(targetVault).accountLiquidity(address(this), true);

        // Apply dynamic incentive model: borrower gets collateralForBorrower(B, C_new)
        // Liquidator gets the remainder as reward for handling external liquidation
        uint borrowerClaim = collateralForBorrower(B, C_new);
        uint liquidatorReward = userCollateral - borrowerClaim;

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
