// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.28;

import {CollateralVaultBase} from "src/twyne/CollateralVaultBase.sol";
import {PauseState} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";
import {IRewardsController} from "aave-v3/rewards/interfaces/IRewardsController.sol";
import {IPool as IAaveV3Pool} from "aave-v3/interfaces/IPool.sol";
import {IPoolDataProvider as IAaveV3DataProvider} from "aave-v3/interfaces/IPoolDataProvider.sol";
import {IPoolAddressesProvider as IAaveV3AddressProvider} from "aave-v3/interfaces/IPoolAddressesProvider.sol";
import {EModeConfiguration} from "aave-v3/protocol/libraries/configuration/EModeConfiguration.sol";
import {IPriceOracle as IAaveV3PriceOracle} from "aave-v3/interfaces/IPriceOracle.sol";
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

    IAaveV3AddressProvider internal immutable aaveAddressProvider;
    IAaveV3DataProvider internal immutable aaveDataProvider;

    IRewardsController internal immutable INCENTIVES_CONTROLLER;

    address public targetAsset; // like USDC
    address public aaveDebtToken; // like vUSDC
    address public aToken; // like aWETH
    address public underlyingAsset; // like WETH
    // Category ID for e-mode on Aave V3
    uint8 public categoryId;
    uint internal tenPowAssetDecimals;
    uint internal tenPowVAssetDecimals;

    uint[50] private __gap;

    /// @param _evc address of EVC deployed by Twyne
    /// @param _aavePool address of Aave v3 Pool
    constructor(address _evc, address _aavePool, address _incentiveController) CollateralVaultBase(_evc, _aavePool) {
        aaveAddressProvider = IAaveV3AddressProvider(IAaveV3Pool(_aavePool).ADDRESSES_PROVIDER());
        aaveDataProvider = IAaveV3DataProvider(aaveAddressProvider.getPoolDataProvider());
        INCENTIVES_CONTROLLER = IRewardsController(_incentiveController);
        _disableInitializers();
    }

    /// @param __intermediateVault address of the intermediate vault
    /// @param __borrower address of vault owner
    /// @param __liqLTV user-specified target LTV
    /// @param __vaultManager VaultManager contract address
    /// @param __targetAsset Target asset to borrow
    /// @param __categoryId Category ID for e-mode on Aave
    function initialize(
        address __intermediateVault,
        address __borrower,
        uint __liqLTV,
        VaultManager __vaultManager,
        address __targetAsset,
        uint8 __categoryId
    ) external initializer {
        // categoryId and underlyingAsset are used in _checkLiqLTV
        categoryId = __categoryId;
        address __asset = IEVault(__intermediateVault).asset();
        address _underlyingAsset = IAaveV3ATokenWrapper(__asset).asset();
        underlyingAsset = _underlyingAsset;
        targetAsset = __targetAsset;

        __CollateralVaultBase_init(__intermediateVault, __borrower, __liqLTV, __vaultManager);

        (,,address debtToken) = aaveDataProvider.getReserveTokensAddresses(__targetAsset);
        IAaveV3Pool(targetVault).setUserEMode(__categoryId);
        aaveDebtToken = debtToken;
        SafeERC20.forceApprove(IERC20(__targetAsset), address(targetVault), type(uint).max); // necessary for repay()

        address _aToken = IAaveV3ATokenWrapper(__asset).aToken();
        // necessary for wrapper.rebalanceATokens_CV()
        SafeERC20.forceApprove(IERC20(_aToken), __asset, type(uint).max);
        aToken = _aToken;
        // Overflows when decimals > 77; governance will verify decimals before listing
        unchecked {
            tenPowAssetDecimals = 10 ** uint(IAaveV3ATokenWrapper(__asset).decimals());
            tenPowVAssetDecimals = 10 ** uint(IERC20_Euler(aaveDebtToken).decimals());
        }
    }

    function _isNotExternallyLiquidated() internal view virtual override returns (bool) {
        return totalAssetsDepositedOrReserved <= IAToken(aToken).scaledBalanceOf(address(this));
    }

    /// @dev increment the version for proxy upgrades
    function version() external override pure returns (uint) {
        return 3;
    }

    function __targetAsset() internal view override returns (address) {
        return targetAsset;
    }

    /// @notice Returns Aave's liquidation threshold for the underlying asset
    /// @dev For eMode (categoryId != 0): checks if asset is in collateral bitmap, returns eMode LT or reserve LT accordingly
    /// @dev For non-eMode (categoryId == 0): returns the reserve's liquidation threshold directly
    /// @return uint The liquidation threshold in 1e4 precision
    function _getExtLiqLTV() internal view override returns (uint) {
        uint8 _categoryId = categoryId;
        address _underlyingAsset = underlyingAsset;
        if (_categoryId != 0) {
            // This is to ensure if emode is disabled we are taking correct liq ltv
            // Below code is taken from https://github.com/aave-dao/aave-v3-origin/blob/f53f03cf95ea5c3528016e849bf98210abdd5bcb/src/contracts/protocol/libraries/logic/GenericLogic.sol#L67
            IAaveV3Pool _pool = IAaveV3Pool(targetVault);
            uint reserveId = _pool.getReserveData(_underlyingAsset).id;
            uint128 collateralBitmap = _pool.getEModeCategoryCollateralBitmap(_categoryId);

            if (EModeConfiguration.isReserveEnabledOnBitmap(collateralBitmap, reserveId)) {
                return _pool.getEModeCategoryCollateralConfig(_categoryId).liquidationThreshold;
            }
        }

        (,,uint currentLiquidationThreshold,,,,,,,) = aaveDataProvider.getReserveConfigurationData(_underlyingAsset);
        return currentLiquidationThreshold;
    }

    /// @notice returns the maximum assets that can be repaid to Aave
    function maxRepay() public view override returns (uint) {
        return IERC20(aaveDebtToken).balanceOf(address(this));
    }

    /// @notice Converts a collateral-asset amount to target-asset units via Aave's USD prices
    function _convertCollateralToTargetAsset(uint collateralAmount) internal view override returns (uint) {
        IAaveV3ATokenWrapper __asset = IAaveV3ATokenWrapper(asset);
        uint collateralPrice = uint(__asset.latestAnswer());
        uint targetAssetPrice = IAaveV3PriceOracle(aaveAddressProvider.getPriceOracle()).getAssetPrice(targetAsset);

        return collateralAmount * collateralPrice * tenPowVAssetDecimals
            / (tenPowAssetDecimals * targetAssetPrice);
    }

    /// @notice adjust credit reserved from intermediate vault
    function _handleExcessCredit(uint __invariantCollateralAmount) internal override {
        uint vaultAssets = totalAssetsDepositedOrReserved;
        unchecked {
            if (vaultAssets > __invariantCollateralAmount) {
                uint excess = Math.min(vaultAssets - __invariantCollateralAmount, intermediateVault.debtOf(address(this)));
                vaultAssets -= intermediateVault.repay(excess, address(this));
            } else if (vaultAssets < __invariantCollateralAmount) {
                vaultAssets += intermediateVault.borrow(__invariantCollateralAmount - vaultAssets, address(this));
            }
        }

        IAaveV3ATokenWrapper(asset).rebalanceATokens_CV(vaultAssets);
        totalAssetsDepositedOrReserved = vaultAssets;
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
        address _targetAsset = targetAsset;
        SafeERC20Lib.safeTransferFrom(IERC20_Euler(_targetAsset), borrower, address(this), _targetAmount, permit2);
        IAaveV3Pool(targetVault).repay(_targetAsset, _targetAmount, 2, address(this));
    }

    /// @notice Returns user collateral (C) in USD
    /// @dev C = user-owned collateral valued using the wrapper's latestAnswer oracle price
    /// @return C The user-owned collateral value in USD
    function _getC() internal view override returns (uint C) {
        unchecked { C = totalAssetsDepositedOrReserved - maxRelease(); }
        return C * uint(IAaveV3ATokenWrapper(asset).latestAnswer()) / tenPowAssetDecimals;
    }

    /// @notice Checks if this vault can be liquidated on Twyne
    /// @dev B = totalDebtBase from Aave's getUserAccountData (in USD with 8 decimals)
    /// @dev Two liquidation scenarios:
    /// @dev 1. Aave health factor is close to liquidation (hf * buffer < 1)
    /// @dev 2. Twyne LTV exceeded (totalDebt > C · λ̃_t)
    /// @return bool True if the vault can be liquidated
    /// @return uint B The total debt value in USD
    function _canLiquidate() internal view virtual override returns (bool, uint) {
        IAaveV3ATokenWrapper __asset = IAaveV3ATokenWrapper(asset);
        (, uint totalDebtBase,,,,uint hf) = IAaveV3Pool(targetVault).getUserAccountData(address(this));

        (uint buffer, uint maxTwyneLiqLTV,) = _liqParams();
        // Check external protocol liquidation condition (with overflow protection for hf)
        if (hf <= type(uint).max / MAXFACTOR && buffer * hf < 1e18 * MAXFACTOR) {
            return (true, totalDebtBase);
        }

        // C · λ̃_t converted to value (USD base units, 1e8 precision on LTV)
        uint collateralValueScaledByLiqLTV =
            _collateralScaledByLiqLTV1e8(false, buffer * _getExtLiqLTV(), maxTwyneLiqLTV, maxRelease()) * uint(__asset.latestAnswer()) / tenPowAssetDecimals;
        return (totalDebtBase * 1e8 > collateralValueScaledByLiqLTV, totalDebtBase);
    }

    /// @notice Converts collateral value from USD to native collateral asset units
    /// @dev Uses the wrapper's latestAnswer oracle price for conversion
    /// @dev Returns the minimum of calculated amount and user-owned collateral
    /// @param collateralValue The collateral value in USD (with oracle decimals)
    /// @return collateralAmount The collateral amount in native asset units
    function _convertBaseToCollateral(uint collateralValue) internal view virtual override returns (uint collateralAmount) {
        collateralAmount = collateralValue * tenPowAssetDecimals / uint(IAaveV3ATokenWrapper(asset).latestAnswer());
        unchecked { return Math.min(totalAssetsDepositedOrReserved - maxRelease(), collateralAmount); }
    }

    function balanceOf(address user) external view nonReentrantView override returns (uint) {
        if (user != address(this)) return 0;

        uint _totalAssetsDepositedOrReserved = totalAssetsDepositedOrReserved;
        // return 0 when this vault doesn't have any assets
        if (_totalAssetsDepositedOrReserved == 0) return 0;
        // return 0 if externally liquidated

        if (_totalAssetsDepositedOrReserved > IAToken(aToken).scaledBalanceOf(address(this))) return 0;
        unchecked { return _totalAssetsDepositedOrReserved - maxRelease(); }
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
    function splitCollateralAfterExtLiq(uint _collateralBalance, uint _maxRepay, uint _maxRelease, uint B) internal view returns (uint liquidatorReward, uint releaseAmount, uint borrowerClaim) {
        IAaveV3ATokenWrapper __asset = IAaveV3ATokenWrapper(asset);

        if (_maxRepay == 0) {
            unchecked {
                uint _releaseAmount = Math.min(_collateralBalance, _maxRelease);
                uint _borrowerClaim = _collateralBalance - _releaseAmount;
                return (0, _releaseAmount, _borrowerClaim);
            }
        }

        // Step 1: Calculate user's portion of collateral (C_temp)
        // userCollateral = B_ext / λ̃^max_t (converted to collateral asset units)
        // This represents the collateral value needed to cover debt at max Twyne LTV
        // Get price of target asset (borrowed asset) from Aave oracle
        uint targetAssetPrice = IAaveV3PriceOracle(aaveAddressProvider.getPriceOracle()).getAssetPrice(targetAsset);
        uint collateralPrice = uint(__asset.latestAnswer());

        // Convert _maxRepay / maxTwyneLTV in target asset units collateral asset units via USD
        // Cap by available collateral balance
        // _maxTwyneLiqLTV is always populated here: the only caller, handleExternalLiquidation(),
        // takes the vault snapshot before invoking this split
        uint userCollateral = Math.min(_collateralBalance, targetAssetPrice * (_maxRepay * MAXFACTOR / _maxTwyneLiqLTV) * tenPowAssetDecimals
            / (tenPowVAssetDecimals * collateralPrice));

        // Step 2: Calculate CLP gets min(C_left - C_temp, C_LP^old)
        // This is the amount intermediate vault gets back
        unchecked { releaseAmount = Math.min(_collateralBalance - userCollateral, _maxRelease); }

        // Step 3: Calculate C_new which is C_left - CLP.
        // Collateral to be split between borrower and liquidator
        // _collateralBalance >= _collateralBalance - userCollateral >= releaseAmount;
        unchecked { userCollateral = _collateralBalance - releaseAmount; }

        // Step 3: Split userCollateral between borrower and liquidator using dynamic incentive
        // Convert userCollateral to USD for collateralForBorrower calculation
        uint C_new = userCollateral * collateralPrice / tenPowAssetDecimals;

        // Apply dynamic incentive model: borrower gets collateralForBorrower(B, C_new)
        // Liquidator gets the remainder as reward for handling external liquidation
        borrowerClaim = collateralForBorrower(B, C_new);
        unchecked { liquidatorReward = userCollateral - borrowerClaim; }
    }

    /// @notice to be called if the vault is liquidated by Aave
    function handleExternalLiquidation() external override callThroughEVC whenNotPaused(PauseState.Paused) nonReentrant {
        createVaultSnapshot();
        IAaveV3ATokenWrapper __asset = IAaveV3ATokenWrapper(asset);
        uint _totalAssetsDepositedOrReserved = totalAssetsDepositedOrReserved;
        uint scaledBalance = IAToken(aToken).scaledBalanceOf(address(this));
        require(_totalAssetsDepositedOrReserved > scaledBalance, NotExternallyLiquidated());

        IAaveV3Pool _pool = IAaveV3Pool(targetVault);
        (, uint B,,,,uint healthFactor) = _pool.getUserAccountData(address(this));
        require(healthFactor >= 1e18, ExternalPositionUnhealthy());

        // guarded by require(_totalAssetsDepositedOrReserved > scaledBalance) above
        unchecked { __asset.burnShares_CV(_totalAssetsDepositedOrReserved - scaledBalance); }
        // after external liquidation
        uint _maxRelease = maxRelease();
        address liquidator = _msgSender();

        if (_maxRelease == 0) {
            require(liquidator == borrower, NoLiquidationForZeroReserve());
        }

        uint _maxRepay = maxRepay();

        uint amount = __asset.balanceOf(address(this));
        (uint liquidatorReward, uint releaseAmount, uint borrowerClaim) = splitCollateralAfterExtLiq(amount, _maxRepay, _maxRelease, B);

        if (_maxRepay > 0) {
            // step 1: repay all external debt
            address _targetAsset = targetAsset;
            SafeERC20Lib.safeTransferFrom(IERC20_Euler(_targetAsset), liquidator, address(this), _maxRepay, permit2);
            _pool.repay(_targetAsset, _maxRepay, 2, address(this));
        }

        // This needs to be done after repaying debt, else it will fail.
        // This needs to be done before distributing the collateral,
        // as redeem may fail if the wrapper doesn't have enough aTokens.
        __asset.rebalanceATokens_CV(0);

        if (liquidatorReward > 0) {
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
    function claimRewards(address[] calldata assets) external {
        bytes memory data = abi.encodeCall(IRewardsController.claimAllRewards, (assets, address(twyneVaultManager)));
        address controller = address(INCENTIVES_CONTROLLER);
        assembly("memory-safe") {
            if iszero(call(gas(), controller, 0, add(data, 0x20), mload(data), 0, 0)) {
                revert(0x00, 0x00)
            }
        }
    }
}
