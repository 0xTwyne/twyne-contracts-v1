// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.28;

import {CollateralVaultBase} from "src/twyne/CollateralVaultBase.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {IVariableDebtToken as IAaveV3DebtToken} from "aave-v3/interfaces/IVariableDebtToken.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";
import {IRewardsController} from "aave-v3/rewards/interfaces/IRewardsController.sol";
import {IPool as IAaveV3Pool, DataTypes as AaveV3DataTypes} from "aave-v3/interfaces/IPool.sol";
import {IPoolDataProvider as IAaveV3DataProvider} from "aave-v3/interfaces/IPoolDataProvider.sol";
import {IPoolAddressesProvider as IAaveV3AddressProvider} from "aave-v3/interfaces/IPoolAddressesProvider.sol";
import {EModeConfiguration} from "aave-v3/protocol/libraries/configuration/EModeConfiguration.sol";
import {IPriceOracle as IAaveV3PriceOracle} from "aave-v3/interfaces/IPriceOracle.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {IAaveV3ATokenWrapper} from "src/interfaces/IAaveV3ATokenWrapper.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {SafeERC20Lib, IERC20 as IERC20_Euler} from "euler-vault-kit/EVault/shared/lib/SafeERC20Lib.sol";
import {SafeERC20, IERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";

/// @title AaveV3CollateralVault
/// @notice To contact the team regarding security matters, visit https://twyne.xyz/security
/// @dev Provides integration logic for Aave V3 as external protocol.
/// @notice In this contract, the EVC is authenticated before any action that may affect the state of the vault or an
/// account. This is done to ensure that if it's EVC calling, the account is correctly authorized.
contract AaveV3CollateralVault is CollateralVaultBase {
    using SafeERC20 for IERC20;

    IAaveV3DataProvider public immutable aaveDataProvider;

    IRewardsController public immutable INCENTIVES_CONTROLLER;

    address public targetAsset; // like USDC
    address public aaveDebtToken; // like vUSDC
    address public aToken; // like aWETH
    address public underlyingAsset; // like WETH
    // Category ID for e-mode on Aave V3
    uint8 public categoryId;
    uint public tenPowAssetDecimals;
    uint public tenPowVAssetDecimals;

    uint[50] private __gap;

    /// @param _evc address of EVC deployed by Twyne
    /// @param _aavePool address of Aave v3 Pool
    constructor(address _evc, address _aavePool, address _incentiveController) CollateralVaultBase(_evc, _aavePool) {
        aaveDataProvider = IAaveV3DataProvider(IAaveV3AddressProvider(IAaveV3Pool(_aavePool).ADDRESSES_PROVIDER()).getPoolDataProvider());
        INCENTIVES_CONTROLLER = IRewardsController(_incentiveController);
        _disableInitializers();
    }

    /// @param __asset address of vault asset (AaveV3AToken wrapper shares)
    /// @param __borrower address of vault owner
    /// @param __liqLTV user-specified target LTV
    /// @param __vaultManager VaultManager contract address
    /// @param __targetAsset Target asset to borrow
    /// @param __categoryId Category ID for e-mode on Aave
    function initialize(
        IERC20 __asset,
        address __borrower,
        uint __liqLTV,
        VaultManager __vaultManager,
        address __targetAsset,
        uint8 __categoryId
    ) external initializer {
        // categoryId and underlyingAsset are used in _checkLiqLTV
        categoryId = __categoryId;
        address _underlyingAsset = IAaveV3ATokenWrapper(address(__asset)).asset();
        underlyingAsset = _underlyingAsset;

        __CollateralVaultBase_init(__asset, __borrower, __liqLTV, __vaultManager);

        (,,address debtToken) = aaveDataProvider.getReserveTokensAddresses(__targetAsset);
        targetAsset = __targetAsset;
        IAaveV3Pool(targetVault).setUserEMode(__categoryId);
        aaveDebtToken = debtToken;
        SafeERC20.forceApprove(IERC20(__targetAsset), address(targetVault), type(uint).max); // necessary for repay()
        // necessary for depositUnderlying
        SafeERC20.forceApprove(IERC20(_underlyingAsset), address(__asset), type(uint256).max);

        address _aToken = IAaveV3ATokenWrapper(address(__asset)).aToken();
        // necessary for wrapper.rebalanceATokens_CV()
        SafeERC20.forceApprove(IERC20(_aToken), address(__asset), type(uint256).max);
        aToken = _aToken;
        tenPowAssetDecimals = 10 ** uint(IAaveV3ATokenWrapper(address(__asset)).decimals());
        tenPowVAssetDecimals = 10 ** uint(IERC20_Euler(aaveDebtToken).decimals());
        emit T_CollateralVaultInitialized();
    }

    function _isNotExternallyLiquidated() internal view virtual override returns (bool) {
        return totalAssetsDepositedOrReserved <= IAToken(aToken).scaledBalanceOf(address(this));
    }

    /// @dev increment the version for proxy upgrades
    function version() external override pure returns (uint) {
        return 1;
    }

    /// @notice Returns Aave's liquidation threshold for the underlying asset
    /// @dev For eMode (categoryId != 0): checks if asset is in collateral bitmap, returns eMode LT or reserve LT accordingly
    /// @dev For non-eMode (categoryId == 0): returns the reserve's liquidation threshold directly
    /// @return uint The liquidation threshold in 1e4 precision
    function _getExtLiqLTV(address) internal view override returns (uint) {
        if (categoryId != 0) {
            // This is to ensure if emode is disabled we are taking correct liq ltv
            // Below code is taken from https://github.com/aave-dao/aave-v3-origin/blob/f53f03cf95ea5c3528016e849bf98210abdd5bcb/src/contracts/protocol/libraries/logic/GenericLogic.sol#L67
            uint reserveId = IAaveV3Pool(targetVault).getReserveData(underlyingAsset).id;
            uint128 collateralBitmap = IAaveV3Pool(targetVault).getEModeCategoryCollateralBitmap(categoryId);

            if (EModeConfiguration.isReserveEnabledOnBitmap(collateralBitmap, reserveId)) {
                return IAaveV3Pool(targetVault).getEModeCategoryCollateralConfig(categoryId).liquidationThreshold;
            }
        }

        (,,uint currentLiquidationThreshold,,,,,,,) = aaveDataProvider.getReserveConfigurationData(underlyingAsset);
        return currentLiquidationThreshold;
    }

    /// @notice Validates that the provided liqLTV is within acceptable bounds for Aave
    /// @dev Ensures: aaveLiqLTV * buffer <= liqLTV * MAXFACTOR && liqLTV <= maxLTV
    /// @param _liqLTV The liquidation LTV to validate (in 1e4 precision)
    /// @param _asset The collateral asset address (used to fetch buffer and maxLTV from VaultManager)
    function _checkLiqLTV(uint _liqLTV, address _asset) internal view override {
        uint buffer = uint(twyneVaultManager.externalLiqBuffers(_asset));
        uint maxLTV = uint(twyneVaultManager.maxTwyneLTVs(_asset));
        require(_getExtLiqLTV(address(0)) * buffer <= _liqLTV * MAXFACTOR && _liqLTV <= maxLTV, ValueOutOfRange());
    }

    /// @notice returns the maximum assets that can be repaid to Aave
    function maxRepay() public view override returns (uint) {
        return IERC20(aaveDebtToken).balanceOf(address(this));
    }

    /// @notice adjust credit reserved from intermediate vault
    function _handleExcessCredit(uint __invariantCollateralAmount) internal override {
        uint vaultAssets = totalAssetsDepositedOrReserved;
        if (vaultAssets > __invariantCollateralAmount) {
            vaultAssets -= intermediateVault.repay(vaultAssets - __invariantCollateralAmount, address(this));
        } else if (vaultAssets < __invariantCollateralAmount) {
            vaultAssets += intermediateVault.borrow(__invariantCollateralAmount - vaultAssets, address(this));
        }

        IAaveV3ATokenWrapper(asset()).rebalanceATokens_CV(vaultAssets);
        totalAssetsDepositedOrReserved = vaultAssets;
    }

    /// @notice Calculates the collateral assets that should be held by the collateral vault to comply with invariants
    /// @return uint Returns the amount of collateral assets that the collateral vault should hold with zero excess credit
    function _invariantCollateralAmount() internal view override returns (uint) {
        uint userCollateral = totalAssetsDepositedOrReserved - maxRelease();

        uint liqLTV_external = _getExtLiqLTV(address(0)) * uint(twyneVaultManager.externalLiqBuffers(asset())); // 1e8 precision
        return Math.ceilDiv(userCollateral * twyneLiqLTV * MAXFACTOR, liqLTV_external);
    }

    /// @dev collateral vault borrows targetAsset from underlying protocol.
    /// Implementation should make sure targetAsset is whitelisted.
    function _borrow(uint _targetAmount, address _receiver) internal virtual override {
        address _targetVault = targetVault;

        // Enable collateral on Aave. This is needed whenever atoken balance goes from 0 to non-zero but for simplicity we call it everytime before borrow.
        IAaveV3Pool(_targetVault).setUserUseReserveAsCollateral(underlyingAsset, true);

        address _targetAsset = targetAsset;
        IAaveV3Pool(_targetVault).borrow(_targetAsset, _targetAmount, 2, 0, address(this));
        IERC20(_targetAsset).safeTransfer(_receiver, _targetAmount);
    }

    /// @dev Implementation should make sure the correct targetAsset is repaid and the repay action is successful.
    /// Revert otherwise.
    function _repay(uint _targetAmount) internal virtual override {
        SafeERC20Lib.safeTransferFrom(IERC20_Euler(targetAsset), borrower, address(this), _targetAmount, permit2);
        IAaveV3Pool(targetVault).repay(targetAsset, _targetAmount, 2, address(this));
    }

    /// @notice Deposits underlying collateral (like WETH)
    function _depositUnderlying(uint underlying) internal virtual override returns (uint){
        IAaveV3ATokenWrapper __asset = IAaveV3ATokenWrapper(asset());
        SafeERC20Lib.safeTransferFrom(IERC20_Euler(underlyingAsset), borrower, address(this), underlying, permit2);
        return __asset.deposit(underlying, address(this));
    }

    /// @notice Returns debt (B) and user collateral (C) in USD for Aave position
    /// @dev B = totalDebtBase from Aave's getUserAccountData (in USD with 8 decimals)
    /// @dev C = user-owned collateral valued using the wrapper's latestAnswer oracle price
    /// @return B The total debt value in USD
    /// @return C The user-owned collateral value in USD
    function _getBC() internal view override returns (uint, uint) {
        (, uint totalDebtBase,,,,) = IAaveV3Pool(targetVault).getUserAccountData(address(this));
        uint userCollateralValue =
            (totalAssetsDepositedOrReserved - maxRelease()) * uint(IAaveV3ATokenWrapper(asset()).latestAnswer()) / tenPowAssetDecimals;

        return (totalDebtBase, userCollateralValue);
    }

    /// @notice Checks if this vault can be liquidated on Twyne
    /// @dev Two liquidation scenarios:
    /// @dev 1. Aave health factor is close to liquidation (hf * buffer < 1e18 * MAXFACTOR)
    /// @dev 2. Twyne LTV exceeded (totalDebt * MAXFACTOR > twyneLiqLTV * userCollateralValue)
    /// @return bool True if the vault can be liquidated
    function _canLiquidate() internal view virtual override returns (bool) {
        IAaveV3ATokenWrapper __asset = IAaveV3ATokenWrapper(asset());
        (, uint totalDebtBase,,,,uint hf) = IAaveV3Pool(targetVault).getUserAccountData(address(this));

        // Check external protocol liquidation condition (with overflow protection for hf)
        if (hf <= type(uint).max / MAXFACTOR &&
            uint(twyneVaultManager.externalLiqBuffers(address(__asset))) * hf < 1e18 * MAXFACTOR) {
            return true;
        }

        uint userCollateralValue =
            (totalAssetsDepositedOrReserved - maxRelease()) * uint(__asset.latestAnswer()) / tenPowAssetDecimals;
        return (totalDebtBase * MAXFACTOR > twyneLiqLTV * userCollateralValue);
    }

    /// @notice Converts collateral value from USD to native collateral asset units
    /// @dev Uses the wrapper's latestAnswer oracle price for conversion
    /// @dev Returns the minimum of calculated amount and user-owned collateral
    /// @param collateralValue The collateral value in USD (with oracle decimals)
    /// @return collateralAmount The collateral amount in native asset units
    function _convertBaseToCollateral(uint collateralValue) internal view virtual override returns (uint collateralAmount) {
        collateralAmount = collateralValue * tenPowAssetDecimals / uint(IAaveV3ATokenWrapper(asset()).latestAnswer());
        return Math.min(totalAssetsDepositedOrReserved - maxRelease(), collateralAmount);
    }

    function balanceOf(address user) external view nonReentrantView override returns (uint) {
        if (user != address(this)) return 0;
        if (borrower == address(0)) return 0;

        uint _totalAssetsDepositedOrReserved = totalAssetsDepositedOrReserved;
        // return 0 if externally liquidated

        if (_totalAssetsDepositedOrReserved > IAToken(aToken).scaledBalanceOf(address(this))) return 0;
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
        IAaveV3ATokenWrapper __asset = IAaveV3ATokenWrapper(asset());

        if (_maxRepay == 0) {
            uint _releaseAmount = Math.min(_collateralBalance, _maxRelease);
            uint _borrowerClaim = _collateralBalance - _releaseAmount;
            return (0, _releaseAmount, _borrowerClaim);
        }

        // Step 1: Calculate user's portion of collateral (C_temp)
        // userCollateral = B_ext / λ̃^max_t (converted to collateral asset units)
        // This represents the collateral value needed to cover debt at max Twyne LTV
        // Get price of target asset (borrowed asset) from Aave oracle
        uint targetAssetPrice = IAaveV3PriceOracle(IAaveV3AddressProvider(__asset.POOL_ADDRESSES_PROVIDER()).getPriceOracle()).getAssetPrice(targetAsset);

        // Convert _maxRepay / maxTwyneLTV to USD
        // Result is in USD with Chainlink decimals for target asset
        uint userCollateral = targetAssetPrice * (_maxRepay * MAXFACTOR / twyneVaultManager.maxTwyneLTVs(address(__asset)))
            / tenPowVAssetDecimals;

        // Convert from USD to collateral asset units
        // Divides by collateral asset's Chainlink price
        userCollateral = userCollateral * tenPowAssetDecimals / uint(__asset.latestAnswer());

        // Cap by available collateral balance
        userCollateral = Math.min(_collateralBalance, userCollateral);

        // Step 2: Calculate CLP gets min(C_left - C_temp, C_LP^old)
        // This is the amount intermediate vault gets back
        uint releaseAmount = Math.min(_collateralBalance - userCollateral, _maxRelease);

        // Step 3: Calculate C_new which is C_left - CLP.
        // Collateral to be split between borrower and liquidator
        userCollateral = _collateralBalance - releaseAmount;

        // Step 3: Split userCollateral between borrower and liquidator using dynamic incentive
        // Convert userCollateral to USD for collateralForBorrower calculation
        uint C_new =
            userCollateral * uint(__asset.latestAnswer()) / tenPowAssetDecimals;

        (, uint B,,,,) = IAaveV3Pool(targetVault).getUserAccountData(address(this));

        // Apply dynamic incentive model: borrower gets collateralForBorrower(B, C_new)
        // Liquidator gets the remainder as reward for handling external liquidation
        uint borrowerClaim = collateralForBorrower(B, C_new);
        uint liquidatorReward = userCollateral - borrowerClaim;

        return (liquidatorReward, releaseAmount, borrowerClaim);
    }

    /// @notice to be called if the vault is liquidated by Aave
    function handleExternalLiquidation() external override callThroughEVC nonReentrant {
        createVaultSnapshot();
        IAaveV3ATokenWrapper __asset = IAaveV3ATokenWrapper(asset());
        uint _totalAssetsDepositedOrReserved = totalAssetsDepositedOrReserved;
        uint scaledBalance = IAToken(aToken).scaledBalanceOf(address(this));
        require(_totalAssetsDepositedOrReserved > scaledBalance, NotExternallyLiquidated());

        {
            (,,,,,uint healthFactor) = IAaveV3Pool(targetVault).getUserAccountData(address(this));
            require(healthFactor >= 1e18, ExternalPositionUnhealthy());
        }

        __asset.burnShares_CV(_totalAssetsDepositedOrReserved - scaledBalance);
        // after external liquidation
        uint _maxRelease = maxRelease();
        address liquidator = _msgSender();

        if (_maxRelease == 0) {
            require(liquidator == borrower, NoLiquidationForZeroReserve());
        }

        uint _maxRepay = maxRepay();

        uint amount = __asset.balanceOf(address(this));
        (uint liquidatorReward, uint releaseAmount, uint borrowerClaim) = splitCollateralAfterExtLiq(amount, _maxRepay, _maxRelease);

        if (_maxRepay > 0) {
            // step 1: repay all external debt
            SafeERC20Lib.safeTransferFrom(IERC20_Euler(targetAsset), liquidator, address(this), _maxRepay, permit2);
            IAaveV3Pool(targetVault).repay(targetAsset, _maxRepay, 2, address(this));
        }

        // This needs to be done after repaying debt, else it will fail.
        // This needs to be done before distributing the collateral,
        // as redeem may fail if the wrapper doesn't have enough aTokens.
        __asset.rebalanceATokens_CV(0);

        if (liquidatorReward > 0){
            // step 2: transfer collateral reward to liquidator.
            // We transfer atokens instead of underlying token (like USDC)
            // to avoid revert during high utilization on Aave.
            __asset.redeemATokens(liquidatorReward, liquidator, address(this));
        }

        if (borrowerClaim > 0) {
            // step 3: return some collateral to borrower
            // We transfer atokens instead of underlying token (like USDC)
            // to avoid revert during high utilization on Aave.
            __asset.redeemATokens(borrowerClaim, borrower, address(this));
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

    /// @notice This is to claim rewards accrued to this collateral vault because of atoken balance to vault manager
    /// @param assets address of tokens for which reward is to be claimed
    function claimRewards(address[] memory assets) external {
        INCENTIVES_CONTROLLER.claimAllRewards(assets, address(twyneVaultManager));
    }

}